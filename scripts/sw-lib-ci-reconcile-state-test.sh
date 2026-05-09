#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/ci-reconcile-state test — Unit tests                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: ci-reconcile-state Tests"

setup_test_env "sw-lib-ci-reconcile-state-test"
_test_cleanup_hook() { cleanup_test_env; }

# Source the helper under test
source "$SCRIPT_DIR/lib/ci-reconcile-state.sh"

# ─── Fixture builder ─────────────────────────────────────────────────────────
make_state_file() {
    local filepath="$1"
    local status="$2"
    shift 2
    # remaining args: "stage:outcome" pairs to put in the log
    cat > "$filepath" <<YAML
---
pipeline: autonomous
goal: "Test goal"
status: ${status}
current_stage: build
---

## Log

YAML
    while [[ $# -gt 0 ]]; do
        local pair="$1"; shift
        local stage="${pair%%:*}"
        local outcome="${pair#*:}"
        printf '### %s (12:00:00)\n' "$stage" >> "$filepath"
        printf '%s (1m 0s)\n\n' "$outcome" >> "$filepath"
    done
}

# ─── Test 1: running → interrupted, extracts completed stages ────────────────
print_test_section "1. running → interrupted + log extraction"
STATE="$TEST_TEMP_DIR/state1.md"
make_state_file "$STATE" "running" \
    "intake:complete" "plan:complete" "design:complete" \
    "build:complete" "test:complete" "review:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten to interrupted" "interrupted" "$rewritten_status"
assert_contains "intake in result" "$result" "intake"
assert_contains "plan in result" "$result" "plan"
assert_contains "design in result" "$result" "design"
assert_contains "build in result" "$result" "build"
assert_contains "test in result" "$result" "test"
assert_contains "review in result" "$result" "review"

# ─── Test 2: paused → interrupted ────────────────────────────────────────────
print_test_section "2. paused → interrupted"
STATE="$TEST_TEMP_DIR/state2.md"
make_state_file "$STATE" "paused" "intake:complete" "plan:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten to interrupted" "interrupted" "$rewritten_status"
assert_contains "intake in result" "$result" "intake"
assert_contains "plan in result" "$result" "plan"

# ─── Test 3: failed — left alone, empty stdout ───────────────────────────────
print_test_section "3. failed — untouched"
STATE="$TEST_TEMP_DIR/state3.md"
make_state_file "$STATE" "failed" "intake:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (failed)" "failed" "$rewritten_status"
assert_eq "empty stdout for failed" "" "$result"

# ─── Test 4: interrupted — left alone, empty stdout ──────────────────────────
print_test_section "4. interrupted — untouched"
STATE="$TEST_TEMP_DIR/state4.md"
make_state_file "$STATE" "interrupted" "intake:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (interrupted)" "interrupted" "$rewritten_status"
assert_eq "empty stdout for interrupted" "" "$result"

# ─── Test 5: stuck_cycling — left alone ──────────────────────────────────────
print_test_section "5. stuck_cycling — untouched"
STATE="$TEST_TEMP_DIR/state5.md"
make_state_file "$STATE" "stuck_cycling" "intake:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (stuck_cycling)" "stuck_cycling" "$rewritten_status"
assert_eq "empty stdout for stuck_cycling" "" "$result"

# ─── Test 6: mixed-case stage IDs (COMPOUND_QUALITY, test_2) ─────────────────
print_test_section "6. mixed-case stage IDs"
STATE="$TEST_TEMP_DIR/state6.md"
make_state_file "$STATE" "running" \
    "intake:complete" "COMPOUND_QUALITY:complete" "test_2:complete"

result="$(ci_reconcile_state "$STATE")"

assert_contains "COMPOUND_QUALITY in result" "$result" "COMPOUND_QUALITY"
assert_contains "test_2 in result" "$result" "test_2"
assert_contains "intake in result" "$result" "intake"

# ─── Test 7: stage appears failed then later complete → counted as complete ───
print_test_section "7. stage with retry (failed then complete)"
STATE="$TEST_TEMP_DIR/state7.md"
make_state_file "$STATE" "running" \
    "build:Build loop iteration 1" \
    "build:complete"

result="$(ci_reconcile_state "$STATE")"

assert_contains "build in result (completed after retry)" "$result" "build"
# Should appear exactly once (deduped)
count="$(echo "$result" | tr ',' '\n' | grep -c "^build$" || echo 0)"
assert_eq "build deduped to single occurrence" "1" "$count"

# ─── Test 8: no ## Log section → empty stdout, status still rewritten ─────────
print_test_section "8. no ## Log section"
STATE="$TEST_TEMP_DIR/state8.md"
cat > "$STATE" <<YAML
---
status: running
current_stage: build
---
YAML

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten even without log" "interrupted" "$rewritten_status"
assert_eq "empty stdout when no log section" "" "$result"

# ─── Test 9: non-existent file → empty stdout, exit 0 ────────────────────────
print_test_section "9. non-existent file"
result="$(ci_reconcile_state "$TEST_TEMP_DIR/does-not-exist.md")"
exit_code=$?

assert_eq "exit code 0 for missing file" "0" "$exit_code"
assert_eq "empty stdout for missing file" "" "$result"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
