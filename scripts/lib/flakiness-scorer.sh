#!/usr/bin/env bash
# flakiness-scorer.sh — Pure scoring logic for test flakiness detection
# Source from other scripts. No file I/O — pure functions only.
[[ -n "${_FLAKINESS_SCORER_LOADED:-}" ]] && return 0
_FLAKINESS_SCORER_LOADED=1

VERSION="3.2.4"

# ─── Flakiness Classification ──────────────────────────────────────────────
# Calculate flakiness classification from pass/fail counts.
# Args: passCount failCount [minSampleSize=3]
# Output (stdout): JSON with failRate, isFlaky, isBroken, isUntested, confidence
# Pure function — no side effects, no file I/O.
calculate_flakiness() {
    local pass_count="${1:?pass_count required}"
    local fail_count="${2:?fail_count required}"
    local min_sample="${3:-3}"

    local total=$((pass_count + fail_count))

    # Insufficient data → untested
    if [[ "$total" -lt "$min_sample" ]]; then
        echo '{"failRate":0,"isFlaky":false,"isBroken":false,"isUntested":true,"confidence":0}'
        return 0
    fi

    # Calculate fail rate as integer percentage (0-100) to avoid floating point
    local fail_rate_pct=$(( (fail_count * 100) / total ))

    # Classify:
    #   < 10%  → stable
    #   10-90% → flaky (inclusive on boundaries)
    #   > 90%  → broken
    local is_flaky="false"
    local is_broken="false"
    if [[ "$fail_rate_pct" -ge 10 && "$fail_rate_pct" -le 90 ]]; then
        is_flaky="true"
    elif [[ "$fail_rate_pct" -gt 90 ]]; then
        is_broken="true"
    fi

    # Confidence scales with sample size (max at 50 samples)
    local confidence
    if [[ "$total" -ge 50 ]]; then
        confidence=100
    else
        confidence=$(( (total * 100) / 50 ))
    fi

    # Use jq for proper JSON output
    jq -n \
        --argjson failRate "$fail_rate_pct" \
        --argjson isFlaky "$is_flaky" \
        --argjson isBroken "$is_broken" \
        --argjson confidence "$confidence" \
        --argjson passCount "$pass_count" \
        --argjson failCount "$fail_count" \
        '{failRate: $failRate, isFlaky: $isFlaky, isBroken: $isBroken, isUntested: false, confidence: $confidence, passCount: $passCount, failCount: $failCount}'
}

# ─── Retry Decision ────────────────────────────────────────────────────────
# Determine if a failed test should be retried.
# Args: isFlaky(true|false) isBroken(true|false) attemptCount maxAttempts
# Returns: 0 (should retry) or 1 (should not retry)
should_retry() {
    local is_flaky="${1:?isFlaky required}"
    local is_broken="${2:?isBroken required}"
    local attempt_count="${3:?attemptCount required}"
    local max_attempts="${4:-3}"

    # Only retry flaky tests that aren't broken and haven't exceeded max attempts
    if [[ "$is_flaky" == "true" && "$is_broken" != "true" && "$attempt_count" -lt "$max_attempts" ]]; then
        return 0
    fi
    return 1
}
