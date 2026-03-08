#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-flaky.sh — Flakiness detection and reporting CLI               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/flakiness-tracker.sh"

show_help() {
    echo "Usage: shipwright test-flaky <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  list       List flaky tests sorted by fail rate"
    echo "  score      Show flakiness score for a specific test"
    echo "  record     Record a test result manually"
    echo "  prune      Remove old records"
    echo "  summary    Show retry summary from last run"
    echo "  report     Generate JSON report of all test flakiness"
    echo ""
    echo "Options:"
    echo "  --window N     Window size for scoring (default: 50)"
    echo "  --limit N      Max results to show (default: 20)"
    echo "  --db PATH      Path to flakiness database"
    echo ""
    echo "Examples:"
    echo "  shipwright test-flaky list"
    echo "  shipwright test-flaky score \"test-name\""
    echo "  shipwright test-flaky record \"test-name\" pass 142"
    echo "  shipwright test-flaky prune --days 14"
}

cmd_list() {
    local window=50
    local limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window) window="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local flaky
    flaky=$(get_flaky_tests "$window" "$limit")
    local count
    count=$(echo "$flaky" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        info "No flaky tests detected"
        return 0
    fi

    echo ""
    echo -e "${BOLD}Flaky Tests${RESET} ${DIM}($count found, window=$window)${RESET}"
    echo -e "${DIM}─────────────────────────────────────────────────────${RESET}"
    printf "  ${BOLD}%-40s %8s %6s %6s %10s${RESET}\n" "TEST ID" "FAIL %" "PASS" "FAIL" "CONFIDENCE"
    echo -e "${DIM}─────────────────────────────────────────────────────${RESET}"

    echo "$flaky" | jq -r '.[] | "\(.testId)\t\(.failRate)\t\(.passCount)\t\(.failCount)\t\(.confidence)"' | while IFS=$'\t' read -r tid rate pass fail conf; do
        local color="$YELLOW"
        if [[ "$rate" -ge 50 ]]; then
            color="$RED"
        fi
        printf "  %-40s ${color}%7d%%${RESET} %6d %6d %9d%%\n" "$tid" "$rate" "$pass" "$fail" "$conf"
    done
    echo ""
}

cmd_score() {
    local test_id="${1:?test ID required}"
    local window="${2:-50}"
    local score
    score=$(get_flakiness_score "$test_id" "$window")
    echo "$score" | jq '.'
}

cmd_record() {
    local test_id="${1:?test ID required}"
    local result="${2:?result required (pass|fail|skip)}"
    local duration="${3:-0}"
    local run_id="${4:-manual-$(date +%s)}"

    record_test_result "$test_id" "$result" "$duration" "$run_id"
    success "Recorded: $test_id → $result (${duration}ms)"
}

cmd_prune() {
    local days=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local pruned
    pruned=$(prune_old_results "$days")
    success "Pruned $pruned records older than $days days"
}

cmd_report() {
    local window=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window) window="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$FLAKINESS_DB" ]]; then
        jq -n '{totalTests: 0, flakyCount: 0, brokenCount: 0, stableCount: 0, untestedCount: 0, topFlaky: []}'
        return 0
    fi

    local test_ids
    test_ids=$(jq -R 'fromjson? // empty | .testId' "$FLAKINESS_DB" | sort -u | jq -r '.')

    local total=0 flaky_count=0 broken_count=0 stable_count=0 untested_count=0
    local top_flaky="[]"

    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        total=$((total + 1))
        local score
        score=$(get_flakiness_score "$tid" "$window")
        local is_flaky is_broken is_untested
        is_flaky=$(echo "$score" | jq -r '.isFlaky')
        is_broken=$(echo "$score" | jq -r '.isBroken')
        is_untested=$(echo "$score" | jq -r '.isUntested')

        if [[ "$is_untested" == "true" ]]; then
            untested_count=$((untested_count + 1))
        elif [[ "$is_broken" == "true" ]]; then
            broken_count=$((broken_count + 1))
        elif [[ "$is_flaky" == "true" ]]; then
            flaky_count=$((flaky_count + 1))
            top_flaky=$(echo "$top_flaky" | jq \
                --arg testId "$tid" \
                --argjson score "$score" \
                '. + [{testId: $testId, failRate: $score.failRate, passCount: $score.passCount, failCount: $score.failCount}]')
        else
            stable_count=$((stable_count + 1))
        fi
    done <<< "$test_ids"

    top_flaky=$(echo "$top_flaky" | jq 'sort_by(-.failRate) | .[:10]')

    jq -n \
        --argjson totalTests "$total" \
        --argjson flakyCount "$flaky_count" \
        --argjson brokenCount "$broken_count" \
        --argjson stableCount "$stable_count" \
        --argjson untestedCount "$untested_count" \
        --argjson topFlaky "$top_flaky" \
        '{totalTests: $totalTests, flakyCount: $flakyCount, brokenCount: $brokenCount, stableCount: $stableCount, untestedCount: $untestedCount, topFlaky: $topFlaky}'
}

# ─── Parse global options ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) FLAKINESS_DB="$2"; shift 2 ;;
        --help|-h) show_help; exit 0 ;;
        *) break ;;
    esac
done

subcmd="${1:-help}"
shift || true

case "$subcmd" in
    list)     cmd_list "$@" ;;
    score)    cmd_score "$@" ;;
    record)   cmd_record "$@" ;;
    prune)    cmd_prune "$@" ;;
    report)   cmd_report "$@" ;;
    summary)  get_retry_summary ;;
    help|*)   show_help ;;
esac
