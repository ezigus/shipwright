#!/usr/bin/env bash
# test-retry.sh — Isolated per-test retry handler for flaky tests
# Source from other scripts. Requires flakiness-tracker.sh.
[[ -n "${_TEST_RETRY_LOADED:-}" ]] && return 0
_TEST_RETRY_LOADED=1

VERSION="3.2.4"

SCRIPT_DIR_RETRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_RETRY/flakiness-tracker.sh"

# Accumulate retry summaries in a file (avoids subshell variable loss)
_RETRY_SUMMARY_FILE="${TMPDIR:-/tmp}/sw-retry-summary-$$.jsonl"
: > "$_RETRY_SUMMARY_FILE"

# ─── Retry a failing test if flaky ─────────────────────────────────────────
# Args: testId testCmd [maxAttempts=3] [timeoutSecs=30]
# Output (stdout): JSON {passed, attempts, results[], isFlaky}
# Returns: 0 if eventually passed, 1 if all retries exhausted
retry_flaky_test() {
    local test_id="${1:?testId required}"
    local test_cmd="${2:?testCmd required}"
    local max_attempts="${3:-3}"
    local timeout_secs="${4:-30}"

    # Check flakiness score
    local score
    score=$(get_flakiness_score "$test_id")
    local is_flaky is_broken
    is_flaky=$(echo "$score" | jq -r '.isFlaky')
    is_broken=$(echo "$score" | jq -r '.isBroken')

    # If not flaky or broken, don't retry
    if ! should_retry "$is_flaky" "$is_broken" 0 "$max_attempts"; then
        echo "$score" | jq '{passed: false, attempts: 0, results: [], isFlaky: false, reason: "not_flaky"}'
        return 1
    fi

    local attempt=0
    local results="[]"
    local passed="false"

    while [[ "$attempt" -lt "$max_attempts" ]]; do
        attempt=$((attempt + 1))
        local start_ms
        start_ms=$(date +%s%N 2>/dev/null | cut -c1-13 || echo "$(date +%s)000")

        # Run the test with timeout
        local exit_code=0
        local output=""
        if command -v timeout >/dev/null 2>&1; then
            output=$(timeout "$timeout_secs" bash -c "$test_cmd" 2>&1) || exit_code=$?
        else
            output=$(bash -c "$test_cmd" 2>&1) || exit_code=$?
        fi

        local end_ms
        end_ms=$(date +%s%N 2>/dev/null | cut -c1-13 || echo "$(date +%s)000")
        local duration_ms=$(( end_ms - start_ms ))
        # Clamp negative durations (can happen with fallback)
        [[ "$duration_ms" -lt 0 ]] && duration_ms=0

        local result
        if [[ "$exit_code" -eq 0 ]]; then
            result="pass"
            passed="true"
        elif [[ "$exit_code" -eq 124 ]]; then
            result="fail"  # timeout
        else
            result="fail"
        fi

        # Record this attempt
        record_test_result "$test_id" "$result" "$duration_ms" "retry-$attempt"

        # Add to results array
        results=$(echo "$results" | jq \
            --argjson attempt "$attempt" \
            --arg result "$result" \
            --argjson exitCode "$exit_code" \
            --argjson durationMs "$duration_ms" \
            '. + [{attempt: $attempt, result: $result, exitCode: $exitCode, durationMs: $durationMs}]')

        # Stop on first pass
        if [[ "$passed" == "true" ]]; then
            break
        fi

        # Check if we should continue retrying
        if ! should_retry "$is_flaky" "$is_broken" "$attempt" "$max_attempts"; then
            break
        fi
    done

    local summary
    summary=$(jq -n \
        --arg testId "$test_id" \
        --argjson passed "$passed" \
        --argjson attempts "$attempt" \
        --argjson results "$results" \
        --argjson isFlaky true \
        '{testId: $testId, passed: $passed, attempts: $attempts, results: $results, isFlaky: $isFlaky}')

    # Accumulate summary to file (survives subshell)
    echo "$summary" | jq -c '.' >> "$_RETRY_SUMMARY_FILE"

    echo "$summary"

    if [[ "$passed" == "true" ]]; then
        return 0
    fi
    return 1
}

# ─── Get summary of all retries this run ───────────────────────────────────
# Output (stdout): JSON array of retry summaries
get_retry_summary() {
    if [[ ! -f "$_RETRY_SUMMARY_FILE" ]] || [[ ! -s "$_RETRY_SUMMARY_FILE" ]]; then
        echo '[]'
        return 0
    fi
    jq -cs '.' "$_RETRY_SUMMARY_FILE"
}
