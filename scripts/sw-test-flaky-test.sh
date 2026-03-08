#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-flaky-test.sh — CLI command test suite                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "test-flaky-cli"

export FLAKINESS_DB="$TEST_TEMP_DIR/home/.shipwright/flakiness-db.jsonl"

print_test_header "Test Flaky CLI"

# ─── help output ───────────────────────────────────────────────────────────

output=$("$SCRIPT_DIR/sw-test-flaky.sh" --help 2>&1)
assert_contains "help shows usage" "$output" "Usage:"
assert_contains "help shows list subcommand" "$output" "list"
assert_contains "help shows score subcommand" "$output" "score"

# ─── record subcommand ────────────────────────────────────────────────────

output=$("$SCRIPT_DIR/sw-test-flaky.sh" record "cli-test-1" pass 100 2>&1)
assert_contains "record confirms success" "$output" "Recorded"
assert_file_exists "record creates DB" "$FLAKINESS_DB"

# ─── score subcommand ─────────────────────────────────────────────────────

# Seed enough data
for i in $(seq 1 8); do
    "$SCRIPT_DIR/sw-test-flaky.sh" record "cli-test-2" pass 50 >/dev/null 2>&1
done
for i in $(seq 1 4); do
    "$SCRIPT_DIR/sw-test-flaky.sh" record "cli-test-2" fail 50 >/dev/null 2>&1
done

output=$("$SCRIPT_DIR/sw-test-flaky.sh" score "cli-test-2" 2>&1)
assert_contains "score shows failRate" "$output" "failRate"
assert_contains "score shows isFlaky" "$output" "isFlaky"

# ─── list subcommand ──────────────────────────────────────────────────────

output=$("$SCRIPT_DIR/sw-test-flaky.sh" list 2>&1)
assert_contains "list shows flaky test" "$output" "cli-test-2"

# ─── report subcommand ────────────────────────────────────────────────────

output=$("$SCRIPT_DIR/sw-test-flaky.sh" report 2>&1)
assert_contains "report has totalTests" "$output" "totalTests"
assert_contains "report has flakyCount" "$output" "flakyCount"

# ─── custom --db flag ─────────────────────────────────────────────────────

custom_db="$TEST_TEMP_DIR/custom.jsonl"
"$SCRIPT_DIR/sw-test-flaky.sh" --db "$custom_db" record "custom-test" pass 50 >/dev/null 2>&1
assert_file_exists "custom DB created" "$custom_db"

# ─── empty DB report ──────────────────────────────────────────────────────

output=$("$SCRIPT_DIR/sw-test-flaky.sh" --db "$TEST_TEMP_DIR/empty.jsonl" report 2>&1)
report_total=$(echo "$output" | jq -r '.totalTests')
assert_eq "empty DB report: totalTests=0" "0" "$report_total"

cleanup_test_env
print_test_results
