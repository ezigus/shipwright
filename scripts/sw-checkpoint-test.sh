#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright checkpoint test — Validate checkpoint save/restore           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/checkpoints"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls stat shasum; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        elif [[ "${2:-}" == "HEAD" ]]; then echo "abc1234def5678"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

SRC="$SCRIPT_DIR/sw-checkpoint.sh"

# Run tests from within mock repo so CHECKPOINT_DIR is relative to it
cd "$TEST_TEMP_DIR/repo"

echo ""
print_test_header "shipwright checkpoint test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -qF 'set -euo pipefail' "$SRC" 2>/dev/null; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -qF 'trap' "$SRC" 2>/dev/null; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -qE '^VERSION=' "$SRC" 2>/dev/null; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 2. Help ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

HELP_OUT=$(bash "$SRC" help 2>&1) || true

assert_contains "help exits 0 and contains USAGE" "$HELP_OUT" "USAGE"
assert_contains "help lists 'save' subcommand" "$HELP_OUT" "save"
assert_contains "help lists 'restore' subcommand" "$HELP_OUT" "restore"
assert_contains "help lists 'list' subcommand" "$HELP_OUT" "list"
assert_contains "help lists 'clear' subcommand" "$HELP_OUT" "clear"
assert_contains "help lists 'expire' subcommand" "$HELP_OUT" "expire"

HELP2=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help alias works" "$HELP2" "USAGE"

HELP3=$(bash "$SRC" -h 2>&1) || true
assert_contains "-h alias works" "$HELP3" "USAGE"

echo ""

# ─── 3. Error Handling ───────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_fail "Unknown command exits non-zero"
else
    assert_pass "Unknown command exits non-zero"
fi

echo ""

# ─── 4. Save subcommand ─────────────────────────────────────────────────────
echo -e "${BOLD}  Save Subcommand${RESET}"

# save without --stage exits non-zero
if bash "$SRC" save 2>/dev/null; then
    assert_fail "save without --stage exits non-zero"
else
    assert_pass "save without --stage exits non-zero"
fi

# save with --stage creates checkpoint file
bash "$SRC" save --stage build --iteration 5 2>/dev/null || true
CKPT=".claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
if [[ -f "$CKPT" ]]; then
    assert_pass "save creates checkpoint file"
else
    assert_fail "save creates checkpoint file"
fi

# Verify checkpoint is valid JSON
if jq empty "$CKPT" 2>/dev/null; then
    assert_pass "Checkpoint is valid JSON"
else
    assert_fail "Checkpoint is valid JSON"
fi

# Verify stage field
STAGE_VAL=$(jq -r '.stage' "$CKPT" 2>/dev/null || echo "")
assert_eq "Checkpoint stage field correct" "build" "$STAGE_VAL"

# Verify iteration field
ITER_VAL=$(jq -r '.iteration' "$CKPT" 2>/dev/null || echo "")
assert_eq "Checkpoint iteration field correct" "5" "$ITER_VAL"

# Verify git_sha is populated (from mock git)
SHA_VAL=$(jq -r '.git_sha' "$CKPT" 2>/dev/null || echo "")
if [[ -n "$SHA_VAL" && "$SHA_VAL" != "null" ]]; then
    assert_pass "Checkpoint git_sha populated"
else
    assert_fail "Checkpoint git_sha populated"
fi

# save with --tests-passing flag
bash "$SRC" save --stage test --tests-passing 2>/dev/null || true
CKPT2=".claude/pipeline-artifacts/checkpoints/test-checkpoint.json"
TESTS_VAL=$(jq -r '.tests_passing' "$CKPT2" 2>/dev/null || echo "")
assert_eq "save --tests-passing sets true" "true" "$TESTS_VAL"

# save with --files-modified
bash "$SRC" save --stage review --files-modified "src/a.ts,src/b.ts" 2>/dev/null || true
CKPT3=".claude/pipeline-artifacts/checkpoints/review-checkpoint.json"
FILES_COUNT=$(jq '.files_modified | length' "$CKPT3" 2>/dev/null || echo "0")
assert_eq "save --files-modified stores 2 files" "2" "$FILES_COUNT"

# save with --loop-state
bash "$SRC" save --stage deploy --loop-state running 2>/dev/null || true
CKPT4=".claude/pipeline-artifacts/checkpoints/deploy-checkpoint.json"
LOOP_VAL=$(jq -r '.loop_state' "$CKPT4" 2>/dev/null || echo "")
assert_eq "save --loop-state stores state" "running" "$LOOP_VAL"

# Verify created_at timestamp is present
CREATED=$(jq -r '.created_at' "$CKPT" 2>/dev/null || echo "")
if [[ -n "$CREATED" && "$CREATED" != "null" ]]; then
    assert_pass "Checkpoint created_at timestamp present"
else
    assert_fail "Checkpoint created_at timestamp present"
fi

echo ""

# ─── 5. Restore subcommand ──────────────────────────────────────────────────
echo -e "${BOLD}  Restore Subcommand${RESET}"

# restore returns checkpoint JSON
OUT=$(bash "$SRC" restore --stage build 2>/dev/null) || true
if echo "$OUT" | jq -e '.stage' >/dev/null 2>&1; then
    assert_pass "restore returns checkpoint JSON"
else
    assert_fail "restore returns checkpoint JSON" "$OUT"
fi

RESTORED_STAGE=$(echo "$OUT" | jq -r '.stage' 2>/dev/null || echo "")
assert_eq "Restored checkpoint has correct stage" "build" "$RESTORED_STAGE"

# restore with missing stage exits non-zero
if bash "$SRC" restore --stage nonexistent 2>/dev/null; then
    assert_fail "restore missing stage exits non-zero"
else
    assert_pass "restore missing stage exits non-zero"
fi

# restore without --stage exits non-zero
if bash "$SRC" restore 2>/dev/null; then
    assert_fail "restore without --stage exits non-zero"
else
    assert_pass "restore without --stage exits non-zero"
fi

echo ""

# ─── 6. List subcommand ─────────────────────────────────────────────────────
echo -e "${BOLD}  List Subcommand${RESET}"

LIST_OUT=$(bash "$SRC" list 2>&1) || true
assert_contains "list shows Checkpoints header" "$LIST_OUT" "Checkpoints"
assert_contains "list shows build checkpoint" "$LIST_OUT" "build"
assert_contains "list shows checkpoint count" "$LIST_OUT" "checkpoint(s)"

# list with no checkpoints
rm -f .claude/pipeline-artifacts/checkpoints/*-checkpoint.json
LIST_OUT2=$(bash "$SRC" list 2>&1) || true
assert_contains "list with no checkpoints shows empty" "$LIST_OUT2" "No checkpoints found"

echo ""

# ─── 7. Clear subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Clear Subcommand${RESET}"

# Create some checkpoints first
bash "$SRC" save --stage build --iteration 1 2>/dev/null || true
bash "$SRC" save --stage test --iteration 2 2>/dev/null || true

# clear --stage removes specific checkpoint
bash "$SRC" clear --stage build 2>/dev/null || true
if [[ ! -f ".claude/pipeline-artifacts/checkpoints/build-checkpoint.json" ]]; then
    assert_pass "clear --stage removes specific checkpoint"
else
    assert_fail "clear --stage removes specific checkpoint"
fi

# The other checkpoint should still exist
if [[ -f ".claude/pipeline-artifacts/checkpoints/test-checkpoint.json" ]]; then
    assert_pass "clear --stage preserves other checkpoints"
else
    assert_fail "clear --stage preserves other checkpoints"
fi

# clear without args exits non-zero
if bash "$SRC" clear 2>/dev/null; then
    assert_fail "clear without args exits non-zero"
else
    assert_pass "clear without args exits non-zero"
fi

# clear --all removes all checkpoints
bash "$SRC" save --stage build --iteration 3 2>/dev/null || true
bash "$SRC" clear --all 2>/dev/null || true
REMAINING=$(find .claude/pipeline-artifacts/checkpoints -name "*-checkpoint.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "clear --all removes all checkpoints" "0" "$REMAINING"

echo ""

# ─── 8. Expire subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  Expire Subcommand${RESET}"

# expire with no checkpoints exits 0
if bash "$SRC" expire --hours 1 2>/dev/null; then
    assert_pass "expire with no checkpoints exits 0"
else
    assert_fail "expire with no checkpoints exits 0"
fi

echo ""

# ─── 9. Save-context / Restore-context ─────────────────────────────────────────
echo -e "${BOLD}  Save-context / Restore-context${RESET}"

# Create build context via save-context (SW_LOOP_* env vars)
export SW_LOOP_GOAL="Fix the auth bug"
export SW_LOOP_FINDINGS="Found issue in middleware"
export SW_LOOP_MODIFIED="src/auth.ts,src/middleware.ts"
export SW_LOOP_TEST_OUTPUT="1 test failed"
export SW_LOOP_ITERATION="5"
export SW_LOOP_STATUS="running"
bash "$SRC" save-context --stage build 2>/dev/null || true
CTX_FILE=".claude/pipeline-artifacts/checkpoints/build-claude-context.json"
if [[ -f "$CTX_FILE" ]]; then
    assert_pass "save-context creates claude-context.json"
else
    assert_fail "save-context creates claude-context.json"
fi

# Verify saved context contents
CTX_GOAL=$(jq -r '.goal // empty' "$CTX_FILE" 2>/dev/null || echo "")
CTX_ITER=$(jq -r '.iteration // 0' "$CTX_FILE" 2>/dev/null || echo "0")
assert_eq "Context goal saved correctly" "Fix the auth bug" "$CTX_GOAL"
assert_eq "Context iteration saved correctly" "5" "$CTX_ITER"

# restore-context exports both RESTORED_* and SW_LOOP_* (run in subshell, eval exports)
RESTORE_OUT=$(bash -c "source \"$SRC\" && checkpoint_restore_context build && echo \"RESTORED_GOAL=\$RESTORED_GOAL\" && echo \"SW_LOOP_GOAL=\$SW_LOOP_GOAL\"" 2>/dev/null) || true
assert_contains "restore-context exports RESTORED_GOAL" "$RESTORE_OUT" "RESTORED_GOAL=Fix the auth bug"
assert_contains "restore-context exports SW_LOOP_GOAL" "$RESTORE_OUT" "SW_LOOP_GOAL=Fix the auth bug"

echo ""

# ─── 10. Iteration Checkpoint Cycle ──────────────────────────────────────────
echo -e "${BOLD}  Iteration Checkpoint Cycle${RESET}"

# Save a checkpoint with full iteration data (simulating save_iteration_checkpoint)
bash "$SRC" save --stage build --iteration 7 \
    --git-sha "iter7sha" --tests-passing \
    --files-modified "src/a.ts,src/b.ts" \
    --loop-state running 2>/dev/null || true

ITER_CKPT=".claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
if [[ -f "$ITER_CKPT" ]]; then
    assert_pass "Iteration checkpoint file created"
else
    assert_fail "Iteration checkpoint file created"
fi

ITER_VAL=$(jq -r '.iteration' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration checkpoint has correct iteration" "7" "$ITER_VAL"

ITER_SHA=$(jq -r '.git_sha' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration checkpoint has correct git_sha" "iter7sha" "$ITER_SHA"

ITER_TESTS=$(jq -r '.tests_passing' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration checkpoint has tests_passing true" "true" "$ITER_TESTS"

ITER_STATE=$(jq -r '.loop_state' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration checkpoint has loop_state running" "running" "$ITER_STATE"

ITER_FILES=$(jq '.files_modified | length' "$ITER_CKPT" 2>/dev/null || echo "0")
assert_eq "Iteration checkpoint has 2 modified files" "2" "$ITER_FILES"

# Overwrite with iteration 8 — verify atomic overwrite
bash "$SRC" save --stage build --iteration 8 \
    --git-sha "iter8sha" --loop-state running 2>/dev/null || true
ITER_VAL2=$(jq -r '.iteration' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration overwrite updates to iteration 8" "8" "$ITER_VAL2"
ITER_SHA2=$(jq -r '.git_sha' "$ITER_CKPT" 2>/dev/null || echo "")
assert_eq "Iteration overwrite updates git_sha" "iter8sha" "$ITER_SHA2"

echo ""

# ─── 11. Cleanup on Completion ───────────────────────────────────────────────
echo -e "${BOLD}  Cleanup on Completion${RESET}"

# Create both checkpoint and context files
bash "$SRC" save --stage build --iteration 10 --loop-state complete 2>/dev/null || true
export SW_LOOP_GOAL="Test cleanup"
export SW_LOOP_ITERATION="10"
export SW_LOOP_STATUS="complete"
export SW_LOOP_TEST_OUTPUT=""
export SW_LOOP_FINDINGS=""
export SW_LOOP_MODIFIED=""
bash "$SRC" save-context --stage build 2>/dev/null || true

CKPT_FILE=".claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
CTX_FILE2=".claude/pipeline-artifacts/checkpoints/build-claude-context.json"

if [[ -f "$CKPT_FILE" ]] && [[ -f "$CTX_FILE2" ]]; then
    assert_pass "Both checkpoint and context files exist before clear"
else
    assert_fail "Both checkpoint and context files exist before clear"
fi

# Clear the build stage checkpoint (simulating clear_build_checkpoint)
bash "$SRC" clear --stage build 2>/dev/null || true

if [[ ! -f "$CKPT_FILE" ]]; then
    assert_pass "Checkpoint file removed after clear"
else
    assert_fail "Checkpoint file removed after clear"
fi

if [[ ! -f "$CTX_FILE2" ]]; then
    assert_pass "Context file removed after clear"
else
    assert_fail "Context file removed after clear"
fi

echo ""

# ─── 12. Crash Detection ────────────────────────────────────────────────────
echo -e "${BOLD}  Crash Detection (detect_interrupted_loop)${RESET}"

# Source loop-restart.sh to get detect_interrupted_loop
# Need to set up the environment it expects
LOOP_RESTART_SRC="$SCRIPT_DIR/lib/loop-restart.sh"
_LOOP_RESTART_LOADED=""  # Reset module guard

# Helper functions needed by loop-restart.sh
now_epoch() { date +%s 2>/dev/null || echo 0; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*"; }
success() { echo "OK: $*"; }
export -f now_epoch now_iso info warn error success 2>/dev/null || true

PROJECT_ROOT="$TEST_TEMP_DIR/repo"
STATE_FILE="$TEST_TEMP_DIR/repo/loop-state.md"
MAX_ITERATIONS=20
MAX_ITERATIONS_EXPLICIT=false
GOAL=""
TEST_CMD=""
MODEL="opus"
AGENTS=1
CONSECUTIVE_FAILURES=0
TOTAL_COMMITS=0
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
QUALITY_GATES_ENABLED=false
DOD_FILE=""
AUTO_EXTEND=false
EXTENSION_COUNT=0
MAX_EXTENSIONS=3
LOG_ENTRIES=""
STATUS=""
ITERATION=0
LOOP_START_COMMIT=""
DIM=""
RESET=""

source "$LOOP_RESTART_SRC"

# Test 1: No checkpoint file — should return 1 (no crash detected)
rm -f "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
rm -f "$STATE_FILE"
if detect_interrupted_loop 2>/dev/null; then
    assert_fail "No checkpoint → no crash detected (returns 1)"
else
    assert_pass "No checkpoint → no crash detected (returns 1)"
fi

# Test 2: Checkpoint exists with running state + state file running → crash detected
bash "$SRC" save --stage build --iteration 5 --loop-state running 2>/dev/null || true
cat > "$STATE_FILE" <<'STATEEOF'
---
goal: "Test goal"
iteration: 5
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-13T00:00:00Z
last_iteration_at: 2026-03-13T00:00:00Z
consecutive_failures: 0
total_commits: 3
audit_enabled: false
audit_agent_enabled: false
quality_gates_enabled: false
dod_file: ""
auto_extend: false
extension_count: 0
max_extensions: 3
---

## Log
STATEEOF

if detect_interrupted_loop 2>/dev/null; then
    assert_pass "Running checkpoint + running state → crash detected"
else
    assert_fail "Running checkpoint + running state → crash detected"
fi

# Test 3: Checkpoint exists but state file shows complete → no false positive
cat > "$STATE_FILE" <<'STATEEOF2'
---
goal: "Test goal"
iteration: 10
max_iterations: 20
status: complete
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-13T00:00:00Z
last_iteration_at: 2026-03-13T00:00:00Z
consecutive_failures: 0
total_commits: 5
audit_enabled: false
audit_agent_enabled: false
quality_gates_enabled: false
dod_file: ""
auto_extend: false
extension_count: 0
max_extensions: 3
---

## Log
STATEEOF2

if detect_interrupted_loop 2>/dev/null; then
    assert_fail "Complete state → no false positive (returns 1)"
else
    assert_pass "Complete state → no false positive (returns 1)"
fi

# Test 4: Checkpoint exists with interrupted state + state file interrupted → crash detected
bash "$SRC" save --stage build --iteration 3 --loop-state interrupted 2>/dev/null || true
cat > "$STATE_FILE" <<'STATEEOF3'
---
goal: "Test goal"
iteration: 3
max_iterations: 20
status: interrupted
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-13T00:00:00Z
last_iteration_at: 2026-03-13T00:00:00Z
consecutive_failures: 0
total_commits: 1
audit_enabled: false
audit_agent_enabled: false
quality_gates_enabled: false
dod_file: ""
auto_extend: false
extension_count: 0
max_extensions: 3
---

## Log
STATEEOF3

if detect_interrupted_loop 2>/dev/null; then
    assert_pass "Interrupted state → crash detected"
else
    assert_fail "Interrupted state → crash detected"
fi

# Test 5: Checkpoint exists but no state file → no crash detected
rm -f "$STATE_FILE"
if detect_interrupted_loop 2>/dev/null; then
    assert_fail "No state file → no crash detected (returns 1)"
else
    assert_pass "No state file → no crash detected (returns 1)"
fi

# Cleanup
rm -f "$STATE_FILE"
bash "$SRC" clear --all 2>/dev/null || true

echo ""

# ─── Results ─────────────────────────────────────────────────────────────────
echo ""
echo ""
print_test_results
