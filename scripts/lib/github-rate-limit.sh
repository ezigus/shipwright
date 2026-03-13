#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright github-rate-limit — Centralized GitHub API retry with
#   exponential backoff and circuit breaker integration
#
#   Source this from any script that calls the GitHub API:
#     source "$SCRIPT_DIR/lib/github-rate-limit.sh"
#
#   Provides:
#     - gh_safe()              — retry wrapper for gh CLI calls
#     - _gh_is_retryable()     — classify HTTP/exit errors
#     - _gh_parse_retry_after() — extract Retry-After from output
# ═══════════════════════════════════════════════════════════════════
[[ -n "${_GITHUB_RATE_LIMIT_LOADED:-}" ]] && return 0
_GITHUB_RATE_LIMIT_LOADED=1

# ─── Configuration (read from defaults.json via config.sh) ────────
_GH_RL_MAX_RETRIES=""
_GH_RL_BASE_BACKOFF=""
_GH_RL_MAX_BACKOFF=""
_GH_RL_BACKOFF_MULTIPLIER=""
_GH_RL_CB_FAILURES=""

_gh_rl_load_config() {
    if [[ -n "$_GH_RL_MAX_RETRIES" ]]; then return 0; fi
    if type _config_get_int >/dev/null 2>&1; then
        _GH_RL_MAX_RETRIES=$(_config_get_int "network.rate_limit.max_retries" 4)
        _GH_RL_BASE_BACKOFF=$(_config_get_int "network.rate_limit.base_backoff_secs" 2)
        _GH_RL_MAX_BACKOFF=$(_config_get_int "network.rate_limit.max_backoff_secs" 300)
        _GH_RL_BACKOFF_MULTIPLIER=$(_config_get_int "network.rate_limit.backoff_multiplier" 2)
        _GH_RL_CB_FAILURES=$(_config_get_int "network.rate_limit.circuit_breaker_failures" 3)
    else
        _GH_RL_MAX_RETRIES=4
        _GH_RL_BASE_BACKOFF=2
        _GH_RL_MAX_BACKOFF=300
        _GH_RL_BACKOFF_MULTIPLIER=2
        _GH_RL_CB_FAILURES=3
    fi
}

# ─── Error Classification ────────────────────────────────────────
# Returns 0 if the error is retryable, 1 if it should fail fast.
# Args: <exit_code> <stderr_output>
_gh_is_retryable() {
    local exit_code="$1"
    local output="$2"

    # Timeout (exit 124 from _timeout)
    if [[ "$exit_code" -eq 124 ]]; then
        return 0
    fi

    # Rate limit: HTTP 403 with rate-limit text, or HTTP 429
    if echo "$output" | grep -qiE "HTTP 403.*rate|rate limit|HTTP 429|abuse detection|secondary rate|You have exceeded"; then
        return 0
    fi

    # Server errors: 502, 503
    if echo "$output" | grep -qE "HTTP 50[23]|502|503"; then
        return 0
    fi

    # Client errors that should fail fast: 400, 401, 404, 422
    if echo "$output" | grep -qE "HTTP 40[014]|HTTP 422"; then
        return 1
    fi

    # Generic gh failure — may be transient (network errors, etc.)
    if [[ "$exit_code" -ne 0 ]]; then
        return 0
    fi

    return 1
}

# ─── Retry-After Header Parsing ──────────────────────────────────
# Extracts Retry-After value from gh stderr output.
# Returns the value in seconds, or empty if not found.
_gh_parse_retry_after() {
    local output="$1"
    local retry_after=""
    # gh api may include header info in stderr
    retry_after=$(echo "$output" | grep -ioE 'retry-after[: ]+[0-9]+' | grep -oE '[0-9]+' | head -n 1)
    echo "${retry_after:-}"
}

# ─── Circuit Breaker Integration ─────────────────────────────────
# These track consecutive failures locally when daemon-state.sh
# circuit breaker is not available.
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

_gh_safe_circuit_check() {
    # Prefer daemon-state.sh circuit breaker if available
    if type gh_rate_limited >/dev/null 2>&1; then
        gh_rate_limited && return 0
        return 1
    fi
    # Fallback: local circuit breaker
    local now_e
    now_e=$(date +%s)
    if [[ "$_GH_SAFE_BACKOFF_UNTIL" -gt "$now_e" ]]; then
        return 0
    fi
    return 1
}

_gh_safe_record_success() {
    if type gh_record_success >/dev/null 2>&1; then
        gh_record_success
    fi
    _GH_SAFE_CONSECUTIVE_FAILURES=0
    _GH_SAFE_BACKOFF_UNTIL=0
}

_gh_safe_record_failure() {
    if type gh_record_failure >/dev/null 2>&1; then
        gh_record_failure
    fi
    _GH_SAFE_CONSECUTIVE_FAILURES=$((_GH_SAFE_CONSECUTIVE_FAILURES + 1))
    _gh_rl_load_config
    if [[ "$_GH_SAFE_CONSECUTIVE_FAILURES" -ge "$_GH_RL_CB_FAILURES" ]]; then
        local shift_amt=$(( _GH_SAFE_CONSECUTIVE_FAILURES - _GH_RL_CB_FAILURES ))
        [[ "$shift_amt" -gt 4 ]] && shift_amt=4
        local backoff_secs=$(( _GH_RL_BASE_BACKOFF * (1 << shift_amt) * 15 ))
        [[ "$backoff_secs" -gt "$_GH_RL_MAX_BACKOFF" ]] && backoff_secs="$_GH_RL_MAX_BACKOFF"
        _GH_SAFE_BACKOFF_UNTIL=$(( $(date +%s) + backoff_secs ))
    fi
}

# ─── gh_safe — Main Entry Point ──────────────────────────────────
# Usage: gh_safe <gh-command> [args...]
#   e.g. gh_safe gh issue view 123 --json title
#        gh_safe gh api repos/owner/repo/issues
#
# Behavior:
#   - Checks circuit breaker before calling
#   - Retries retryable errors with exponential backoff
#   - Respects Retry-After header
#   - Emits structured events
#   - Returns: stdout on success, exit code on failure
gh_safe() {
    _gh_rl_load_config

    local max_retries="$_GH_RL_MAX_RETRIES"
    local base_backoff="$_GH_RL_BASE_BACKOFF"
    local max_backoff="$_GH_RL_MAX_BACKOFF"
    local multiplier="$_GH_RL_BACKOFF_MULTIPLIER"

    # Circuit breaker check
    if _gh_safe_circuit_check; then
        if type warn >/dev/null 2>&1; then
            warn "GitHub API circuit breaker open — skipping call: $1 ${2:-}"
        fi
        if type emit_event >/dev/null 2>&1; then
            emit_event "github.circuit_breaker" "action=skipped" "command=$1"
        fi
        return 1
    fi

    local attempt=0
    local backoff_secs="$base_backoff"
    local output=""
    local exit_code=0
    local gh_timeout=30
    if type _config_get_int >/dev/null 2>&1; then
        gh_timeout=$(_config_get_int "network.gh_timeout" 30)
    fi

    while [[ "$attempt" -lt "$max_retries" ]]; do
        attempt=$((attempt + 1))

        # Execute with timeout
        output=""
        exit_code=0
        if type _timeout >/dev/null 2>&1; then
            output=$(_timeout "$gh_timeout" "$@" 2>&1) || exit_code=$?
        else
            output=$("$@" 2>&1) || exit_code=$?
        fi

        # Success
        if [[ "$exit_code" -eq 0 ]]; then
            _gh_safe_record_success
            echo "$output"
            return 0
        fi

        # Classify the error
        if ! _gh_is_retryable "$exit_code" "$output"; then
            # Non-retryable error — fail fast
            if type emit_event >/dev/null 2>&1; then
                emit_event "github.api_error" "exit=$exit_code" "retryable=false" "command=$1"
            fi
            echo "$output"
            return "$exit_code"
        fi

        # Record failure for circuit breaker
        _gh_safe_record_failure

        # Check for Retry-After header
        local retry_after
        retry_after=$(_gh_parse_retry_after "$output")
        if [[ -n "$retry_after" && "$retry_after" -gt 0 ]] 2>/dev/null; then
            backoff_secs="$retry_after"
        fi

        # Cap backoff
        [[ "$backoff_secs" -gt "$max_backoff" ]] && backoff_secs="$max_backoff"

        if [[ "$attempt" -lt "$max_retries" ]]; then
            if type warn >/dev/null 2>&1; then
                warn "GitHub API error — retrying in ${backoff_secs}s (attempt ${attempt}/${max_retries})"
            fi
            if type emit_event >/dev/null 2>&1; then
                emit_event "github.retry" "attempt=$attempt" "backoff=$backoff_secs" "exit=$exit_code" "command=$1"
            fi
            sleep "$backoff_secs"
            # Exponential backoff for next iteration
            backoff_secs=$((backoff_secs * multiplier))
        fi
    done

    # Exhausted all retries
    if type error >/dev/null 2>&1; then
        error "GitHub API call failed after ${max_retries} attempts: $1 ${2:-}"
    fi
    if type emit_event >/dev/null 2>&1; then
        emit_event "github.api_failed" "attempts=$max_retries" "command=$1"
    fi
    echo "$output"
    return "${exit_code:-1}"
}
