#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-lib-test-retry-test.sh — Test retry handler unit tests              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "test-retry"

export FLAKINESS_DB="$TEST_TEMP_DIR/home/.shipwright/flakiness-db.jsonl"

source "$SCRIPT_DIR/lib/test-retry.sh"

print_test_header "Test Retry Handler"

# ─── Setup: seed a flaky test in the DB ────────────────────────────────────

# 15 pass + 5 fail = 25% fail rate → flaky
for i in $(seq 1 15); do
    record_test_result "retry-test-1" "pass" 50 "seed-$i"
done
for i in $(seq 1 5); do
    record_test_result "retry-test-1" "fail" 50 "seed-fail-$i"
done

# Seed a broken test (all fails)
for i in $(seq 1 10); do
    record_test_result "retry-broken" "fail" 50 "broken-$i"
done

# Seed a stable test (all passes)
for i in $(seq 1 10); do
    record_test_result "retry-stable" "pass" 50 "stable-$i"
done

# ─── retry_flaky_test: flaky test passes on retry ──────────────────────────

# Create a test script that fails first time, passes second
cat > "$TEST_TEMP_DIR/bin/flaky-test" <<'SCRIPT'
#!/usr/bin/env bash
COUNTER_FILE="${FLAKY_COUNTER:-/tmp/flaky-counter}"
count=0
[[ -f "$COUNTER_FILE" ]] && count=$(cat "$COUNTER_FILE")
count=$((count + 1))
echo "$count" > "$COUNTER_FILE"
if [[ "$count" -le 1 ]]; then
    exit 1  # fail first attempt
fi
exit 0  # pass second attempt
SCRIPT
chmod +x "$TEST_TEMP_DIR/bin/flaky-test"

export FLAKY_COUNTER="$TEST_TEMP_DIR/flaky-counter"
rm -f "$FLAKY_COUNTER"

result=$(retry_flaky_test "retry-test-1" "$TEST_TEMP_DIR/bin/flaky-test" 3 30)
assert_json_key "flaky test eventually passes" "$result" ".passed" "true"
assert_json_key "flaky test took 2 attempts" "$result" ".attempts" "2"
assert_json_key "marked as flaky" "$result" ".isFlaky" "true"

# ─── retry_flaky_test: broken test not retried ─────────────────────────────

result=$(retry_flaky_test "retry-broken" "false" 3 30) || true
assert_json_key "broken test: not retried (reason)" "$result" ".reason" "not_flaky"

# ─── retry_flaky_test: stable test not retried ─────────────────────────────

result=$(retry_flaky_test "retry-stable" "false" 3 30) || true
assert_json_key "stable test: not retried" "$result" ".reason" "not_flaky"

# ─── retry_flaky_test: all retries exhausted ───────────────────────────────

# Reset counter so all attempts fail
rm -f "$FLAKY_COUNTER"
cat > "$TEST_TEMP_DIR/bin/always-fail" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "$TEST_TEMP_DIR/bin/always-fail"

retry_exit=0
result=$(retry_flaky_test "retry-test-1" "$TEST_TEMP_DIR/bin/always-fail" 3 30) || retry_exit=$?
assert_eq "exhausted retries returns exit 1" "1" "$retry_exit"
assert_json_key "exhausted retries: passed=false" "$result" ".passed" "false"
assert_json_key "exhausted retries: 3 attempts" "$result" ".attempts" "3"

# ─── get_retry_summary ────────────────────────────────────────────────────

summary=$(get_retry_summary)
summary_count=$(echo "$summary" | jq 'length')
assert_gt "retry summary has entries" "$summary_count" 0

cleanup_test_env
print_test_results
