# failure-classifier.sh — Shared 6-class failure taxonomy for pipeline retry
# Source from sw-pipeline.sh. Pure functions, zero dependencies, no side effects.
[[ -n "${_FAILURE_CLASSIFIER_LOADED:-}" ]] && return 0
_FAILURE_CLASSIFIER_LOADED=1

# ─── Failure Taxonomy ────────────────────────────────────────────────────────
# 6 classes, priority-ordered (first match wins):
#   1. environment        — missing deps, permissions, auth (skip retry)
#   2. transient_network  — rate limits, timeouts, connectivity (delayed retry)
#   3. context_exhaustion — token/iteration limits (delayed retry)
#   4. flaky_test         — non-deterministic failures (immediate retry)
#   5. code_bug           — type/syntax/assertion errors (analysis + retry once)
#   6. unknown            — fallback (cautious delayed retry)

# Classify failure from log content
# @param $1 log_content — string, tail of stage log
# @stdout one of the 6 classes
# @exit 0 always
classify_failure_from_log() {
    local log_content="${1:-}"
    [[ -z "$log_content" ]] && { echo "unknown"; return 0; }

    # Priority 1: environment — missing files, permissions, auth failures
    if echo "$log_content" | grep -qiE 'ENOENT|permission denied|MODULE_NOT_FOUND|command not found|not logged in|missing.*env|EACCES|auth.*fail|401 Unauthorized|Cannot find module|No such file|undefined variable|not installed'; then
        echo "environment"
        return 0
    fi

    # Priority 2: transient_network — rate limits, timeouts, connectivity
    if echo "$log_content" | grep -qiE 'rate limit|429 |503 |502 |timeout|ETIMEDOUT|ECONNRESET|socket hang up|service unavailable|ECONNREFUSED|network error|fetch failed|getaddrinfo'; then
        echo "transient_network"
        return 0
    fi

    # Priority 3: context_exhaustion — token/iteration limits
    if echo "$log_content" | grep -qiE 'context window|token limit|max iterations reached|conversation too long|context length exceeded|maximum context'; then
        echo "context_exhaustion"
        return 0
    fi

    # Priority 4: flaky_test — non-deterministic test failures
    if echo "$log_content" | grep -qiE 'intermittent|flaky|race condition|timing|non-deterministic|EAGAIN|resource temporarily unavailable'; then
        echo "flaky_test"
        return 0
    fi

    # Priority 5: code_bug — deterministic code errors
    if echo "$log_content" | grep -qiE 'TypeError|SyntaxError|AssertionError|ReferenceError|compile error|build failed|tsc.*error|eslint.*error|error\[E[0-9]+\]|CompileError|type mismatch'; then
        echo "code_bug"
        return 0
    fi

    # Priority 6: fallback
    echo "unknown"
    return 0
}

# Get retry strategy for a failure class
# @param $1 failure_class
# @stdout JSON: {"max_retries": N, "action": "immediate|delayed|analysis|skip", "backoff_base_s": N}
# @exit 0 always
get_retry_strategy() {
    local failure_class="${1:-unknown}"
    case "$failure_class" in
        environment)
            echo '{"max_retries":0,"action":"skip","backoff_base_s":0}'
            ;;
        transient_network)
            echo '{"max_retries":3,"action":"delayed","backoff_base_s":30}'
            ;;
        context_exhaustion)
            echo '{"max_retries":2,"action":"delayed","backoff_base_s":10}'
            ;;
        flaky_test)
            echo '{"max_retries":2,"action":"immediate","backoff_base_s":1}'
            ;;
        code_bug)
            echo '{"max_retries":1,"action":"analysis","backoff_base_s":5}'
            ;;
        *)
            echo '{"max_retries":1,"action":"delayed","backoff_base_s":5}'
            ;;
    esac
    return 0
}

# Get backoff seconds for a specific attempt
# @param $1 failure_class
# @param $2 attempt (integer >= 1)
# @stdout integer seconds
# @exit 0 always
# Formula: min(base * 2^(attempt-1) + jitter, max_backoff)
get_backoff_seconds() {
    local failure_class="${1:-unknown}"
    local attempt="${2:-1}"

    # Validate attempt is a positive integer
    if ! echo "$attempt" | grep -qE '^[0-9]+$' || [[ "$attempt" -lt 1 ]]; then
        attempt=1
    fi

    local max_backoff="${PIPELINE_MAX_BACKOFF_S:-300}"

    local base_s
    case "$failure_class" in
        environment)        base_s=0 ;;
        transient_network)  base_s=30 ;;
        context_exhaustion) base_s=10 ;;
        flaky_test)         base_s=1 ;;
        code_bug)           base_s=5 ;;
        *)                  base_s=5 ;;
    esac

    # 2^(attempt-1)
    local exp=$((attempt - 1))
    local multiplier=1
    local i=0
    while [[ "$i" -lt "$exp" ]]; do
        multiplier=$((multiplier * 2))
        i=$((i + 1))
    done

    local computed=$((base_s * multiplier))

    # Jitter: 0-25% of computed delay
    local jitter=0
    if [[ "$computed" -gt 0 ]]; then
        local jitter_max=$((computed / 4))
        if [[ "$jitter_max" -gt 0 ]]; then
            jitter=$((RANDOM % (jitter_max + 1)))
        fi
    fi

    local total=$((computed + jitter))

    # Cap at max_backoff
    if [[ "$total" -gt "$max_backoff" ]]; then
        total="$max_backoff"
    fi

    echo "$total"
    return 0
}

# Check if failure class is retryable
# @param $1 failure_class
# @exit 0 if retryable, 1 if not
is_retryable() {
    local failure_class="${1:-unknown}"
    case "$failure_class" in
        environment) return 1 ;;
        *)           return 0 ;;
    esac
}
