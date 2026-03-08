#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-lib-flakiness-tracker-test.sh — Flakiness tracker unit tests        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "flakiness-tracker"

# Point DB to temp location
export FLAKINESS_DB="$TEST_TEMP_DIR/home/.shipwright/flakiness-db.jsonl"

source "$SCRIPT_DIR/lib/flakiness-tracker.sh"

print_test_header "Flakiness Tracker"

# ─── record_test_result tests ──────────────────────────────────────────────

# Test: recording creates DB file
record_test_result "test-a" "pass" 100 "run-1"
assert_file_exists "record creates DB file" "$FLAKINESS_DB"

# Test: record has correct fields
line=$(head -1 "$FLAKINESS_DB")
assert_json_key "record has testId" "$line" ".testId" "test-a"
assert_json_key "record has result" "$line" ".result" "pass"
assert_json_key "record has durationMs" "$line" ".durationMs" "100"
assert_json_key "record has runId" "$line" ".runId" "run-1"

# Test: multiple records append
record_test_result "test-a" "fail" 200 "run-2"
record_test_result "test-b" "pass" 50 "run-3"
line_count=$(wc -l < "$FLAKINESS_DB" | tr -d ' ')
assert_eq "3 records after 3 writes" "3" "$line_count"

# Test: invalid result rejected
invalid_exit=0
record_test_result "test-c" "invalid" 0 "run-4" 2>/dev/null || invalid_exit=$?
assert_eq "invalid result rejected" "1" "$invalid_exit"

# Test: skip result accepted
record_test_result "test-c" "skip" 0 "run-5"
last_line=$(tail -1 "$FLAKINESS_DB")
assert_json_key "skip result recorded" "$last_line" ".result" "skip"

# ─── get_flakiness_score tests ─────────────────────────────────────────────

# Reset DB with controlled data
: > "$FLAKINESS_DB"

# Seed 20 pass + 5 fail for test-flaky-1
for i in $(seq 1 20); do
    record_test_result "test-flaky-1" "pass" 100 "seed-$i"
done
for i in $(seq 1 5); do
    record_test_result "test-flaky-1" "fail" 100 "seed-fail-$i"
done

score=$(get_flakiness_score "test-flaky-1")
assert_json_key "flaky test detected: isFlaky" "$score" ".isFlaky" "true"
assert_json_key "flaky test not broken" "$score" ".isBroken" "false"
assert_json_key "flaky test not untested" "$score" ".isUntested" "false"

# Test: unknown test returns untested
score=$(get_flakiness_score "nonexistent-test")
assert_json_key "unknown test: isUntested" "$score" ".isUntested" "true"

# Test: missing DB returns untested
saved_db="$FLAKINESS_DB"
export FLAKINESS_DB="$TEST_TEMP_DIR/nonexistent.jsonl"
score=$(get_flakiness_score "any-test")
assert_json_key "missing DB: isUntested" "$score" ".isUntested" "true"
export FLAKINESS_DB="$saved_db"

# ─── get_flaky_tests tests ────────────────────────────────────────────────

# Seed a broken test (all fails)
for i in $(seq 1 10); do
    record_test_result "test-broken-1" "fail" 100 "broken-$i"
done

# Seed a stable test (all passes)
for i in $(seq 1 10); do
    record_test_result "test-stable-1" "pass" 100 "stable-$i"
done

flaky_list=$(get_flaky_tests 50 20)
flaky_count=$(echo "$flaky_list" | jq 'length')
assert_gt "at least 1 flaky test in list" "$flaky_count" 0

# Verify broken test NOT in flaky list
broken_in_list=$(echo "$flaky_list" | jq '[.[] | select(.testId == "test-broken-1")] | length')
assert_eq "broken test excluded from flaky list" "0" "$broken_in_list"

# Verify stable test NOT in flaky list
stable_in_list=$(echo "$flaky_list" | jq '[.[] | select(.testId == "test-stable-1")] | length')
assert_eq "stable test excluded from flaky list" "0" "$stable_in_list"

# Verify flaky test IS in flaky list
flaky_in_list=$(echo "$flaky_list" | jq '[.[] | select(.testId == "test-flaky-1")] | length')
assert_eq "flaky test included in flaky list" "1" "$flaky_in_list"

# ─── Empty DB tests ───────────────────────────────────────────────────────

export FLAKINESS_DB="$TEST_TEMP_DIR/empty.jsonl"
empty_list=$(get_flaky_tests)
assert_eq "empty DB returns empty array" "[]" "$empty_list"

cleanup_test_env
print_test_results
