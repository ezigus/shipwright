#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-lib-flakiness-scorer-test.sh — Flakiness scorer unit tests          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "flakiness-scorer"
source "$SCRIPT_DIR/lib/flakiness-scorer.sh"

print_test_header "Flakiness Scorer"

# ─── calculate_flakiness tests ─────────────────────────────────────────────

# Test: insufficient data returns untested
result=$(calculate_flakiness 1 1 3)
assert_json_key "untested when < min samples" "$result" ".isUntested" "true"

# Test: zero failures = stable (not flaky, not broken)
result=$(calculate_flakiness 50 0)
assert_json_key "0% fail rate: not flaky" "$result" ".isFlaky" "false"
assert_json_key "0% fail rate: not broken" "$result" ".isBroken" "false"
assert_json_key "0% fail rate: failRate=0" "$result" ".failRate" "0"

# Test: 5% fail rate = stable (below 10%)
result=$(calculate_flakiness 19 1)
assert_json_key "5% fail rate: not flaky" "$result" ".isFlaky" "false"

# Test: 10% fail rate = flaky (boundary, inclusive)
result=$(calculate_flakiness 9 1)
assert_json_key "10% fail rate: flaky (boundary)" "$result" ".isFlaky" "true"
assert_json_key "10% fail rate: not broken" "$result" ".isBroken" "false"

# Test: 50% fail rate = flaky (middle of range)
result=$(calculate_flakiness 25 25)
assert_json_key "50% fail rate: flaky" "$result" ".isFlaky" "true"
assert_json_key "50% fail rate: failRate=50" "$result" ".failRate" "50"

# Test: 90% fail rate = flaky (boundary, inclusive)
result=$(calculate_flakiness 1 9)
assert_json_key "90% fail rate: flaky (boundary)" "$result" ".isFlaky" "true"
assert_json_key "90% fail rate: not broken" "$result" ".isBroken" "false"

# Test: 95% fail rate = broken (above 90%)
result=$(calculate_flakiness 1 19)
assert_json_key "95% fail rate: broken" "$result" ".isBroken" "true"
assert_json_key "95% fail rate: not flaky" "$result" ".isFlaky" "false"

# Test: 100% fail rate = broken
result=$(calculate_flakiness 0 50)
assert_json_key "100% fail rate: broken" "$result" ".isBroken" "true"
assert_json_key "100% fail rate: failRate=100" "$result" ".failRate" "100"

# Test: confidence at 50 samples = 100%
result=$(calculate_flakiness 25 25)
assert_json_key "confidence at 50 samples: 100%" "$result" ".confidence" "100"

# Test: confidence at 10 samples = 20%
result=$(calculate_flakiness 5 5)
assert_json_key "confidence at 10 samples: 20%" "$result" ".confidence" "20"

# Test: passCount/failCount returned
result=$(calculate_flakiness 30 20)
assert_json_key "passCount returned" "$result" ".passCount" "30"
assert_json_key "failCount returned" "$result" ".failCount" "20"

# ─── should_retry tests ───────────────────────────────────────────────────

# Test: flaky + not broken + attempt 0 → retry
should_retry "true" "false" 0 3
assert_eq "should retry: flaky, attempt 0" "0" "$?"

# Test: flaky + not broken + attempt 2 → retry
should_retry "true" "false" 2 3
assert_eq "should retry: flaky, attempt 2" "0" "$?"

# Test: flaky + not broken + attempt 3 → no retry (exhausted)
should_retry "true" "false" 3 3 || retry_exit=$?
assert_eq "no retry: attempt exhausted" "1" "${retry_exit:-0}"

# Test: not flaky → no retry
should_retry "false" "false" 0 3 || retry_exit=$?
assert_eq "no retry: not flaky" "1" "${retry_exit:-0}"

# Test: broken → no retry
should_retry "true" "true" 0 3 || retry_exit=$?
assert_eq "no retry: broken test" "1" "${retry_exit:-0}"

cleanup_test_env
print_test_results
