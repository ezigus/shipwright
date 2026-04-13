#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/loop-restart test — Unit tests for loop state            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: loop-restart Tests"

setup_test_env "sw-lib-loop-restart-test"
_test_cleanup_hook() { cleanup_test_env; }

# ── Required variables ────────────────────────────────────────────────────────
export STATE_FILE="$TEST_TEMP_DIR/loop-state.md"
export GOAL=""
export ORIGINAL_GOAL=""
export ITERATION=1
export MAX_ITERATIONS=10
export MAX_ITERATIONS_EXPLICIT=false
export cli_max_iterations=10
export STATUS="running"
export TEST_CMD=""
export MODEL="sonnet"
export AGENTS=1
export CONSECUTIVE_FAILURES=0
export TOTAL_COMMITS=0
export AUDIT_ENABLED=false
export AUDIT_AGENT_ENABLED=false
export QUALITY_GATES_ENABLED=false
export DOD_FILE=""
export AUTO_EXTEND=false
export EXTENSION_COUNT=0
export MAX_EXTENSIONS=3
export DOD_DIFF_MAX_LINES=500
export HOLISTIC_DIFF_MAX_LINES=1000
export LOG_ENTRIES=""
export LOOP_START_COMMIT="abc123"   # pre-set to skip git call in resume_state
export PROJECT_ROOT="$TEST_TEMP_DIR" # non-git dir → git calls fail gracefully
export DIM="" RESET="" BOLD=""

# ── Stub functions ────────────────────────────────────────────────────────────
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
info()      { echo "▸ $*"; }
success()   { echo "✓ $*"; }
warn()      { echo "⚠ $*"; }
error()     { echo "✗ $*" >&2; }

# Source the module (module guard is cleared so we get a fresh load)
_LOOP_RESTART_LOADED=""
source "$SCRIPT_DIR/lib/loop-restart.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# write_state / resume_state — multi-line GOAL round-trip (issue #348)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "write_state / resume_state multi-line GOAL round-trip"

# --- Test 1: single-line goal round-trip (regression guard) ---
GOAL="simple loop goal" ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
if [[ "$GOAL" == "simple loop goal" ]]; then
    assert_pass "single-line loop goal round-trip"
else
    assert_fail "single-line loop goal round-trip" "got: $GOAL"
fi

# --- Test 2: multi-line goal write — goal value must be escaped (contains literal \n not real newlines) ---
GOAL="$(printf 'Fix loop tests\n\nKNOWN FIX: check src/foo.sh\nRun: npm test')" ORIGINAL_GOAL=""
write_state
_goal_line=$(grep '^goal:' "$STATE_FILE" | sed 's/^goal: *"//;s/" *$//')
# With the fix, newlines in GOAL are encoded as the two-char sequence \n in the file.
# [[ glob pattern $'\\n' matches literal backslash + n ]]
if [[ "$_goal_line" == *$'\\n'* ]]; then
    assert_pass "multi-line loop goal write encodes newlines as \\n"
else
    assert_fail "multi-line loop goal write encodes newlines as \\n" "no escaped \\n found; first 60 chars: ${_goal_line:0:60}"
fi

# --- Test 3: multi-line goal — full round-trip (write then read back) ---
GOAL=""
resume_state 2>/dev/null
_expected="$(printf 'Fix loop tests\n\nKNOWN FIX: check src/foo.sh\nRun: npm test')"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "multi-line loop goal full round-trip: all content restored"
else
    assert_fail "multi-line loop goal full round-trip: all content restored" "first 80 chars: $(printf '%s' "$GOAL" | head -c 80)"
fi

# --- Test 4: empty goal write — no crash ---
GOAL="" ORIGINAL_GOAL=""
write_state
assert_pass "empty loop goal write does not crash"

# --- Test 5: goal containing a literal \n (two chars: backslash + n) ---
# Full backslash-escaping scheme: literal \n is stored as \\n and round-trips correctly.
GOAL=$'Contains a literal \\n backslash-n and a real\nnewline' ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
if [[ "$GOAL" == $'Contains a literal \\n backslash-n and a real\nnewline' ]]; then
    assert_pass "literal \\n in loop goal round-trips correctly"
else
    assert_fail "literal \\n in loop goal round-trips correctly" "got: $(printf '%s' "$GOAL" | head -c 80)"
fi

# --- Test 7: legacy polluted goal with injection-style content is cleaned on resume ---
# When a state file contains a goal with compound_quality injection content (from a previous
# run bug), resume_state should strip the pollution and restore the original goal.
GOAL="$(printf 'Original goal\n\nBLOCKING ISSUES — fix all of these before merge:\n- test_auth_flow fails\n\nFull review context:\nSee audit log for details')" ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
# After resume, the goal should be stripped of the injection content
_expected="Original goal"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "resume_state strips legacy polluted BLOCKING ISSUES injection"
else
    assert_fail "resume_state strips legacy polluted BLOCKING ISSUES injection" "got: $(printf '%s' "$GOAL" | head -c 80)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# write_state — ORIGINAL_GOAL protection (issue #362)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "write_state ORIGINAL_GOAL protection (issue #362)"

# Reload the real write_state — do NOT re-source loop-restart.sh; use fresh module guard
unset -f write_state
unset -f resume_state
_LOOP_RESTART_LOADED=""
source "$SCRIPT_DIR/lib/loop-restart.sh"

# Test A: write_state uses ORIGINAL_GOAL when GOAL is mutated
GOAL="Original pipeline goal"
ORIGINAL_GOAL="Original pipeline goal"
GOAL="$(printf 'Original pipeline goal\n\nBLOCKING ISSUES — fix all of these before merge: tests fail')"
write_state
_saved=$(grep '^goal:' "$STATE_FILE" | sed 's/^goal: *"//;s/" *$//')
assert_contains "write_state writes ORIGINAL_GOAL not mutated GOAL" "$_saved" "Original pipeline goal"
_blocking_count=$(echo "$_saved" | grep -c 'BLOCKING ISSUES' || true)
assert_eq "write_state does not write BLOCKING ISSUES" "0" "$_blocking_count"

# Test B: ORIGINAL_GOAL empty → falls back to GOAL (no regression)
GOAL="Fallback goal"
ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
assert_eq "write_state falls back to GOAL when ORIGINAL_GOAL empty" "Fallback goal" "$GOAL"

# Test C: resume_state strips BLOCKING ISSUES from legacy polluted state
ORIGINAL_GOAL=""
GOAL="$(printf 'Clean goal\n\nBLOCKING ISSUES — fix all: test fails\n\nFull feedback...')"
write_state
GOAL=""
ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "resume_state strips BLOCKING ISSUES on load" "Clean goal" "$GOAL"
assert_eq "resume_state sets ORIGINAL_GOAL after strip" "Clean goal" "$ORIGINAL_GOAL"

# Test D: resume_state strips HUMAN FEEDBACK from legacy polluted state
ORIGINAL_GOAL=""
GOAL="$(printf 'Clean goal\n\nHUMAN FEEDBACK (received after iteration 3): fix the auth bug')"
write_state
GOAL=""
ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "resume_state strips HUMAN FEEDBACK on load" "Clean goal" "$GOAL"

# Test E: resume_state strips KNOWN FIX prefix from legacy polluted state
ORIGINAL_GOAL=""
GOAL="$(printf 'KNOWN FIX (from past success): retry logic\n\nClean goal')"
write_state
GOAL=""
ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "resume_state strips KNOWN FIX prefix on load" "Clean goal" "$GOAL"

# Test F: no unbounded growth across 2 compound_quality cycles
GOAL="Original"
ORIGINAL_GOAL="Original"
GOAL="$(printf 'Original\n\nBLOCKING ISSUES — something: fail')"
write_state
GOAL=""
ORIGINAL_GOAL=""
resume_state 2>/dev/null
ORIGINAL_GOAL="$GOAL"
GOAL="$(printf '%s\n\nBLOCKING ISSUES — something else: fail' "$GOAL")"
write_state
GOAL=""
ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "no unbounded growth across 2 compound_quality cycles" "Original" "$GOAL"

print_test_results
