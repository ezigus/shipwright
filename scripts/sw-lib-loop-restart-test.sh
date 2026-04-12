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
GOAL="simple loop goal"
write_state
GOAL=""
resume_state 2>/dev/null
if [[ "$GOAL" == "simple loop goal" ]]; then
    assert_pass "single-line loop goal round-trip"
else
    assert_fail "single-line loop goal round-trip" "got: $GOAL"
fi

# --- Test 2: multi-line goal write — goal value must be escaped (contains literal \n not real newlines) ---
GOAL="$(printf 'Fix loop tests\n\nKNOWN FIX: check src/foo.sh\nRun: npm test')"
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
GOAL=""
write_state
assert_pass "empty loop goal write does not crash"

# --- Test 5: goal with injection-style content (compound quality feedback pattern) ---
GOAL="$(printf 'Original goal\n\nBLOCKING ISSUES — fix all of these before merge:\n- test_auth_flow fails\n\nFull review context:\nSee audit log for details')"
write_state
GOAL=""
resume_state 2>/dev/null
_expected="$(printf 'Original goal\n\nBLOCKING ISSUES — fix all of these before merge:\n- test_auth_flow fails\n\nFull review context:\nSee audit log for details')"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "compound quality feedback injection round-trip"
else
    assert_fail "compound quality feedback injection round-trip" "first 80 chars: $(printf '%s' "$GOAL" | head -c 80)"
fi

print_test_results
