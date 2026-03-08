#!/usr/bin/env bash
# flakiness-tracker.sh — JSONL-based test result persistence and scoring
# Source from other scripts. Requires jq.
[[ -n "${_FLAKINESS_TRACKER_LOADED:-}" ]] && return 0
_FLAKINESS_TRACKER_LOADED=1

VERSION="3.2.4"

SCRIPT_DIR_TRACKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_TRACKER/flakiness-scorer.sh"

# Default DB location
FLAKINESS_DB="${FLAKINESS_DB:-${HOME}/.shipwright/flakiness-db.jsonl}"

# ─── Record a test result ──────────────────────────────────────────────────
# Args: testId result(pass|fail|skip) durationMs [runId]
# Side effect: appends to $FLAKINESS_DB
record_test_result() {
    local test_id="${1:?testId required}"
    local result="${2:?result required}"
    local duration_ms="${3:-0}"
    local run_id="${4:-$(date +%s)-$$}"

    # Validate result
    case "$result" in
        pass|fail|skip) ;;
        *) echo "ERROR: invalid result '$result' (must be pass|fail|skip)" >&2; return 1 ;;
    esac

    # Ensure directory exists
    local db_dir
    db_dir="$(dirname "$FLAKINESS_DB")"
    mkdir -p "$db_dir"

    # Build JSON record with jq (-c for compact/single-line JSONL)
    local record
    record=$(jq -cn \
        --arg testId "$test_id" \
        --arg result "$result" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson durationMs "$duration_ms" \
        --arg runId "$run_id" \
        '{testId: $testId, result: $result, ts: $ts, durationMs: $durationMs, runId: $runId}')

    # Append atomically (flock if available, plain append otherwise)
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 5 200 || { echo "WARN: flock timeout, writing without lock" >&2; }
            echo "$record" >> "$FLAKINESS_DB"
        ) 200>"${FLAKINESS_DB}.lock"
    else
        echo "$record" >> "$FLAKINESS_DB"
    fi
}

# ─── Get flakiness score for a test ────────────────────────────────────────
# Args: testId [windowSize=50]
# Output (stdout): JSON with scoring data
get_flakiness_score() {
    local test_id="${1:?testId required}"
    local window_size="${2:-50}"

    if [[ ! -f "$FLAKINESS_DB" ]]; then
        echo '{"failRate":0,"isFlaky":false,"isBroken":false,"isUntested":true,"confidence":0}'
        return 0
    fi

    # Extract last N results for this test (-c for compact one-line-per-record)
    local results
    results=$(jq -cR 'fromjson? // empty | select(.testId == "'"$test_id"'")' "$FLAKINESS_DB" | tail -n "$window_size")

    if [[ -z "$results" ]]; then
        echo '{"failRate":0,"isFlaky":false,"isBroken":false,"isUntested":true,"confidence":0}'
        return 0
    fi

    # Count pass/fail (skip excluded from denominator)
    local pass_count fail_count
    pass_count=$(echo "$results" | jq -cr 'select(.result == "pass") | .result' | wc -l | tr -d ' ')
    fail_count=$(echo "$results" | jq -cr 'select(.result == "fail") | .result' | wc -l | tr -d ' ')

    calculate_flakiness "$pass_count" "$fail_count"
}

# ─── List all flaky tests ──────────────────────────────────────────────────
# Args: [windowSize=50] [limit=20]
# Output (stdout): JSON array of flaky tests sorted by failRate desc
get_flaky_tests() {
    local window_size="${1:-50}"
    local limit="${2:-20}"

    if [[ ! -f "$FLAKINESS_DB" ]]; then
        echo '[]'
        return 0
    fi

    # Get unique test IDs
    local test_ids
    test_ids=$(jq -R 'fromjson? // empty | .testId' "$FLAKINESS_DB" | sort -u | jq -r '.')

    if [[ -z "$test_ids" ]]; then
        echo '[]'
        return 0
    fi

    # Score each test and collect flaky ones
    local flaky_json="[]"
    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        local score
        score=$(get_flakiness_score "$tid" "$window_size")
        local is_flaky
        is_flaky=$(echo "$score" | jq -r '.isFlaky')
        if [[ "$is_flaky" == "true" ]]; then
            flaky_json=$(echo "$flaky_json" | jq \
                --arg testId "$tid" \
                --argjson score "$score" \
                '. + [{ testId: $testId, failRate: $score.failRate, passCount: $score.passCount, failCount: $score.failCount, confidence: $score.confidence }]')
        fi
    done <<< "$test_ids"

    # Sort by failRate descending, limit
    echo "$flaky_json" | jq "sort_by(-.failRate) | .[:$limit]"
}

# ─── Prune old results ─────────────────────────────────────────────────────
# Args: [maxAgeDays=30]
# Output (stdout): number of pruned records
prune_old_results() {
    local max_age_days="${1:-30}"

    if [[ ! -f "$FLAKINESS_DB" ]]; then
        echo "0"
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(date +%s) - (max_age_days * 86400) ))
    local cutoff_iso
    cutoff_iso=$(date -u -d "@$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

    if [[ -z "$cutoff_iso" ]]; then
        echo "0"
        return 0
    fi

    local total_before
    total_before=$(wc -l < "$FLAKINESS_DB" | tr -d ' ')

    # Atomic rewrite: keep only records newer than cutoff
    local tmp_file
    tmp_file=$(mktemp "${FLAKINESS_DB}.tmp.XXXXXX")
    jq -R "fromjson? // empty | select(.ts >= \"$cutoff_iso\")" "$FLAKINESS_DB" | jq -c '.' > "$tmp_file"
    mv "$tmp_file" "$FLAKINESS_DB"

    local total_after
    total_after=$(wc -l < "$FLAKINESS_DB" | tr -d ' ')
    echo $((total_before - total_after))
}
