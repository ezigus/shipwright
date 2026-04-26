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
# Simulates a state file written by the OLD buggy write_state (no original_goal: field).
# resume_state should strip the pollution and restore the original goal.
_t7_goal="$(printf 'Original goal\n\nBLOCKING ISSUES — fix all of these before merge:\n- test_auth_flow fails\n\nFull review context:\nSee audit log for details')"
_t7_esc="${_t7_goal//\\/\\\\}"
_t7_esc="${_t7_esc//$'\n'/\\n}"
{
    printf -- '---\n'
    printf 'goal: "%s"\n' "$_t7_esc"
    printf 'iteration: 1\nmax_iterations: 10\nstatus: running\ntest_cmd: ""\nmodel: sonnet\nagents: 1\n'
    printf 'consecutive_failures: 0\ntotal_commits: 0\naudit_enabled: false\naudit_agent_enabled: false\n'
    printf 'quality_gates_enabled: false\ndod_file: ""\nauto_extend: false\nextension_count: 0\n'
    printf 'max_extensions: 3\ndod_diff_max_lines: 500\nholistic_diff_max_lines: 1000\n'
    printf -- '---\n\n## Log\n'
} > "$STATE_FILE"
GOAL=""
resume_state 2>/dev/null
_expected="Original goal"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "resume_state strips legacy polluted BLOCKING ISSUES injection"
else
    assert_fail "resume_state strips legacy polluted BLOCKING ISSUES injection" "got: $(printf '%s' "$GOAL" | head -c 80)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# write_state — ORIGINAL_GOAL protection (issues #362, Codex P1, Codex P2)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "write_state ORIGINAL_GOAL protection (issue #362 + Codex P1/P2)"

# Reload the real write_state — do NOT re-source loop-restart.sh; use fresh module guard
unset -f write_state
unset -f resume_state
_LOOP_RESTART_LOADED=""
source "$SCRIPT_DIR/lib/loop-restart.sh"

# Helper: write a legacy state file (no original_goal: field) simulating old buggy write_state
_write_legacy_loop_state() {
    local polluted_goal="$1"
    local _esc="${polluted_goal//\\/\\\\}"
    _esc="${_esc//$'\n'/\\n}"
    {
        printf -- '---\n'
        printf 'goal: "%s"\n'           "$_esc"
        printf 'iteration: %s\n'        "$ITERATION"
        printf 'max_iterations: %s\n'   "$MAX_ITERATIONS"
        printf 'status: %s\n'           "${STATUS:-running}"
        printf 'test_cmd: "%s"\n'       "${TEST_CMD:-}"
        printf 'model: %s\n'            "${MODEL:-sonnet}"
        printf 'agents: %s\n'           "${AGENTS:-1}"
        printf 'consecutive_failures: %s\n' "${CONSECUTIVE_FAILURES:-0}"
        printf 'total_commits: %s\n'    "${TOTAL_COMMITS:-0}"
        printf 'audit_enabled: %s\n'    "${AUDIT_ENABLED:-false}"
        printf 'audit_agent_enabled: %s\n'   "${AUDIT_AGENT_ENABLED:-false}"
        printf 'quality_gates_enabled: %s\n' "${QUALITY_GATES_ENABLED:-false}"
        printf 'dod_file: "%s"\n'       "${DOD_FILE:-}"
        printf 'auto_extend: %s\n'      "${AUTO_EXTEND:-false}"
        printf 'extension_count: %s\n'  "${EXTENSION_COUNT:-0}"
        printf 'max_extensions: %s\n'   "${MAX_EXTENSIONS:-3}"
        printf 'dod_diff_max_lines: %s\n'       "${DOD_DIFF_MAX_LINES:-500}"
        printf 'holistic_diff_max_lines: %s\n'  "${HOLISTIC_DIFF_MAX_LINES:-1000}"
        printf -- '---\n\n'
        printf '## Log\n'
    } > "$STATE_FILE"
}

# Test A: write_state uses ORIGINAL_GOAL when GOAL is mutated
GOAL="Original pipeline goal"
ORIGINAL_GOAL="Original pipeline goal"
GOAL="$(printf 'Original pipeline goal\n\nBLOCKING ISSUES — fix all of these before merge: tests fail')"
write_state
_saved=$(grep '^goal:' "$STATE_FILE" | sed 's/^goal: *"//;s/" *$//')
assert_contains "write_state writes ORIGINAL_GOAL not mutated GOAL" "$_saved" "Original pipeline goal"
_blocking_count=$(echo "$_saved" | grep -c 'BLOCKING ISSUES' || true)
assert_eq "write_state does not write BLOCKING ISSUES" "0" "$_blocking_count"

# Test A2: write_state persists original_goal field
_orig_saved=$(grep '^original_goal:' "$STATE_FILE" | sed 's/^original_goal: *"//;s/" *$//')
assert_eq "write_state persists original_goal field" "Original pipeline goal" "$_orig_saved"

# Test B: ORIGINAL_GOAL empty → bootstrapped from GOAL on first non-empty write
GOAL="Fallback goal"
ORIGINAL_GOAL=""
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "write_state bootstraps ORIGINAL_GOAL from GOAL when not set" "Fallback goal" "$GOAL"
assert_eq "resume_state reads ORIGINAL_GOAL from original_goal field" "Fallback goal" "$ORIGINAL_GOAL"

# Test C: legacy state file — resume_state strips BLOCKING ISSUES (no original_goal field)
_write_legacy_loop_state "$(printf 'Clean goal\n\nBLOCKING ISSUES — fix all: test fails\n\nFull feedback...')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips BLOCKING ISSUES" "Clean goal" "$GOAL"
assert_eq "legacy: resume_state sets ORIGINAL_GOAL after strip" "Clean goal" "$ORIGINAL_GOAL"

# Test D: legacy state file — resume_state strips HUMAN FEEDBACK (no original_goal field)
_write_legacy_loop_state "$(printf 'Clean goal\n\nHUMAN FEEDBACK (received after iteration 3): fix the auth bug')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips HUMAN FEEDBACK" "Clean goal" "$GOAL"

# Test E: legacy state file — resume_state strips KNOWN FIX prefix (no original_goal field)
_write_legacy_loop_state "$(printf 'KNOWN FIX (from past success): retry logic\n\nClean goal')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips KNOWN FIX prefix" "Clean goal" "$GOAL"

# Test E2 (Codex P2): new state file — legitimate goal with sentinel-like text is NOT truncated
GOAL="Fix the BLOCKING ISSUES in the auth module"
ORIGINAL_GOAL="Fix the BLOCKING ISSUES in the auth module"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "P2: legitimate goal with sentinel text not truncated" "Fix the BLOCKING ISSUES in the auth module" "$GOAL"

# Test F: no unbounded growth across 2 compound_quality cycles
GOAL="Original"
ORIGINAL_GOAL="Original"
GOAL="$(printf 'Original\n\nBLOCKING ISSUES — something: fail')"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
GOAL="$(printf '%s\n\nBLOCKING ISSUES — something else: fail' "$GOAL")"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "no unbounded growth across 2 compound_quality cycles" "Original" "$GOAL"

# ═══════════════════════════════════════════════════════════════════════════════
# resume_state — 'stuck' terminal status handling (issue #443)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "resume_state stuck status handling (issue #443)"

# Helper: invoke resume_state in a subshell so its `exit` does not kill the test
# runner, while still capturing stderr (where warn writes) and the resulting
# STATUS so we can assert short-circuit behavior.
_run_resume_capture() {
    # Run in a subshell with fresh stderr capture; export marker so we can
    # detect whether resume_state actually returned (non-stuck/non-complete) or
    # short-circuited via exit (stuck/complete terminal states).
    local _out
    _out="$(
        set +e
        resume_state 2>&1
        printf 'AFTER_RESUME_STATUS=%s\n' "${STATUS:-}"
    )"
    printf '%s' "$_out"
}

# --- G1: status=stuck causes resume_state to short-circuit via `exit 0` ---
# Detection: when the function exits, the AFTER_RESUME_STATUS marker line never
# prints inside the subshell. So marker ABSENT == short-circuited correctly.
GOAL="some active goal" ORIGINAL_GOAL="some active goal"
STATUS="stuck"
write_state
GOAL="" ORIGINAL_GOAL=""
STATUS="stuck"  # simulate parser populating STATUS before guard check
_g1_out="$(_run_resume_capture)"
if [[ "$_g1_out" != *"AFTER_RESUME_STATUS="* ]]; then
    assert_pass "G1: resume_state short-circuits via exit when status is stuck"
else
    assert_fail "G1: resume_state short-circuits via exit when status is stuck" \
        "marker present (function did not exit): $(echo "$_g1_out" | grep AFTER_RESUME_STATUS)"
fi

# --- G1b: warning output mentions the word "stuck" so users know why ---
if [[ "$_g1_out" == *stuck* ]]; then
    assert_pass "G1b: stuck-status warning output mentions 'stuck'"
else
    assert_fail "G1b: stuck-status warning output mentions 'stuck'" \
        "no 'stuck' found in: $(printf '%s' "$_g1_out" | head -c 200)"
fi

# --- G2: regression — status=running still resumes (does not short-circuit) ---
# When the function falls through to the end, it explicitly sets STATUS="running"
# and returns; the marker line then prints with STATUS=running.
GOAL="resumable goal" ORIGINAL_GOAL="resumable goal"
STATUS="running"
write_state
GOAL="" ORIGINAL_GOAL=""
STATUS="running"
_g2_out="$(_run_resume_capture)"
if [[ "$_g2_out" == *"AFTER_RESUME_STATUS=running"* ]]; then
    assert_pass "G2: regression — running status still resumes through to STATUS reset"
else
    assert_fail "G2: regression — running status still resumes through to STATUS reset" \
        "marker line: $(echo "$_g2_out" | grep AFTER_RESUME_STATUS)"
fi

# --- G3: regression — status=complete still short-circuits via exit ---
GOAL="finished goal" ORIGINAL_GOAL="finished goal"
STATUS="complete"
write_state
GOAL="" ORIGINAL_GOAL=""
STATUS="complete"
_g3_out="$(_run_resume_capture)"
if [[ "$_g3_out" != *"AFTER_RESUME_STATUS="* ]]; then
    assert_pass "G3: regression — complete status still short-circuits resume via exit"
else
    assert_fail "G3: regression — complete status still short-circuits resume via exit" \
        "marker present (function did not exit): $(echo "$_g3_out" | grep AFTER_RESUME_STATUS)"
fi

# --- G4: write_state round-trips STATUS=stuck verbatim to the file ---
GOAL="round-trip goal" ORIGINAL_GOAL="round-trip goal"
STATUS="stuck"
write_state
_g4_status_line=$(grep '^status:' "$STATE_FILE" | head -1)
if [[ "$_g4_status_line" == "status: stuck" ]]; then
    assert_pass "G4: write_state round-trips STATUS=stuck verbatim"
else
    assert_fail "G4: write_state round-trips STATUS=stuck verbatim" \
        "got: $_g4_status_line"
fi

# --- G5: show_summary in sw-loop.sh has an explicit 'stuck)' case arm ---
_g5_count=$(grep -c '^[[:space:]]*stuck)' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
_g5_count="${_g5_count:-0}"
if [[ "$_g5_count" -ge 1 ]]; then
    assert_pass "G5: sw-loop.sh show_summary has an explicit 'stuck)' case arm"
else
    assert_fail "G5: sw-loop.sh show_summary has an explicit 'stuck)' case arm" \
        "expected >=1 occurrence of 'stuck)' in sw-loop.sh, got: $_g5_count"
fi

# --- G6: that case arm's display string contains the word 'stuck' (legible) ---
_g6_arm=$(grep -E '^[[:space:]]*stuck\)' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ "$_g6_arm" == *[Ss]tuck* ]]; then
    assert_pass "G6: stuck) case arm display string mentions 'stuck'"
else
    assert_fail "G6: stuck) case arm display string mentions 'stuck'" \
        "got arm: $_g6_arm"
fi

# Emit explicit "$PASS/$TOTAL pass" as the final visible line for DoD audit
# parsers. print_test_results() exits internally, so we install an EXIT trap
# that wraps the helper's existing cleanup hook to print the count line last.
_emit_pass_count_then_cleanup() {
    printf '%s/%s pass\n' "$PASS" "$TOTAL"
    _test_harness_cleanup
}
trap '_emit_pass_count_then_cleanup' EXIT

print_test_results
