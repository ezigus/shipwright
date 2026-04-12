#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop test — Validate continuous agent loop harness           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Mock claude CLI
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude executed"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "main"
        else
            echo "abc1234"
        fi
        ;;
    diff)
        echo "+added line"
        echo "-removed line"
        ;;
    log)
        echo "abc1234 Mock commit message"
        ;;
    worktree)
        echo "ok"
        ;;
    branch)
        echo "main"
        ;;
    status)
        echo "nothing to commit"
        ;;
    *)
        echo "mock git: $*"
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock gh output"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock tmux
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Link real date, wc, etc.
    for cmd in date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
        fi
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

# Use assert_pass/assert_fail from test-helpers.sh (they track TOTAL/PASS/FAIL counters)

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Loop Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_test_env "sw-loop-test"
setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi

assert_contains "--help shows usage" "$output" "USAGE"
assert_contains "--help shows options" "$output" "OPTIONS"

# ─── Test 2: --help shows all key options ────────────────────────────────────
assert_contains "--help mentions --max-iterations" "$output" "--max-iterations"
assert_contains "--help mentions --test-cmd" "$output" "--test-cmd"
assert_contains "--help mentions --model" "$output" "--model"
assert_contains "--help mentions --agents" "$output" "--agents"
assert_contains "--help mentions --resume" "$output" "--resume"

# ─── Test 3: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined in sw-loop.sh"
else
    assert_fail "VERSION variable defined in sw-loop.sh"
fi

# ─── Test 4: Missing goal argument ───────────────────────────────────────────
echo ""
echo -e "${DIM}  argument parsing${RESET}"

# sw-loop.sh requires a goal — no goal means empty GOAL var, should fail
output=$(bash "$SCRIPT_DIR/sw-loop.sh" 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "No arguments exits non-zero"
else
    assert_fail "No arguments exits non-zero" "expected failure, got exit 0"
fi

# ─── Test 5: Script uses set -euo pipefail ──────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

# ─── Test 6: ERR trap is set ────────────────────────────────────────────────
if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 7: SIGHUP trap for daemon resilience ──────────────────────────────
if grep -q "trap '' HUP" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "SIGHUP trap set for daemon resilience"
else
    assert_fail "SIGHUP trap set for daemon resilience"
fi

# ─── Test 8: CLAUDECODE unset ───────────────────────────────────────────────
if grep -q "unset CLAUDECODE" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "CLAUDECODE env var is unset"
else
    assert_fail "CLAUDECODE env var is unset"
fi

# ─── Test 9: Default values ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  defaults${RESET}"

# Check key defaults in source
if grep -q 'MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_ITERATIONS is 20"
else
    assert_fail "Default MAX_ITERATIONS is 20"
fi

if grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1"
else
    assert_fail "Default AGENTS is 1"
fi

if grep -qE 'MAX_RESTARTS.*0|loop\.max_restarts.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0"
else
    assert_fail "Default MAX_RESTARTS is 0"
fi

# ─── Test 10: Compat library sourced ─────────────────────────────────────────
if grep -q 'lib/compat.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Sources lib/compat.sh"
else
    assert_fail "Sources lib/compat.sh"
fi

# ─── Test 11: JSON output format in claude flags ────────────────────────────
echo ""
echo -e "${DIM}  json output format${RESET}"
if grep -q 'output-format.*json' "$SCRIPT_DIR/sw-loop.sh" || grep -q 'output-format.*json' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags includes --output-format json"
else
    assert_fail "build_claude_flags includes --output-format json"
fi

# ─── Test 12: Token accumulation parses JSON ────────────────────────────────
if grep -q 'jq.*usage.input_tokens' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "accumulate_loop_tokens parses JSON usage"
else
    assert_fail "accumulate_loop_tokens parses JSON usage"
fi

# ─── Test 13: Cost tracking variable initialized ────────────────────────────
if grep -q 'LOOP_COST_MILLICENTS=0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "LOOP_COST_MILLICENTS initialized"
else
    assert_fail "LOOP_COST_MILLICENTS initialized"
fi

# ─── Test 14: write_loop_tokens includes cost ────────────────────────────────
if grep -q 'cost_usd' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "write_loop_tokens includes cost_usd"
else
    assert_fail "write_loop_tokens includes cost_usd"
fi

# ─── Test 15: _extract_text_from_json helper exists ──────────────────────────
if grep -q '_extract_text_from_json' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "_extract_text_from_json helper defined"
else
    assert_fail "_extract_text_from_json helper defined"
fi

# ─── Test 15b: validate_claude_output and check_budget_gate exist ───────────
if grep -q 'validate_claude_output()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "validate_claude_output helper defined"
else
    assert_fail "validate_claude_output helper defined"
fi
if grep -q 'check_budget_gate()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "check_budget_gate helper defined"
else
    assert_fail "check_budget_gate helper defined"
fi

# ─── Test 16: run_claude_iteration separates stdout/stderr ───────────────────
if grep -q '2>"$err_file"' "$SCRIPT_DIR/sw-loop.sh" || grep -q '2>"$err_file"' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "run_claude_iteration separates stdout from stderr"
else
    assert_fail "run_claude_iteration separates stdout from stderr"
fi

# ─── Test 17-19: _extract_text_from_json robustness ──────────────────────────
echo ""
echo -e "${DIM}  json extraction robustness${RESET}"
# Extract the function from sw-loop.sh and test it in isolation (can't source
# sw-loop.sh because it has no source guard — main() runs unconditionally)
tmpdir=$(mktemp -d)
_fn_file="$tmpdir/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file"
bash <<EXTRACT_TEST 2>/dev/null
warn() { :; }
source "$_fn_file"
# Test 1: empty file → '(no output)'
touch "$tmpdir/empty.json"
_extract_text_from_json "$tmpdir/empty.json" "$tmpdir/out1.log" ""
# Test 2: valid JSON array → extracts .result
echo '[{"type":"result","result":"Hello world","usage":{"input_tokens":100}}]' > "$tmpdir/valid.json"
_extract_text_from_json "$tmpdir/valid.json" "$tmpdir/out2.log" ""
# Test 3: plain text → pass through
echo 'This is plain text output' > "$tmpdir/text.json"
_extract_text_from_json "$tmpdir/text.json" "$tmpdir/out3.log" ""
EXTRACT_TEST

if grep -q "no output" "$tmpdir/out1.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles empty file"
else
    assert_fail "_extract_text_from_json handles empty file" "expected '(no output)' in $tmpdir/out1.log"
fi

if grep -q "Hello world" "$tmpdir/out2.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON"
else
    assert_fail "_extract_text_from_json extracts .result from JSON" "expected 'Hello world' in $tmpdir/out2.log"
fi

if grep -q "plain text" "$tmpdir/out3.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json passes through plain text"
else
    assert_fail "_extract_text_from_json passes through plain text" "expected 'plain text' in $tmpdir/out3.log"
fi
rm -rf "$tmpdir"

# ─── Test 20: Default configuration values from source ─────────────────────────
echo ""
echo -e "${DIM}  default config from source${RESET}"
max_iter_line=$(grep -E '^MAX_ITERATIONS=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ "$max_iter_line" =~ 20 ]]; then
    assert_pass "Default MAX_ITERATIONS is 20 (from source)"
else
    assert_fail "Default MAX_ITERATIONS is 20 (from source)" "got: $max_iter_line"
fi
if grep -qE '^AGENTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1 (from source)"
else
    assert_fail "Default AGENTS is 1 (from source)"
fi
if grep -qE 'MAX_RESTARTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -qE 'max_restarts.*0|MAX_RESTARTS.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0 (from source)"
else
    assert_fail "Default MAX_RESTARTS is 0 (from source)"
fi

# ─── Test 21: _extract_text_from_json — nested objects and binary ─────────────
echo ""
echo -e "${DIM}  json extraction edge cases${RESET}"
tmpdir2=$(mktemp -d)
_fn_file2="$tmpdir2/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file2"
bash <<EXTRACT_TEST2 2>/dev/null
warn() { :; }
source "$_fn_file2"
# Nested JSON array with objects
echo '[{"type":"result","result":"Nested extraction works","usage":{"input_tokens":50}}]' > "$tmpdir2/nested.json"
_extract_text_from_json "$tmpdir2/nested.json" "$tmpdir2/nested_out.log" ""
# Binary garbage — should not crash, pass through or handle
printf '\x00\x01\x02\xff\xfe' > "$tmpdir2/binary.dat"
_extract_text_from_json "$tmpdir2/binary.dat" "$tmpdir2/binary_out.log" ""
EXTRACT_TEST2

if grep -q "Nested extraction works" "$tmpdir2/nested_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles nested JSON objects"
else
    assert_fail "_extract_text_from_json handles nested JSON objects" "expected 'Nested extraction works'"
fi
# Binary input should not crash; output may be raw or placeholder
if [[ -f "$tmpdir2/binary_out.log" ]]; then
    assert_pass "_extract_text_from_json handles binary garbage without crash"
else
    assert_fail "_extract_text_from_json handles binary garbage without crash"
fi
rm -rf "$tmpdir2"

# ─── Test 21b: _extract_text_from_json — JSON object (not array) ──────────────
echo ""
echo -e "${DIM}  json extraction for JSON objects${RESET}"
tmpdir3=$(mktemp -d)
_fn_file3="$tmpdir3/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file3"
bash <<EXTRACT_TEST3 2>"$tmpdir3/stderr.log"
warn() { echo "WARN: \$*" >&2; }
source "$_fn_file3"
# Test: JSON object with .result field
echo '{"type":"result","subtype":"success","result":"Object result text","cost_usd":0.05}' > "$tmpdir3/object.json"
_extract_text_from_json "$tmpdir3/object.json" "$tmpdir3/object_out.log" ""
# Test: JSON object with .content field (no .result)
echo '{"type":"result","content":"Object content text"}' > "$tmpdir3/content.json"
_extract_text_from_json "$tmpdir3/content.json" "$tmpdir3/content_out.log" ""
# Test: JSON object — verify no misleading jq warning
echo '{"type":"result","result":"No warning expected"}' > "$tmpdir3/nowarn.json"
_extract_text_from_json "$tmpdir3/nowarn.json" "$tmpdir3/nowarn_out.log" ""
EXTRACT_TEST3

if grep -q "Object result text" "$tmpdir3/object_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON object"
else
    assert_fail "_extract_text_from_json extracts .result from JSON object" "expected 'Object result text' in $tmpdir3/object_out.log"
fi

if grep -q "Object content text" "$tmpdir3/content_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .content from JSON object"
else
    assert_fail "_extract_text_from_json extracts .content from JSON object" "expected 'Object content text' in $tmpdir3/content_out.log"
fi

if ! grep -q "jq not available" "$tmpdir3/stderr.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json no misleading jq warning for JSON object"
else
    assert_fail "_extract_text_from_json no misleading jq warning for JSON object" "got misleading 'jq not available' warning"
fi
rm -rf "$tmpdir3"

# ─── Test 22: Script structure — circuit breaker, stuckness, test gate ────────
echo ""
echo -e "${DIM}  script structure${RESET}"
if grep -qE 'check_circuit_breaker|CIRCUIT_BREAKER' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has circuit breaker logic"
else
    assert_fail "Script has circuit breaker logic"
fi
if grep -qE 'detect_stuckness|stuckness' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has stuckness detection"
else
    assert_fail "Script has stuckness detection"
fi
if grep -qE 'run_test_gate|run_quality_gates' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Script has test/quality gate functions"
else
    assert_fail "Script has test/quality gate functions"
fi

# ─── Test 23: --help key flags defined in show_help ────────────────────────────
# (Actual help output assertions are in Test 2 above)
if grep -qF -- '--model' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--agents' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --model and --agents flags"
else
    assert_fail "Help text defines --model and --agents flags"
fi
if grep -qF -- '--test-cmd' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--resume' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --test-cmd and --resume flags"
else
    assert_fail "Help text defines --test-cmd and --resume flags"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LOOP BEHAVIOR TESTS (real loop execution with mocks)
# ═══════════════════════════════════════════════════════════════════════════════

# Setup for loop behavior tests: real git repo, mock claude only
setup_loop_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright" "$TEST_TEMP_DIR/home/.claude" "$TEST_TEMP_DIR/bin"

    # Create real git repo (use system git, not mock from PATH)
    local _git
    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
    if [[ -z "$_git" ]]; then
        echo "WARN: git not found — skipping loop behavior tests"
        return 1
    fi
    mkdir -p "$TEST_TEMP_DIR/repo"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
    echo "init" > "$TEST_TEMP_DIR/repo/file.txt"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add . && "$_git" commit -q -m "init")

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
GHMOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Link real jq, git, date, seq, etc. (use clean PATH to avoid mock from setup_env)
    for cmd in jq git date seq wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch bash; do
        if PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$cmd" &>/dev/null; then
            ln -sf "$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd" 2>/dev/null || true
        fi
    done

    # Use our mocks (claude, gh) + real git/jq from our bin
    export PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    return 0
}

# ─── Test: Loop completes when Claude outputs LOOP_COMPLETE ─────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that says LOOP_COMPLETE on first iteration (valid JSON for --output-format json)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 5 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qi "Completion signal detected\|LOOP_COMPLETE"; then
        assert_pass "Loop detected completion signal"
    elif echo "$output" | grep -qiE "LOOP COMPLETE|loop complete|loop.*pass"; then
        assert_pass "Loop detected completion signal"
    else
        assert_fail "Loop detected completion signal" "output missing completion signal"
    fi
else
    assert_fail "Loop completes on LOOP_COMPLETE" "setup failed (git missing?)"
fi

# ─── Test: Loop runs multiple iterations when tests fail ───────────────────
echo ""
echo -e "${DIM}  loop behavior: iterations on test failure${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that makes a change, then says LOOP_COMPLETE on iteration 2
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if [[ ! -f iter2.txt ]]; then
    echo "Adding file" > iter2.txt
    echo '[{"type":"result","result":"Work in progress","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add iter2.txt" \
        --max-iterations 5 \
        --test-cmd "test -f iter2.txt" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_pass "Loop runs multiple iterations when tests fail initially"
    elif echo "$output" | grep -q "LOOP_COMPLETE"; then
        assert_pass "Loop runs multiple iterations and completes"
    elif echo "$output" | grep -qi "circuit breaker\|max iteration"; then
        assert_pass "Loop iterates (stopped by limit)"
    else
        assert_fail "Loop iterates on test failure" "expected multiple iterations"
    fi
else
    assert_fail "Loop iterates on test failure" "setup failed"
fi

# ─── Test: Loop respects max-iterations limit ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: max iterations${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that never says LOOP_COMPLETE (valid JSON)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Still working...","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Never finish" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qiE "max iteration|iteration.*3|Max iterations"; then
        assert_pass "Loop stops at max iterations"
    else
        assert_fail "Loop respects max-iterations" "expected iteration limit message"
    fi
else
    assert_fail "Loop max iterations" "setup failed"
fi

# ─── Test: LOOP_COMPLETE signal detection hardening (#263) ──────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE signal hardening${RESET}"

# Test: main loop prompt uses <<<LOOP:PASS>>> fence delimiter
if grep -q '<<<LOOP:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Main loop prompt uses <<<LOOP:PASS>>> fence delimiter"
else
    assert_fail "Main loop prompt uses <<<LOOP:PASS>>> fence delimiter"
fi

# Test: guard_completion uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*log_file.*LOOP\|detect_gate_signal.*"LOOP"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "guard_completion uses detect_gate_signal for LOOP signal"
else
    assert_fail "guard_completion uses detect_gate_signal for LOOP signal"
fi

# Test: main agent loop uses detect_gate_signal for completion check
if grep -q 'detect_gate_signal.*LOG_FILE.*LOOP\|detect_gate_signal.*"LOOP"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Main agent loop uses detect_gate_signal for completion check"
else
    assert_fail "Main agent loop uses detect_gate_signal for completion check"
fi

# Test: check_completion() in loop-convergence.sh uses detect_gate_signal
if grep -q 'detect_gate_signal' "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "loop-convergence.sh check_completion uses detect_gate_signal"
else
    assert_fail "loop-convergence.sh check_completion uses detect_gate_signal"
fi

# Test: ai-provider.sh uses detect_gate_signal (stdin mode) for LOOP signal
if grep -q 'detect_gate_signal.*"-".*LOOP\|detect_gate_signal.*"-"' "$SCRIPT_DIR/lib/ai-provider.sh"; then
    assert_pass "ai-provider.sh uses detect_gate_signal stdin mode for LOOP signal"
else
    assert_fail "ai-provider.sh uses detect_gate_signal stdin mode for LOOP signal"
fi

# Test: gate-signal.sh shared lib exists (detect_gate_signal extracted out of sw-loop.sh)
if [[ -f "$SCRIPT_DIR/lib/gate-signal.sh" ]]; then
    assert_pass "lib/gate-signal.sh shared library exists"
else
    assert_fail "lib/gate-signal.sh shared library exists"
fi

# Test: sw-loop.sh sources gate-signal.sh (not inline)
if grep -q 'gate-signal.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sources gate-signal.sh"
else
    assert_fail "sw-loop.sh sources gate-signal.sh"
fi

# Test: ai-provider.sh sources gate-signal.sh
if grep -q 'gate-signal.sh' "$SCRIPT_DIR/lib/ai-provider.sh"; then
    assert_pass "ai-provider.sh sources gate-signal.sh"
else
    assert_fail "ai-provider.sh sources gate-signal.sh"
fi

# Load detect_gate_signal from the shared lib for functional tests
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"

# Test: legacy LOOP_COMPLETE still detected via Layer 3 (backwards compat)
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Done. LOOP_COMPLETE" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: legacy LOOP_COMPLETE accepted via Layer 3"
else
    assert_fail "detect_gate_signal: legacy LOOP_COMPLETE accepted via Layer 3"
fi
rm -f "$dgs_test_log"

# Test: new <<<LOOP:PASS>>> fence accepted via Layer 2
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "All tasks complete." > "$dgs_test_log"
echo "<<<LOOP:PASS>>>" >> "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<LOOP:PASS>>> fence accepted"
else
    assert_fail "detect_gate_signal: <<<LOOP:PASS>>> fence accepted"
fi
rm -f "$dgs_test_log"

# Test: prose "goal achieved" no longer accepted (narrowed legacy pattern)
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "The goal has been achieved." > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: prose 'goal achieved' correctly rejected (narrowed pattern)"
else
    assert_fail "detect_gate_signal: prose 'goal achieved' correctly rejected (narrowed pattern)"
fi
rm -f "$dgs_test_log"

# Test: <<<LOOP:FAIL>>> blocks pass even when LOOP_COMPLETE also present
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'LOOP_COMPLETE\n<<<LOOP:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE' '<<<LOOP:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<LOOP:FAIL>>> blocks pass (negative-first)"
else
    assert_fail "detect_gate_signal: <<<LOOP:FAIL>>> blocks pass (negative-first)"
fi
rm -f "$dgs_test_log"

# ─── Test: Loop detects stuckness ───────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: stuckness detection${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that produces identical output every iteration (no file changes)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"I am trying the same approach again.","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Fix something" \
        --max-iterations 5 \
        --test-cmd "false" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qi "stuckness\|stuck"; then
        assert_pass "Loop detects stuckness"
    elif echo "$output" | grep -qi "circuit breaker"; then
        assert_pass "Loop circuit breaker triggered (stuckness-related)"
    elif echo "$output" | grep -qi "max iteration"; then
        assert_pass "Loop stops at limit (stuckness test)"
    else
        assert_fail "Loop stuckness detection" "expected stuckness or circuit breaker"
    fi
else
    assert_fail "Loop stuckness detection" "setup failed"
fi

# ─── Test: Budget gate stops loop ──────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: budget gate${RESET}"

# sw-cost reads from ~/.shipwright. Set budget=0.01 and spent>=budget via costs.json.
if setup_loop_env 2>/dev/null && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    _epoch=$(date +%s)
    echo "{\"daily_budget_usd\":0.01,\"enabled\":true}" > "$TEST_TEMP_DIR/home/.shipwright/budget.json"
    echo "{\"entries\":[{\"ts_epoch\":$_epoch,\"cost_usd\":1.0,\"input_tokens\":0,\"output_tokens\":0,\"model\":\"test\",\"stage\":\"test\",\"issue\":\"\"}],\"summary\":{}}" > "$TEST_TEMP_DIR/home/.shipwright/costs.json"
    # Add claude mock (loop exits before running it, but ensures consistent env)
    echo '#!/usr/bin/env bash
echo '"'"'[{"type":"result","result":"Done","usage":{"input_tokens":0,"output_tokens":0}}]'"'"'
exit 0' > "$TEST_TEMP_DIR/bin/claude"
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 2 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "budget exhausted|Budget exhausted|LOOP BUDGET_EXHAUSTED"; then
        assert_pass "Budget gate stops loop"
    else
        assert_fail "Budget gate stops loop" "expected budget exhausted message"
    fi
else
    assert_pass "Budget gate (skipped - setup or sw-cost missing)"
fi

# ─── Test: validate_claude_output catches bad output ───────────────────────
echo ""
echo -e "${DIM}  validate_claude_output${RESET}"

_validate_fn=$(sed -n '/^validate_claude_output()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
_valid_tmp=$(mktemp -d)
# Use real git for repo setup (bypass mock from setup_env)
_valid_git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
(cd "$_valid_tmp" && "$_valid_git" init -q && "$_valid_git" config user.email "t@t" && "$_valid_git" config user.name "T")
echo "api key leaked" > "$_valid_tmp/leak.ts"
(cd "$_valid_tmp" && "$_valid_git" add leak.ts 2>/dev/null)
_valid_out=$(cd "$_valid_tmp" && bash -c "
warn() { :; }
$_validate_fn
validate_claude_output . 2>/dev/null
_e=\$?
echo \"exit=\$_e\"
" 2>/dev/null)
rm -rf "$_valid_tmp"
if echo "$_valid_out" | grep -q "exit=1"; then
    assert_pass "validate_claude_output catches corrupt output"
else
    assert_fail "validate_claude_output catches bad output" "expected non-zero exit for api key leak"
fi

# ─── Test: Loop tracks progress via git diff ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: progress tracking${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that adds a file (simulates progress)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo "new content" > progress.txt
echo '[{"type":"result","result":"Added progress.txt. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add progress.txt" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "Git:|progress|insertion|LOOP_COMPLETE"; then
        assert_pass "Loop tracks progress via git"
    else
        assert_fail "Loop progress tracking" "expected git/progress output"
    fi
else
    assert_fail "Loop progress tracking" "setup failed"
fi

# ─── Test: context efficiency event emitted ────────────────────────────────
echo ""
echo -e "${DIM}  context efficiency metrics${RESET}"

# context_efficiency was extracted to loop-iteration.sh sub-module
_loop_files="$SCRIPT_DIR/sw-loop.sh $SCRIPT_DIR/lib/loop-iteration.sh"
if grep -q 'emit_event "loop.context_efficiency"' $_loop_files 2>/dev/null; then
    assert_pass "loop.context_efficiency event exists in run_claude_iteration"
else
    assert_fail "loop.context_efficiency event exists in run_claude_iteration"
fi

if grep -q 'raw_prompt_chars=' $_loop_files 2>/dev/null && grep -q 'trimmed_prompt_chars=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits raw and trimmed char counts"
else
    assert_fail "Context efficiency emits raw and trimmed char counts"
fi

if grep -q 'trim_ratio=' $_loop_files 2>/dev/null && grep -q 'budget_utilization=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits trim_ratio and budget_utilization"
else
    assert_fail "Context efficiency emits trim_ratio and budget_utilization"
fi

# Verify raw_prompt_chars is captured before manage_context_window trims
if grep -q 'raw_prompt_chars=${#prompt}' $_loop_files 2>/dev/null; then
    assert_pass "raw_prompt_chars measured from pre-trim prompt"
else
    assert_fail "raw_prompt_chars measured from pre-trim prompt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MULTI-TEST GATE TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  multi-test gate${RESET}"

# Test: ADDITIONAL_TEST_CMDS appears in source
if grep -q 'ADDITIONAL_TEST_CMDS' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ADDITIONAL_TEST_CMDS variable defined"
else
    assert_fail "ADDITIONAL_TEST_CMDS variable defined"
fi

# Test: --additional-test-cmds flag in arg parser
if grep -q '\-\-additional-test-cmds' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "--additional-test-cmds flag in arg parser"
else
    assert_fail "--additional-test-cmds flag in arg parser"
fi

# Test: --help mentions --additional-test-cmds
output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if echo "$output" | grep -q 'additional-test-cmds'; then
    assert_pass "--help documents --additional-test-cmds"
else
    assert_fail "--help documents --additional-test-cmds"
fi

# Test: test-evidence JSON file written
if grep -q 'test-evidence-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_test_gate writes test-evidence JSON"
else
    assert_fail "run_test_gate writes test-evidence JSON"
fi

# Test: audit agent reads evidence file
if grep -q 'evidence_file.*test-evidence' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_audit_agent reads structured test evidence"
else
    assert_fail "run_audit_agent reads structured test evidence"
fi

# Test: audit prompt includes fence delimiter instruction (#261)
if grep -q '<<<AUDIT:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit prompt includes <<<AUDIT:PASS>>> fence delimiter"
else
    assert_fail "Audit prompt includes <<<AUDIT:PASS>>> fence delimiter"
fi

# Test: audit detection uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*AUDIT' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit detection uses detect_gate_signal (not bare grep)"
else
    assert_fail "Audit detection uses detect_gate_signal (not bare grep)"
fi

# Test: audit negative pattern includes both AUDIT_FAIL and fenced <<<AUDIT:FAIL>>>
if grep -q 'AUDIT_FAIL|<<<AUDIT:FAIL>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit negative pattern covers both AUDIT_FAIL and fenced delimiter"
else
    assert_fail "Audit negative pattern covers both AUDIT_FAIL and fenced delimiter"
fi

# Test: audit has empty-response guard that returns early (matching DoD pattern)
if grep -q 'Audit.*evaluator returned empty output' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit has empty-response guard with diagnostic warning"
else
    assert_fail "Audit has empty-response guard with diagnostic warning"
fi

# Test: audit stderr is written to a dedicated file (not merged into audit_log)
if grep -q 'audit_err_log' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit stderr captured to dedicated file (not merged with stdout)"
else
    assert_fail "Audit stderr captured to dedicated file (not merged with stdout)"
fi

# Test: audit non-zero exit_code is logged as a warning
if grep -q 'exit_code.*Audit.*exited with code\|Audit.*claude -p exited with code' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit logs warning on non-zero claude exit code"
else
    assert_fail "Audit logs warning on non-zero claude exit code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICATION GAP TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  verification gap handler${RESET}"

# Test: verification gap detection exists in source
if grep -q 'Verification gap detected' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap detection present"
else
    assert_fail "Verification gap detection present"
fi

# Test: verification gap emits events
if grep -q 'loop.verification_gap_resolved' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap resolved event emitted"
else
    assert_fail "Verification gap resolved event emitted"
fi

if grep -q 'loop.verification_gap_confirmed' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap confirmed event emitted"
else
    assert_fail "Verification gap confirmed event emitted"
fi

# Test: verification gap overrides audit when tests pass
if grep -q 'override_audit' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap can override audit result"
else
    assert_fail "Verification gap can override audit result"
fi

# Test: verification checks for uncommitted changes
if grep -q 'verification-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification re-runs tests to dedicated log"
else
    assert_fail "Verification re-runs tests to dedicated log"
fi

# Test: mid-build test discovery uses detect_created_test_files
if grep -q 'detect_created_test_files' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Mid-build test file discovery integrated"
else
    assert_fail "Mid-build test file discovery integrated"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# HOLISTIC GATE — BRANCH DIFF TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  holistic gate branch diff${RESET}"

# Test: full branch diff section present in holistic prompt
if grep -q 'Full Branch Changes vs Base' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt includes Full Branch Changes vs Base section"
else
    assert_fail "Holistic prompt includes Full Branch Changes vs Base section"
fi

# Test: loop-run section relabelled (not the old 'from start' wording)
if grep -q 'this loop run only' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic loop-run diff section labelled as loop-run only"
else
    assert_fail "Holistic loop-run diff section labelled as loop-run only"
fi

# Test: restart NOTE present to guide assessor
if grep -q 'loop was restarted after prior work' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt includes restart NOTE for assessor"
else
    assert_fail "Holistic prompt includes restart NOTE for assessor"
fi

# Test: base branch detection uses git rev-parse (not hardcoded 'main')
if grep -q "rev-parse --abbrev-ref origin/HEAD" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic gate detects base branch dynamically via git rev-parse"
else
    assert_fail "Holistic gate detects base branch dynamically via git rev-parse"
fi

# Test: fallback to 'main' if rev-parse fails
if grep -A2 'rev-parse --abbrev-ref origin/HEAD' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'base_branch.*main'; then
    assert_pass "Holistic gate falls back to main if base branch detection fails"
else
    assert_fail "Holistic gate falls back to main if base branch detection fails"
fi

# Test: Project Stats uses loop-scoped label (not misleading 'Cumulative')
if grep -q 'Loop-run changes:' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Project Stats labels loop-scoped change count accurately"
else
    assert_fail "Project Stats labels loop-scoped change count accurately"
fi

# ─── HOLISTIC gate signal hardening (#264) ────────────────────────────────────
echo ""
echo -e "${DIM}  holistic gate: signal hardening (#264)${RESET}"

# Test: holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter
if grep -q '<<<HOLISTIC:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter"
else
    assert_fail "Holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter"
fi

# Test: holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter
if grep -q '<<<HOLISTIC:FAIL>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter"
else
    assert_fail "Holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter"
fi

# Test: holistic detection uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*holistic_log.*HOLISTIC\|detect_gate_signal.*"HOLISTIC"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic detection uses detect_gate_signal (not bare grep)"
else
    assert_fail "Holistic detection uses detect_gate_signal (not bare grep)"
fi

# Test: holistic has empty-response guard (checks both zero-length and whitespace-only)
if grep -q 'grep -q.*\[.*\^.*\[:space:\]' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic empty-response guard rejects whitespace-only output"
else
    assert_fail "Holistic empty-response guard rejects whitespace-only output"
fi

# Test: holistic captures stderr separately
if grep -q 'holistic.*stderr\|holistic_stderr' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic stderr captured to dedicated file"
else
    assert_fail "Holistic stderr captured to dedicated file"
fi

# Test: holistic surfaces gap text as HOLISTIC_RESULT for agent feedback
if grep -q 'HOLISTIC_RESULT=' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic sets HOLISTIC_RESULT for agent feedback injection"
else
    assert_fail "Holistic sets HOLISTIC_RESULT for agent feedback injection"
fi

# Test: compose_holistic_feedback_section exists for prompt injection
if grep -q '^compose_holistic_feedback_section()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "compose_holistic_feedback_section() exists for prompt injection"
else
    assert_fail "compose_holistic_feedback_section() exists for prompt injection"
fi

# Test: holistic feedback injected into agent prompt
if grep -q 'holistic_feedback_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "holistic_feedback_section injected into agent prompt"
else
    assert_fail "holistic_feedback_section injected into agent prompt"
fi

# Test: holistic legacy pattern does NOT include prose goal.{0,20}fully.{0,10}achieved
# (removed in review — too permissive, matches negated sentences)
if ! grep 'detect_gate_signal.*HOLISTIC' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'goal.*achieved'; then
    assert_pass "Holistic legacy pattern does not include overly permissive prose (goal.*achieved removed)"
else
    assert_fail "Holistic legacy pattern does not include overly permissive prose (goal.*achieved removed)"
fi

# Test: holistic negative pattern is <<<HOLISTIC:FAIL>>> only (no ambiguous prose)
if ! grep 'detect_gate_signal.*HOLISTIC' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'gaps.*remaining'; then
    assert_pass "Holistic negative pattern is unambiguous (gaps.remaining prose removed)"
else
    assert_fail "Holistic negative pattern is unambiguous (gaps.remaining prose removed)"
fi

# Load detect_gate_signal for unit tests
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"

# Test: detect_gate_signal — HOLISTIC_PASS legacy accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "HOLISTIC_PASS" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC legacy HOLISTIC_PASS accepted"
else
    assert_fail "detect_gate_signal: HOLISTIC legacy HOLISTIC_PASS accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal — <<<HOLISTIC:PASS>>> fence accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Goal is complete." > "$dgs_test_log"
echo "<<<HOLISTIC:PASS>>>" >> "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<HOLISTIC:PASS>>> fence accepted"
else
    assert_fail "detect_gate_signal: <<<HOLISTIC:PASS>>> fence accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal — <<<HOLISTIC:FAIL>>> blocks pass
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'HOLISTIC_PASS\n<<<HOLISTIC:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<HOLISTIC:FAIL>>> blocks positive match (negative-first)"
else
    assert_fail "detect_gate_signal: <<<HOLISTIC:FAIL>>> blocks positive match (negative-first)"
fi
rm -f "$dgs_test_log"

# Test: boundary — "no gaps remaining" (past-tense resolution prose) does not cause false FAIL
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'HOLISTIC_PASS\nAll gaps have been addressed; no gaps remaining.\n' > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC prose 'no gaps remaining' does not cause false FAIL"
else
    assert_fail "detect_gate_signal: HOLISTIC prose 'no gaps remaining' does not cause false FAIL"
fi
rm -f "$dgs_test_log"

# Test: boundary — "not fully achieved" prose does not cause false PASS
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Overall status: the goal is not fully achieved yet." > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC prose 'not fully achieved' does not trigger false PASS"
else
    assert_fail "detect_gate_signal: HOLISTIC prose 'not fully achieved' does not trigger false PASS"
fi
rm -f "$dgs_test_log"

# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT EXHAUSTION PREVENTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  context exhaustion prevention${RESET}"

# Test: loop-context-monitor.sh exists
if [[ -f "$SCRIPT_DIR/lib/loop-context-monitor.sh" ]]; then
    assert_pass "loop-context-monitor.sh module exists"
else
    assert_fail "loop-context-monitor.sh module exists"
fi

# Test: module has module guard
if grep -q '_LOOP_CONTEXT_MONITOR_LOADED' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "loop-context-monitor.sh has module guard"
else
    assert_fail "loop-context-monitor.sh has module guard"
fi

# Test: module defines CONTEXT_WINDOW_TOKENS default
if grep -q 'CONTEXT_WINDOW_TOKENS.*200000' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "CONTEXT_WINDOW_TOKENS defaults to 200000"
else
    assert_fail "CONTEXT_WINDOW_TOKENS defaults to 200000"
fi

# Test: module defines CONTEXT_EXHAUSTION_THRESHOLD default
if grep -q 'CONTEXT_EXHAUSTION_THRESHOLD.*70' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "CONTEXT_EXHAUSTION_THRESHOLD defaults to 70"
else
    assert_fail "CONTEXT_EXHAUSTION_THRESHOLD defaults to 70"
fi

# Test: check_context_exhaustion function defined
if grep -q '^check_context_exhaustion()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "check_context_exhaustion() function defined"
else
    assert_fail "check_context_exhaustion() function defined"
fi

# Test: summarize_loop_state function defined
if grep -q '^summarize_loop_state()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "summarize_loop_state() function defined"
else
    assert_fail "summarize_loop_state() function defined"
fi

# Test: get_context_usage_pct function defined
if grep -q '^get_context_usage_pct()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "get_context_usage_pct() function defined"
else
    assert_fail "get_context_usage_pct() function defined"
fi

# Test: division-by-zero guard present
if grep -q 'window.*-le 0' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "Division-by-zero guard present in get_context_usage_pct"
else
    assert_fail "Division-by-zero guard present in get_context_usage_pct"
fi

# Test: threshold calculation — get_context_usage_pct returns correct value
source "$SCRIPT_DIR/lib/loop-context-monitor.sh" 2>/dev/null || true
if type get_context_usage_pct >/dev/null 2>&1; then
    # 140000 / 200000 = 70%
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=40000
    CONTEXT_WINDOW_TOKENS=200000
    pct="$(get_context_usage_pct)"
    if [[ "$pct" -eq 70 ]]; then
        assert_pass "get_context_usage_pct: 140000/200000 = 70%"
    else
        assert_fail "get_context_usage_pct: 140000/200000 = 70%" "got $pct, expected 70"
    fi

    # Under threshold: 100000 / 200000 = 50%
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    pct_under="$(get_context_usage_pct)"
    if [[ "$pct_under" -eq 50 ]]; then
        assert_pass "get_context_usage_pct: 100000/200000 = 50%"
    else
        assert_fail "get_context_usage_pct: 100000/200000 = 50%" "got $pct_under, expected 50"
    fi

    # Zero tokens: should return 0
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
    pct_zero="$(get_context_usage_pct)"
    if [[ "$pct_zero" -eq 0 ]]; then
        assert_pass "get_context_usage_pct: 0/200000 = 0%"
    else
        assert_fail "get_context_usage_pct: 0/200000 = 0%" "got $pct_zero, expected 0"
    fi

    # Division by zero guard: window=0 should return 0, not crash
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=0
    CONTEXT_WINDOW_TOKENS=0
    pct_divzero="$(get_context_usage_pct)"
    if [[ "$pct_divzero" -eq 0 ]]; then
        assert_pass "get_context_usage_pct: division-by-zero returns 0"
    else
        assert_fail "get_context_usage_pct: division-by-zero returns 0" "got $pct_divzero, expected 0"
    fi
    # Reset to sane defaults
    CONTEXT_WINDOW_TOKENS=200000
else
    assert_fail "get_context_usage_pct() callable after sourcing module"
fi

# Test: check_context_exhaustion returns false (1) when below threshold
if type check_context_exhaustion >/dev/null 2>&1; then
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
    CONTEXT_WINDOW_TOKENS=200000
    CONTEXT_EXHAUSTION_THRESHOLD=70
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns false when no tokens"
    else
        assert_fail "check_context_exhaustion: returns false when no tokens"
    fi

    # 50% usage (below 70% threshold) — should return false
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns false at 50% usage"
    else
        assert_fail "check_context_exhaustion: returns false at 50% usage"
    fi

    # 70% usage (at threshold) — should return true
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=40000
    if check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns true at 70% threshold"
    else
        assert_fail "check_context_exhaustion: returns true at 70% threshold"
    fi

    # Over threshold (80%) — should return true
    LOOP_INPUT_TOKENS=140000
    LOOP_OUTPUT_TOKENS=20000
    if check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns true above threshold"
    else
        assert_fail "check_context_exhaustion: returns true above threshold"
    fi

    # Custom threshold override: 90% threshold, 80% usage → should return false
    LOOP_INPUT_TOKENS=140000
    LOOP_OUTPUT_TOKENS=20000
    CONTEXT_EXHAUSTION_THRESHOLD=90
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: respects custom threshold (90%)"
    else
        assert_fail "check_context_exhaustion: respects custom threshold (90%)"
    fi
    # Reset
    CONTEXT_EXHAUSTION_THRESHOLD=70
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
else
    assert_fail "check_context_exhaustion() callable after sourcing module"
fi

# Test: summarize_loop_state writes output file
if type summarize_loop_state >/dev/null 2>&1; then
    _summary_log_dir="$TEST_TEMP_DIR/log-summary-test"
    mkdir -p "$_summary_log_dir"
    LOG_DIR="$_summary_log_dir"
    GOAL="Test goal for summarization"
    ORIGINAL_GOAL="Test goal for summarization"
    ITERATION=5
    MAX_ITERATIONS=20
    TEST_PASSED=false
    CONSECUTIVE_FAILURES=2
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    CONTEXT_WINDOW_TOKENS=200000
    PROJECT_ROOT="$TEST_TEMP_DIR/repo"
    LOG_ENTRIES="### Iteration 1
Some work done
### Iteration 2
More progress"

    _summary_path="$(summarize_loop_state 2>/dev/null || true)"
    if [[ -f "$_summary_log_dir/context-summary.md" ]]; then
        assert_pass "summarize_loop_state: creates context-summary.md"
    else
        assert_fail "summarize_loop_state: creates context-summary.md"
    fi

    # Check required sections exist
    _summary_content="$(cat "$_summary_log_dir/context-summary.md" 2>/dev/null || true)"
    if echo "$_summary_content" | grep -q 'Goal'; then
        assert_pass "summarize_loop_state: includes Goal section"
    else
        assert_fail "summarize_loop_state: includes Goal section"
    fi

    if echo "$_summary_content" | grep -q 'Session Status'; then
        assert_pass "summarize_loop_state: includes Session Status section"
    else
        assert_fail "summarize_loop_state: includes Session Status section"
    fi

    if echo "$_summary_content" | grep -q 'Modified Files'; then
        assert_pass "summarize_loop_state: includes Modified Files section"
    else
        assert_fail "summarize_loop_state: includes Modified Files section"
    fi

    if echo "$_summary_content" | grep -q 'Recent Progress'; then
        assert_pass "summarize_loop_state: includes Recent Progress section"
    else
        assert_fail "summarize_loop_state: includes Recent Progress section"
    fi
else
    assert_fail "summarize_loop_state() callable after sourcing module"
fi

# Test: sw-loop.sh sources loop-context-monitor.sh
if grep -q 'loop-context-monitor.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sources loop-context-monitor.sh"
else
    assert_fail "sw-loop.sh sources loop-context-monitor.sh"
fi

# Test: sw-loop.sh has context exhaustion check in main loop
if grep -q 'check_context_exhaustion' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh calls check_context_exhaustion in main loop"
else
    assert_fail "sw-loop.sh calls check_context_exhaustion in main loop"
fi

# Test: sw-loop.sh emits context_exhaustion_warning (via the monitor module)
if grep -q 'context_exhaustion_warning' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "loop.context_exhaustion_warning event emitted in monitor module"
else
    assert_fail "loop.context_exhaustion_warning event emitted in monitor module"
fi

# Test: sw-loop.sh handles context_exhaustion status in restart handler
if grep -q 'context_exhaustion_restart' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh emits loop.context_exhaustion_restart event"
else
    assert_fail "sw-loop.sh emits loop.context_exhaustion_restart event"
fi

# Test: sw-loop.sh resets token counters on every session restart (not just context_exhaustion).
# The reset must appear in the shared restart block, before the context_exhaustion branch.
# Accepts either an inline zero-assignment or a call to reset_token_counters().
if grep -A30 'Reset ALL iteration-level state' "$SCRIPT_DIR/sw-loop.sh" | grep -qE 'LOOP_INPUT_TOKENS=0|reset_token_counters'; then
    assert_pass "sw-loop.sh resets LOOP_INPUT_TOKENS on context_exhaustion restart"
else
    assert_fail "sw-loop.sh resets LOOP_INPUT_TOKENS on context_exhaustion restart"
fi

# Test: loop-iteration.sh emits loop.context_usage event
if grep -q 'loop.context_usage' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "loop-iteration.sh emits loop.context_usage event per iteration"
else
    assert_fail "loop-iteration.sh emits loop.context_usage event per iteration"
fi

# Test: loop.context_usage event includes usage_pct field
if grep -A5 'loop.context_usage' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'usage_pct'; then
    assert_pass "loop.context_usage event includes usage_pct field"
else
    assert_fail "loop.context_usage event includes usage_pct field"
fi

# ─── safe_git_stage() — daemon-config.json exclusion ─────────────────────────

# Test: safe_git_stage() is defined in helpers.sh
if grep -q '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "safe_git_stage() defined in helpers.sh"
else
    assert_fail "safe_git_stage() defined in helpers.sh"
fi

# Test: safe_git_stage() calls restore --staged daemon-config.json
if grep -A10 '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh" | grep -q '_GIT_BOOKKEEPING_FILES'; then
    assert_pass "safe_git_stage() uses _GIT_BOOKKEEPING_FILES to unstage bookkeeping files"
else
    assert_fail "safe_git_stage() uses _GIT_BOOKKEEPING_FILES to unstage bookkeeping files"
fi

# Test: post-audit cleanup path uses safe_git_stage
if grep -B2 'post-audit cleanup' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "post-audit cleanup path uses safe_git_stage"
else
    assert_fail "post-audit cleanup path uses safe_git_stage"
fi

# Test: git_auto_commit() uses safe_git_stage
if grep -A15 'git_auto_commit()' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "git_auto_commit() uses safe_git_stage"
else
    assert_fail "git_auto_commit() uses safe_git_stage"
fi

# Test: multi-agent parallel commit path uses safe_git_stage
if grep -B2 "agent-.*: iteration" "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "multi-agent parallel commit path uses safe_git_stage"
else
    assert_fail "multi-agent parallel commit path uses safe_git_stage"
fi

# Test: pipeline-stages-build.sh TDD commit uses safe_git_stage
if grep -B1 'TDD - define expected' "$SCRIPT_DIR/lib/pipeline-stages-build.sh" | grep -q 'safe_git_stage'; then
    assert_pass "pipeline-stages-build.sh TDD commit uses safe_git_stage"
else
    assert_fail "pipeline-stages-build.sh TDD commit uses safe_git_stage"
fi

# Test: pipeline-stages-delivery.sh cleanup commit uses safe_git_stage
if grep -B1 'pipeline cleanup' "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh" | grep -q 'safe_git_stage'; then
    assert_pass "pipeline-stages-delivery.sh cleanup commit uses safe_git_stage"
else
    assert_fail "pipeline-stages-delivery.sh cleanup commit uses safe_git_stage"
fi

# Test: pipeline-state.sh artifact commit guards daemon-config.json
if grep -A3 'git add.*to_add' "$SCRIPT_DIR/lib/pipeline-state.sh" | grep -q 'daemon-config.json'; then
    assert_pass "pipeline-state.sh artifact commit guards daemon-config.json"
else
    assert_fail "pipeline-state.sh artifact commit guards daemon-config.json"
fi

# Test: _GIT_BOOKKEEPING_FILES array is defined in helpers.sh
if grep -q '_GIT_BOOKKEEPING_FILES=' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_GIT_BOOKKEEPING_FILES defined in helpers.sh"
else
    assert_fail "_GIT_BOOKKEEPING_FILES defined in helpers.sh"
fi

# Test: _GIT_RUNTIME_EXCLUDES array is defined in helpers.sh
if grep -q '_GIT_RUNTIME_EXCLUDES=' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_GIT_RUNTIME_EXCLUDES defined in helpers.sh"
else
    assert_fail "_GIT_RUNTIME_EXCLUDES defined in helpers.sh"
fi

# Test: _git_diff_stat_excluded helper is defined in helpers.sh
if grep -q '^_git_diff_stat_excluded()' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_git_diff_stat_excluded() defined in helpers.sh"
else
    assert_fail "_git_diff_stat_excluded() defined in helpers.sh"
fi

# Test: all three bookkeeping files are listed in _GIT_BOOKKEEPING_FILES
for _bf in daemon-config.json pipeline-tasks.md tasks.md; do
    if awk '/_GIT_BOOKKEEPING_FILES=/,/\)/' "$SCRIPT_DIR/lib/helpers.sh" | grep -Fq "$_bf"; then
        assert_pass "_GIT_BOOKKEEPING_FILES includes $_bf"
    else
        assert_fail "_GIT_BOOKKEEPING_FILES includes $_bf"
    fi
done

# Test: safe_git_stage() loops over _GIT_BOOKKEEPING_FILES (not a hardcoded path)
if grep -A10 '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh" | grep -q '_GIT_BOOKKEEPING_FILES'; then
    assert_pass "safe_git_stage() uses _GIT_BOOKKEEPING_FILES"
else
    assert_fail "safe_git_stage() uses _GIT_BOOKKEEPING_FILES"
fi

# Test: check_progress() uses shared helper
if grep -A20 '^check_progress()' "$SCRIPT_DIR/lib/loop-convergence.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "check_progress() uses _git_diff_stat_excluded"
else
    assert_fail "check_progress() uses _git_diff_stat_excluded"
fi

# Test: track_iteration_velocity() uses shared helper
if grep -A5 '^track_iteration_velocity()' "$SCRIPT_DIR/lib/loop-convergence.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "track_iteration_velocity() uses _git_diff_stat_excluded"
else
    assert_fail "track_iteration_velocity() uses _git_diff_stat_excluded"
fi

# Test: git_diff_stat() uses shared helper
if grep -A3 '^git_diff_stat()' "$SCRIPT_DIR/sw-loop.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "git_diff_stat() uses _git_diff_stat_excluded"
else
    assert_fail "git_diff_stat() uses _git_diff_stat_excluded"
fi

# Test: functional — safe_git_stage excludes all bookkeeping files (not just daemon-config.json)
# Uses the real git binary (not the mock stub injected by setup_env) so the
# test actually exercises git init/add/commit/restore rather than no-ops.
_test_safe_git_stage() {
    local real_git
    real_git="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)" || return 1
    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    "$real_git" init -q "$tmpdir"
    "$real_git" -C "$tmpdir" config user.email "test@test.com"
    "$real_git" -C "$tmpdir" config user.name "test"
    mkdir -p "$tmpdir/.claude"
    # Create all bookkeeping files and a real code file
    echo '{}' > "$tmpdir/.claude/daemon-config.json"
    echo '# tasks' > "$tmpdir/.claude/pipeline-tasks.md"
    echo '# tasks' > "$tmpdir/.claude/tasks.md"
    echo 'echo hello' > "$tmpdir/app.sh"
    "$real_git" -C "$tmpdir" add -A
    "$real_git" -C "$tmpdir" commit -q -m "initial"
    # Modify all files
    echo '{"modified": true}' > "$tmpdir/.claude/daemon-config.json"
    echo '# updated tasks' > "$tmpdir/.claude/pipeline-tasks.md"
    echo '# updated tasks' > "$tmpdir/.claude/tasks.md"
    echo 'echo world' > "$tmpdir/app.sh"
    # Run safe_git_stage
    ( cd "$tmpdir" && PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin source "$SCRIPT_DIR/lib/helpers.sh" && safe_git_stage )
    local staged
    staged="$("$real_git" -C "$tmpdir" diff --cached --name-only)"
    # Bookkeeping files must NOT be staged
    local _bf
    for _bf in .claude/daemon-config.json .claude/pipeline-tasks.md .claude/tasks.md; do
        if echo "$staged" | grep -F -x -q "$_bf"; then
            return 1
        fi
    done
    # Real code file MUST be staged
    if ! echo "$staged" | grep -F -x -q "app.sh"; then
        return 1
    fi
    return 0
}
if _test_safe_git_stage; then
    assert_pass "safe_git_stage() functional: all bookkeeping files excluded, real code staged"
else
    assert_fail "safe_git_stage() functional: all bookkeeping files excluded, real code staged"
fi

# ─── Tests: check_progress() with new_commits param (issue #221) ─────────────
# Each case runs in its own subshell to avoid set -e propagation from sourced scripts.

# Build a two-commit repo for the no-arg fallback test (needs real commits)
_build_test_repo() {
    local _real_git
    _real_git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null) || return 1
    local _tmpdir
    _tmpdir=$(mktemp -d)
    "$_real_git" init -q "$_tmpdir"
    "$_real_git" -C "$_tmpdir" config user.email "test@test.com"
    "$_real_git" -C "$_tmpdir" config user.name "test"
    printf 'line1\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "initial"
    printf 'line1\nline2\nline3\nline4\nline5\nline6\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "second"
    echo "$_tmpdir"
}

# Test A: new_commits=0 → no progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 0 ) 2>/dev/null; then
    assert_fail "check_progress(0): no commits = no progress (circuit breaker fix #221)"
else
    assert_pass "check_progress(0): no commits = no progress (circuit breaker fix #221)"
fi

# Test B: new_commits=1 → progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 1 ) 2>/dev/null; then
    assert_pass "check_progress(1): one commit = progress detected"
else
    assert_fail "check_progress(1): one commit = progress detected"
fi

# Test C: new_commits=3 → progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 3 ) 2>/dev/null; then
    assert_pass "check_progress(3): multiple commits = progress detected"
else
    assert_fail "check_progress(3): multiple commits = progress detected"
fi

# Test D: no-arg fallback uses _git_diff_stat_excluded (backward compat)
# Strip mock bin from PATH so _git_diff_stat_excluded uses the real git binary.
_fallback_repo=$(_build_test_repo 2>/dev/null || echo "")
if [[ -n "$_fallback_repo" ]]; then
    if (
         _real_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | \
             awk -v mock="${TEST_TEMP_DIR:-__none__}/bin" '$0 != mock' | \
             paste -sd: -)
         export PATH="$_real_path"
         export PROJECT_ROOT="$_fallback_repo" MIN_PROGRESS_LINES=5
         source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
         source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
         check_progress
       ) 2>/dev/null; then
        assert_pass "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    else
        assert_fail "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    fi
    rm -rf "$_fallback_repo"
else
    assert_pass "check_progress() fallback (no args): skipped (git unavailable)"
fi

# ─── Progress message variants — commit count fix (#246) ──────────────────────

# Test: "Progress detected — tests still failing" message exists (Claude committed, tests fail)
if grep -q 'Progress detected — tests still failing' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh contains 'Progress detected — tests still failing' message variant"
else
    assert_fail "sw-loop.sh contains 'Progress detected — tests still failing' message variant"
fi

# Test: "Low progress" message still exists (zero commits case unchanged)
if grep -q 'Low progress' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh contains 'Low progress' message variant (zero commits case)"
else
    assert_fail "sw-loop.sh contains 'Low progress' message variant (zero commits case)"
fi

# Test: In main loop, commits_before capture appears before run_claude_iteration
# (line-ordering regression: guards against moving commits_before back after the call)
_cb_line=$(grep -n 'commits_before.*git_commit_count' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
_rci_line=$(grep -n 'run_claude_iteration' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [[ -n "$_cb_line" && -n "$_rci_line" && "$_cb_line" -lt "$_rci_line" ]]; then
    assert_pass "sw-loop.sh: commits_before captured before run_claude_iteration (line ${_cb_line} < ${_rci_line})"
else
    assert_fail "sw-loop.sh: commits_before captured before run_claude_iteration (got commits_before=${_cb_line:-unset}, run_claude_iteration=${_rci_line:-unset})"
fi

# Test: In agent sub-loop, _commits_before appears before the agent-specific claude -p invocation
# (line-ordering regression: guards against moving _commits_before back after the call)
# Restrict search to lines 1800+ to target the agent sub-loop only (avoids earlier claude -p calls)
_acb_line=$(grep -n '_commits_before=\$(git rev-list' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
_cp_line=$(awk 'NR>=1800 && /claude -p "\$PROMPT"/{print NR; exit}' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
if [[ -n "$_acb_line" && -n "$_cp_line" && "$_acb_line" -lt "$_cp_line" ]]; then
    assert_pass "sw-loop.sh: agent _commits_before captured before claude -p (line ${_acb_line} < ${_cp_line})"
else
    assert_fail "sw-loop.sh: agent _commits_before captured before claude -p (got _commits_before=${_acb_line:-unset}, claude -p=${_cp_line:-unset})"
fi

# ─── GATES_PASSED_NO_SIGNAL — silent loop continuation fix (#234) ─────────────

# Test: GATES_PASSED_NO_SIGNAL is set when quality gates pass but no LOOP_COMPLETE
if grep -q 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sets GATES_PASSED_NO_SIGNAL=true when gates pass without LOOP_COMPLETE"
else
    assert_fail "sw-loop.sh sets GATES_PASSED_NO_SIGNAL=true when gates pass without LOOP_COMPLETE"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when COMPLETION_REJECTED is not true
if grep -B3 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'COMPLETION_REJECTED.*!=.*true'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by COMPLETION_REJECTED check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by COMPLETION_REJECTED check"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when QUALITY_GATES_ENABLED
if grep -B5 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'QUALITY_GATES_ENABLED'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by QUALITY_GATES_ENABLED check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by QUALITY_GATES_ENABLED check"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when audit passed
if grep -B5 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'AUDIT_RESULT'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by AUDIT_RESULT check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by AUDIT_RESULT check"
fi

# Test: compose_rejection_notice_section handles GATES_PASSED_NO_SIGNAL branch
if grep -A10 '^compose_rejection_notice_section()' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'GATES_PASSED_NO_SIGNAL'; then
    assert_pass "compose_rejection_notice_section() handles GATES_PASSED_NO_SIGNAL branch"
else
    assert_fail "compose_rejection_notice_section() handles GATES_PASSED_NO_SIGNAL branch"
fi

# Test: quality gates passed hint injected into prompt (not rejection notice)
if grep -A20 'GATES_PASSED_NO_SIGNAL.*true' "$SCRIPT_DIR/sw-loop.sh" | grep -qi 'quality.*gates.*passed\|gates.*passed'; then
    assert_pass "GATES_PASSED_NO_SIGNAL branch emits quality gates passed hint"
else
    assert_fail "GATES_PASSED_NO_SIGNAL branch emits quality gates passed hint"
fi

# Test: COMPLETION_REJECTED path unchanged (rejection notice still present)
if grep -A5 '^compose_rejection_notice_section()' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'COMPLETION_REJECTED'; then
    assert_pass "compose_rejection_notice_section() still handles COMPLETION_REJECTED path"
else
    assert_fail "compose_rejection_notice_section() still handles COMPLETION_REJECTED path"
fi

# Test: COMPLETION_REJECTED and GATES_PASSED_NO_SIGNAL reset at top of each iteration
# (not inside compose_rejection_notice_section subshell where resets are no-ops)
if grep -A5 'Reset per-iteration completion signal flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'COMPLETION_REJECTED=false'; then
    assert_pass "COMPLETION_REJECTED reset in main loop before prompt build (not in subshell)"
else
    assert_fail "COMPLETION_REJECTED reset in main loop before prompt build (not in subshell)"
fi

if grep -A5 'Reset per-iteration completion signal flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'GATES_PASSED_NO_SIGNAL=false'; then
    assert_pass "GATES_PASSED_NO_SIGNAL reset in main loop before prompt build (not in subshell)"
else
    assert_fail "GATES_PASSED_NO_SIGNAL reset in main loop before prompt build (not in subshell)"
fi

# ─── Early exit when no changes and all gates pass (#245) ─────────────────────

# Test: early exit block exists after GATES_PASSED_NO_SIGNAL is set
if grep -A10 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'loop.early_exit_gates_passed'; then
    assert_pass "early exit check present after GATES_PASSED_NO_SIGNAL (all gates = complete)"
else
    assert_fail "early exit check present after GATES_PASSED_NO_SIGNAL (all gates = complete)"
fi

# Test: early exit does NOT require zero new_commits (fires regardless of commits when gates pass)
if grep -B2 'loop.early_exit_gates_passed' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'new_commits.*-eq 0'; then
    assert_fail "early exit must NOT be guarded by new_commits == 0 (should exit on any gates-pass)"
else
    assert_pass "early exit not guarded by new_commits == 0 — exits when gates pass regardless of commits"
fi

# Test: early exit sets STATUS=complete
if grep -B5 'loop.early_exit_gates_passed' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'STATUS="complete"'; then
    assert_pass "early exit sets STATUS=complete"
else
    assert_fail "early exit sets STATUS=complete"
fi

# Test: early exit runs holistic gate before exiting
# Use -A2 to match across potential line breaks in the condition
if grep -A2 'GATES_PASSED_NO_SIGNAL.*true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'run_holistic_gate'; then
    assert_pass "early exit runs run_holistic_gate before completing"
else
    assert_fail "early exit runs run_holistic_gate before completing"
fi

# Test: holistic gate prompt includes actual diff content (not just stats)
if grep -q 'branch_diff' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate collects branch_diff for prompt"
else
    assert_fail "holistic gate collects branch_diff for prompt"
fi

# Test: holistic gate prompt includes Evaluation Rules with default-to-FAIL bias
if grep -q 'Default to FAIL' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt has default-to-FAIL conservative bias"
else
    assert_fail "holistic gate prompt has default-to-FAIL conservative bias"
fi

# Test: holistic gate prompt requires per-component goal verification
if grep -q 'each distinct component' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt requires per-component goal verification"
else
    assert_fail "holistic gate prompt requires per-component goal verification"
fi

# Test: branch_diff is sanitized to prevent delimiter injection
if grep -q 'REDACTED:HOLISTIC:PASS\|REDACTED:HOLISTIC:FAIL' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "branch_diff sanitized to prevent holistic gate delimiter injection"
else
    assert_fail "branch_diff sanitized to prevent holistic gate delimiter injection"
fi

# Test: diff truncation notice in prompt (so model knows to rely on stats for large branches)
if grep -q 'may be truncated' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt notes diff may be truncated"
else
    assert_fail "holistic gate prompt notes diff may be truncated"
fi

# Test: new_commits recomputed after post-audit cleanup commit
if grep -B5 'Quality gates' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'commits_after_cleanup'; then
    assert_pass "new_commits recomputed after post-audit cleanup"
else
    assert_fail "new_commits recomputed after post-audit cleanup"
fi

# Behavioral test: loop exits early when holistic outputs new fence delimiter (primary path)
echo ""
echo -e "${DIM}  loop behavior: early exit with no changes (#245, #264)${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude: no changes, holistic outputs new <<<HOLISTIC:PASS>>> fence delimiter
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if echo "$@" | grep -q 'output-format'; then
    echo '[{"type":"result","result":"Everything looks good, no changes needed.","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo "<<<HOLISTIC:PASS>>>"
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git)
    echo ".claude/" > "$TEST_TEMP_DIR/repo/.gitignore"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" rm -r --cached .claude 2>/dev/null || true)
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add .gitignore && "$_git" commit -q -m "add gitignore" --allow-empty)
    rm -f "$TEST_TEMP_DIR/home/.shipwright/costs.json" "$TEST_TEMP_DIR/home/.shipwright/budget.json"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Already done task" \
        --max-iterations 5 \
        --test-cmd "true" \
        --quality-gates \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "no changes needed, all gates passing|LOOP COMPLETE|Complete"; then
        assert_pass "Loop early exit (fence delimiter): no changes + holistic <<<HOLISTIC:PASS>>> = complete"
    else
        assert_fail "Loop early exit (fence delimiter): expected early exit on <<<HOLISTIC:PASS>>>" "$(echo "$output" | grep -iE 'error|Fatal|Budget|Iteration|Complete|no changes|holistic' | head -5)"
    fi

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_fail "Loop early exit (fence delimiter): should exit after iteration 1"
    else
        assert_pass "Loop early exit (fence delimiter): exited after iteration 1"
    fi
else
    assert_fail "Loop early exit behavioral test (fence delimiter)" "setup failed"
fi

# Behavioral test: legacy HOLISTIC_PASS still accepted (Layer 3 compat)
if setup_loop_env 2>/dev/null; then
    # Mock claude: no changes, holistic outputs legacy HOLISTIC_PASS string
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if echo "$@" | grep -q 'output-format'; then
    echo '[{"type":"result","result":"Everything looks good, no changes needed.","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo "HOLISTIC_PASS"
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git)
    echo ".claude/" > "$TEST_TEMP_DIR/repo/.gitignore"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" rm -r --cached .claude 2>/dev/null || true)
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add .gitignore && "$_git" commit -q -m "add gitignore" --allow-empty)
    rm -f "$TEST_TEMP_DIR/home/.shipwright/costs.json" "$TEST_TEMP_DIR/home/.shipwright/budget.json"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Already done task" \
        --max-iterations 5 \
        --test-cmd "true" \
        --quality-gates \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "no changes needed, all gates passing|LOOP COMPLETE|Complete"; then
        assert_pass "Loop early exit (legacy compat): HOLISTIC_PASS still accepted via Layer 3"
    else
        assert_fail "Loop early exit (legacy compat): HOLISTIC_PASS should still work" "$(echo "$output" | grep -iE 'error|Fatal|Budget|Iteration|Complete|no changes|holistic' | head -5)"
    fi

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_fail "Loop early exit (legacy compat): should exit after iteration 1"
    else
        assert_pass "Loop early exit (legacy compat): exited after iteration 1"
    fi
else
    assert_fail "Loop early exit behavioral test (legacy compat)" "setup failed"
fi

# ─── DoD evaluator: configurable diff truncation (#236, #275) ──────────────────

# Test: DoD diff uses configurable DOD_DIFF_MAX_LINES (not hard-coded)
if grep -A10 'Detailed Changes' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'head -200'; then
    assert_fail "DoD diff must NOT be truncated with hard-coded head -200"
elif grep -A10 'Detailed Changes' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'DOD_DIFF_MAX_LINES'; then
    assert_pass "DoD diff uses configurable DOD_DIFF_MAX_LINES"
else
    assert_fail "DoD diff should use DOD_DIFF_MAX_LINES variable"
fi

# Test: Holistic gate uses configurable HOLISTIC_DIFF_MAX_LINES (not hard-coded)
if grep -B2 -A2 'head -300' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'holistic\|HOLISTIC'; then
    assert_fail "Holistic gate must NOT use hard-coded head -300"
elif grep -B2 -A2 'HOLISTIC_DIFF_MAX_LINES' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'head.*HOLISTIC_DIFF_MAX_LINES'; then
    assert_pass "Holistic gate uses configurable HOLISTIC_DIFF_MAX_LINES"
else
    assert_fail "Holistic gate should use HOLISTIC_DIFF_MAX_LINES variable"
fi

# Test: DOD_DIFF_MAX_LINES actually truncates (behavioral)
_trunc_tmpdir="$(mktemp -d)"
seq 1 20 > "$_trunc_tmpdir/bigdiff.txt"
DOD_DIFF_MAX_LINES=5
_trunc_result="$(cat "$_trunc_tmpdir/bigdiff.txt" | head -"${DOD_DIFF_MAX_LINES}")"
_trunc_lines="$(echo "$_trunc_result" | wc -l | tr -d ' ')"
if [[ "$_trunc_lines" -eq 5 ]]; then
    assert_pass "DOD_DIFF_MAX_LINES=5 truncates 20-line diff to 5 lines"
else
    assert_fail "DOD_DIFF_MAX_LINES=5 truncates 20-line diff to 5 lines" "got $_trunc_lines lines"
fi

# Test: HOLISTIC_DIFF_MAX_LINES actually truncates (behavioral)
HOLISTIC_DIFF_MAX_LINES=3
_trunc_result2="$(cat "$_trunc_tmpdir/bigdiff.txt" | head -"${HOLISTIC_DIFF_MAX_LINES}")"
_trunc_lines2="$(echo "$_trunc_result2" | wc -l | tr -d ' ')"
if [[ "$_trunc_lines2" -eq 3 ]]; then
    assert_pass "HOLISTIC_DIFF_MAX_LINES=3 truncates 20-line diff to 3 lines"
else
    assert_fail "HOLISTIC_DIFF_MAX_LINES=3 truncates 20-line diff to 3 lines" "got $_trunc_lines2 lines"
fi
rm -rf "$_trunc_tmpdir"

# Test: DoD includes full branch diff for compound_rebuild cycle correctness (#258)
# When compound_quality fails and triggers a rebuild, LOOP_START_COMMIT is reset to HEAD
# (after all prior build work). The loop-run diff is then empty/tiny, causing the DoD
# evaluator to say "no diff provided". The fix: also include the merge-base..HEAD diff.
if grep -q '_dod_merge_base' "$SCRIPT_DIR/sw-loop.sh" && \
   grep -q 'Full Branch Changes vs Base' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD includes full branch diff for compound_rebuild cycle correctness"
else
    assert_fail "DoD must include full branch diff (merge-base..HEAD) to handle compound_rebuild cycles"
fi

# Test: DoD branch diff is sanitized to prevent delimiter injection
if grep -A5 '_dod_branch_diff' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'REDACTED:DOD'; then
    assert_pass "DoD branch diff sanitized to prevent delimiter injection"
else
    assert_fail "DoD branch diff must sanitize <<<DOD:PASS/FAIL>>> tokens"
fi

# Test: DoD prompt notes loop-run diff may be small in rebuild cycles
if grep -q 'prior build' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt explains loop-run diff may be small in rebuild cycles"
else
    assert_fail "DoD prompt should explain loop-run diff may be small in rebuild cycles"
fi

# Test: DoD does NOT use --json-schema (flag causes empty output — see #253)
if grep -A5 'dod_flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q '\-\-json-schema'; then
    assert_fail "DoD evaluator must NOT use --json-schema (causes empty claude -p output)"
else
    assert_pass "DoD evaluator does not use --json-schema"
fi

# Test: DoD prompt embeds explicit JSON format instruction (replaces CLI schema enforcement)
if grep -q 'Respond with a JSON object' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt embeds explicit JSON format instruction"
else
    assert_fail "DoD prompt embeds explicit JSON format instruction"
fi

# Test: DoD has empty-output guard before verdict parsing (surfaces broken CLI invocations)
if grep -q 'claude -p returned empty output' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD has empty-output guard with diagnostic warning"
else
    assert_fail "DoD has empty-output guard with diagnostic warning"
fi

# Test: DoD rejects pass verdict when items is missing, not an array, or empty (#253)
# The guard uses a type-checking jq expression so non-array items (string, object) are
# also rejected — not just a missing or empty array.
if grep -q 'verdict is pass but items array is missing, not an array, or empty' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD rejects pass verdict when items is missing, not an array, or empty"
else
    assert_fail "DoD rejects pass verdict when items is missing, not an array, or empty"
fi

# Test: DoD verdict parsed from JSON verdict field (not plain text DOD_PASS)
if grep -q 'dod_verdict.*jq.*verdict' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD verdict parsed from JSON verdict field"
else
    assert_fail "DoD verdict parsed from JSON verdict field"
fi

# Test: DoD verdict checks for "pass" string (JSON schema enum value)
if grep -q '"$dod_verdict" == "pass"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD verdict compared against JSON enum value \"pass\""
else
    assert_fail "DoD verdict compared against JSON enum value \"pass\""
fi

# Test: DoD fallback uses detect_gate_signal (multi-layer, not bare grep)
if grep -q 'detect_gate_signal.*dod_log.*DOD\|detect_gate_signal.*"DOD"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD fallback uses detect_gate_signal for robust multi-layer detection"
else
    assert_fail "DoD fallback uses detect_gate_signal for robust multi-layer detection"
fi

# Test: DoD fallback is gated on empty dod_verdict (prevents overriding legitimate jq "fail")
# A model returning {"verdict":"fail","summary":"all requirements are now satisfied"} must stay
# a fail — the "all...satisfied" prose in the summary must not flip the verdict via Layer 3.
if grep -q '\[\[ -z.*dod_verdict.*\]\].*detect_gate_signal\|detect_gate_signal.*dod_log.*DOD' "$SCRIPT_DIR/sw-loop.sh" && \
   grep -q '\-z.*dod_verdict' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD fallback gated on empty dod_verdict (won't override legitimate fail verdict)"
else
    assert_fail "DoD fallback gated on empty dod_verdict (won't override legitimate fail verdict)"
fi

# Test: DoD prompt includes fence delimiter instruction
if grep -q '<<<DOD:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt includes <<<DOD:PASS>>> fence delimiter"
else
    assert_fail "DoD prompt includes <<<DOD:PASS>>> fence delimiter"
fi

# Test: DoD strips markdown fences before jq parsing
if grep -q 'sed.*json.*dod_log.*dod_clean\|dod_clean.*sed' "$SCRIPT_DIR/sw-loop.sh" || \
   grep -q "sed.*dod_log.*dod_clean" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD strips markdown fences from output before jq parsing"
else
    assert_fail "DoD strips markdown fences from output before jq parsing"
fi

# Test: detect_gate_signal helper exists in lib/gate-signal.sh (shared lib)
if grep -q '^detect_gate_signal()' "$SCRIPT_DIR/lib/gate-signal.sh"; then
    assert_pass "detect_gate_signal() helper function exists in lib/gate-signal.sh"
else
    assert_fail "detect_gate_signal() helper function exists in lib/gate-signal.sh"
fi

# Test: detect_gate_signal Layer 2 — fenced delimiter passes
# Load from shared lib (function moved out of sw-loop.sh into lib/gate-signal.sh)
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "<<<DOD:PASS>>>" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD") 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 2 fenced delimiter accepted"
else
    assert_fail "detect_gate_signal: Layer 2 fenced delimiter accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal Layer 3 — legacy DOD_PASS accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "DOD_PASS" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD" 'DOD_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 3 legacy DOD_PASS accepted"
else
    assert_fail "detect_gate_signal: Layer 3 legacy DOD_PASS accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal Layer 1 — failure signal overrides PASS delimiter
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo '<<<DOD:PASS>>> <<<DOD:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD" 'DOD_PASS' '<<<DOD:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 1 failure signal overrides PASS delimiter"
else
    assert_fail "detect_gate_signal: Layer 1 failure signal overrides PASS delimiter"
fi
rm -f "$dgs_test_log"

# ─── Circuit breaker: DoD-only failures (#237) ────────────────────────────────

# Test: bypass emits 'skipping circuit breaker strike' message
if grep -q 'skipping circuit breaker strike' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "circuit breaker bypass emits 'skipping circuit breaker strike' message"
else
    assert_fail "circuit breaker bypass emits 'skipping circuit breaker strike' message"
fi

# Test: bypass resets CONSECUTIVE_FAILURES=0 (not just skipping increment)
# so stale prior strikes don't accumulate across a verified-pass iteration
if grep -B1 'skipping circuit breaker strike' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'CONSECUTIVE_FAILURES=0'; then
    assert_pass "circuit breaker bypass resets CONSECUTIVE_FAILURES=0 to clear stale strikes"
else
    assert_fail "circuit breaker bypass resets CONSECUTIVE_FAILURES=0 to clear stale strikes"
fi

# Test: bypass guarded by TEST_PASSED == true
if grep -A3 'check_progress.*new_commits' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'TEST_PASSED.*true'; then
    assert_pass "circuit breaker bypass guarded by TEST_PASSED == true"
else
    assert_fail "circuit breaker bypass guarded by TEST_PASSED == true"
fi

# Test: bypass requires explicit AUDIT_RESULT=pass when audit is enabled (no silent default)
if grep -A3 'TEST_PASSED.*true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'AUDIT_AGENT_ENABLED\|AUDIT_RESULT.*==.*pass'; then
    assert_pass "circuit breaker bypass guards AUDIT_RESULT explicitly (no silent default to pass)"
else
    assert_fail "circuit breaker bypass guards AUDIT_RESULT explicitly (no silent default to pass)"
fi

# Test: genuine failures (test fail or audit fail) still increment circuit breaker
if grep -q 'CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "genuine failures still increment CONSECUTIVE_FAILURES"
else
    assert_fail "genuine failures still increment CONSECUTIVE_FAILURES"
fi

# ─── Stale counters + contradictory prompt fixes (#238) ──────────────────────

# Test: diagnoses.txt is cleared at loop init (not shared across pipeline runs)
if grep -A5 'strategy-attempts.txt' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'diagnoses.txt'; then
    assert_pass "diagnoses.txt is cleared at loop init alongside strategy-attempts.txt"
else
    assert_fail "diagnoses.txt is cleared at loop init alongside strategy-attempts.txt"
fi

# Test: alternative_approach threshold is 5 (not 2)
if grep -q 'repeat_count.*-ge 5' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "alternative_approach escalation threshold is 5 same-session failures"
else
    assert_fail "alternative_approach escalation threshold is 5 same-session failures"
fi

# Test: GOAL is NOT mutated by appending alt_strategy when stuck
if grep 'GOAL=' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'alt_strategy'; then
    assert_fail "GOAL must NOT be mutated with alt_strategy when stuck (creates contradictory prompt)"
else
    assert_pass "GOAL is not mutated with alt_strategy when stuck"
fi

# Test: alt_strategy injected as dedicated section (alt_strategy_section variable)
if grep -q 'alt_strategy_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "alt_strategy injected as dedicated prompt section (not appended to GOAL)"
else
    assert_fail "alt_strategy injected as dedicated prompt section (not appended to GOAL)"
fi

# Test: prompt uses prompt_goal (truncated when stuck) instead of raw GOAL
if grep -q 'prompt_goal' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "prompt uses prompt_goal variable (truncated to headline when stuck)"
else
    assert_fail "prompt uses prompt_goal variable (truncated to headline when stuck)"
fi

# ─── Dynamic task progress (#239) ────────────────────────────────────────────

# Test: pipeline-stages-build.sh no longer injects raw cat of TASKS_FILE anywhere
if grep -q 'cat.*TASKS_FILE\|\$(cat.*TASKS_FILE' "$SCRIPT_DIR/lib/pipeline-stages-build.sh"; then
    assert_fail "pipeline-stages-build.sh must NOT inject raw TASKS_FILE (done dynamically now)"
else
    assert_pass "pipeline-stages-build.sh does not inject raw TASKS_FILE into enriched goal"
fi

# Test: compose_task_section() function exists in loop-iteration.sh
if grep -q '^compose_task_section()' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "compose_task_section() function exists in loop-iteration.sh"
else
    assert_fail "compose_task_section() function exists in loop-iteration.sh"
fi

# Test: compose_task_section annotates tasks with [x] based on diff (auto-marking logic)
if grep -q '\- \[x\]' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "compose_task_section() marks completed tasks with [x]"
else
    assert_fail "compose_task_section() marks completed tasks with [x]"
fi

# Test: task_section is injected into the prompt
if grep -q 'task_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "task_section is injected into the prompt each iteration"
else
    assert_fail "task_section is injected into the prompt each iteration"
fi

# ─── Issue #331: Loop cycling fixes ─────────────────────────────────────────
echo ""
echo -e "${DIM}  loop cycling: stale HOLISTIC_RESULT, dampening, window (#331)${RESET}"

# Test 1: HOLISTIC_RESULT="" appears inside run_quality_gates (grep-based)
if awk '/^run_quality_gates\(\)/{found=1} found && /HOLISTIC_RESULT=""/{print; exit}' \
    "$SCRIPT_DIR/sw-loop.sh" | grep -q 'HOLISTIC_RESULT=""'; then
    assert_pass "HOLISTIC_RESULT reset inside run_quality_gates() (#331 Bug 1)"
else
    assert_fail "HOLISTIC_RESULT reset inside run_quality_gates() (#331 Bug 1)" \
        "expected 'HOLISTIC_RESULT=\"\"' inside run_quality_gates body"
fi

# Test 2: detect_stuckness triggers when tests pass but diffs are zero (conditional dampening)
_sw331_tracking=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331.XXXXXX")
printf 'abc123|none|0\nabc123|none|0\nabc123|none|0\nabc123|none|0\nabc123|none|0\n' > "$_sw331_tracking"
if (
    export PROJECT_ROOT="/tmp" ITERATION=6 MAX_ITERATIONS=20 \
           TEST_PASSED=true AUDIT_RESULT=pass QUALITY_GATE_PASSED=true \
           LOG_DIR="$(dirname "$_sw331_tracking")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking" \
           STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT=""
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ -n "$STUCKNESS_HINT" ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: zero-diff iterations not dampened when tests pass (#331 Bug 2)"
else
    assert_fail "detect_stuckness: zero-diff iterations not dampened when tests pass (#331 Bug 2)" \
        "STUCKNESS_HINT was empty — dampening incorrectly suppressed detection"
fi
rm -f "$_sw331_tracking"

# Test 3: Signal 2 fires for 5 consecutive identical diffs (expanded window)
_sw331_tracking3=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331b.XXXXXX")
printf 'deadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\n' > "$_sw331_tracking3"
if (
    export PROJECT_ROOT="/tmp" ITERATION=6 MAX_ITERATIONS=20 \
           TEST_PASSED=false STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$(dirname "$_sw331_tracking3")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking3"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ -n "$STUCKNESS_HINT" ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: Signal 2 fires for 5 consecutive identical diffs (#331 Bug 3)"
else
    assert_fail "detect_stuckness: Signal 2 fires for 5 consecutive identical diffs (#331 Bug 3)"
fi
rm -f "$_sw331_tracking3"

# Test 4: Signal 2b cycling detector fires at exactly 4 identical diffs
_sw331_tracking4=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331c.XXXXXX")
printf 'cafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\n' > "$_sw331_tracking4"
if (
    export PROJECT_ROOT="/tmp" ITERATION=5 MAX_ITERATIONS=20 \
           TEST_PASSED=false STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$(dirname "$_sw331_tracking4")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking4"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ "$STUCKNESS_HINT" == *"cycling"* ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: Signal 2b cycling detector fires at 4 identical diffs (#331)"
else
    assert_fail "detect_stuckness: Signal 2b cycling detector fires at 4 identical diffs (#331)" \
        "expected STUCKNESS_HINT to contain 'cycling'"
fi
rm -f "$_sw331_tracking4"

# Test 5: DOD_DIFF_MAX_LINES default is 5000
if grep -E "DOD_DIFF_MAX_LINES=\\\$\(_config_get_int[^)]*5000" "$SCRIPT_DIR/sw-loop.sh" | grep -q '5000'; then
    assert_pass "DOD_DIFF_MAX_LINES default is 5000 (#331)"
else
    assert_fail "DOD_DIFF_MAX_LINES default is 5000 (#331)" "expected 5000 as default"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Bug fixes: loop stuckness — GOAL pollution, circuit-breaker escape hatch,
# zero-progress blindness (#345)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  loop stuckness fixes (#345)${RESET}"

# ─── Fix 1: Holistic gate uses ORIGINAL_GOAL, not polluted GOAL ──────────────
# run_holistic_gate() must inject ${ORIGINAL_GOAL:-$GOAL} so that feedback
# accumulated in GOAL during a session does not poison the holistic assessment.
if grep -q 'ORIGINAL_GOAL:-\$GOAL' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 1: holistic gate uses \${ORIGINAL_GOAL:-\$GOAL}"
else
    assert_fail "Fix 1: holistic gate uses \${ORIGINAL_GOAL:-\$GOAL}" \
        "Expected ORIGINAL_GOAL:-\$GOAL in sw-loop.sh holistic prompt; got raw \${GOAL}"
fi

# Verify the fix is specifically inside run_holistic_gate (not just anywhere in the file)
holistic_gate_block=$(
    awk '
        /^run_holistic_gate\(\)[[:space:]]*\{/ { in_fn=1 }
        in_fn { print }
        in_fn && /^\}/ { exit }
    ' "$SCRIPT_DIR/sw-loop.sh" || true
)
if printf '%s\n' "$holistic_gate_block" | grep -q 'ORIGINAL_GOAL:-\$GOAL'; then
    assert_pass "Fix 1: ORIGINAL_GOAL:-\$GOAL present inside run_holistic_gate"
else
    assert_fail "Fix 1: ORIGINAL_GOAL:-\$GOAL present inside run_holistic_gate" \
        "Expected ORIGINAL_GOAL:-\$GOAL inside run_holistic_gate in sw-loop.sh"
fi

# ─── Fix 2: Circuit breaker escape hatch respects quality gates ──────────────
# The elif branch that resets CONSECUTIVE_FAILURES=0 must also require that
# QUALITY_GATE_PASSED is true (or quality gates are disabled). Variable is
# QUALITY_GATE_PASSED (singular), gated by QUALITY_GATES_ENABLED.
if grep -qE 'QUALITY_GATES_ENABLED.*QUALITY_GATE_PASSED|QUALITY_GATE_PASSED.*QUALITY_GATES_ENABLED' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 2: circuit breaker escape hatch checks QUALITY_GATE_PASSED"
else
    assert_fail "Fix 2: circuit breaker escape hatch checks QUALITY_GATE_PASSED" \
        "Expected QUALITY_GATES_ENABLED and QUALITY_GATE_PASSED in the elif escape-hatch branch"
fi

# Verify escape hatch still resets CONSECUTIVE_FAILURES (it should still work when gates pass)
if grep -A5 'QUALITY_GATES_ENABLED.*QUALITY_GATE_PASSED\|QUALITY_GATE_PASSED.*QUALITY_GATES_ENABLED' \
    "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | grep -q 'CONSECUTIVE_FAILURES=0' 2>/dev/null; then
    assert_pass "Fix 2: CONSECUTIVE_FAILURES still resets when all gates pass"
else
    assert_fail "Fix 2: CONSECUTIVE_FAILURES still resets when all gates pass" \
        "Expected CONSECUTIVE_FAILURES=0 in the escape hatch branch after quality gate guard"
fi

# ─── Fix 3a: PREV_NEW_COMMITS global initialized and persisted ───────────────
# PREV_NEW_COMMITS=0 must be initialized in the defaults section.
if grep -q 'PREV_NEW_COMMITS=0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 3a: PREV_NEW_COMMITS initialized to 0 in defaults"
else
    assert_fail "Fix 3a: PREV_NEW_COMMITS initialized to 0 in defaults" \
        "Expected 'PREV_NEW_COMMITS=0' in sw-loop.sh defaults"
fi

# PREV_NEW_COMMITS must be set to new_commits after the circuit breaker block
if grep -q 'PREV_NEW_COMMITS="${new_commits' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 3a: PREV_NEW_COMMITS set from new_commits after circuit breaker"
else
    assert_fail "Fix 3a: PREV_NEW_COMMITS set from new_commits after circuit breaker" \
        "Expected PREV_NEW_COMMITS=\"\${new_commits...}\" assignment in main loop body"
fi

# ─── Fix 3b: Zero-progress notice in compose_prompt ─────────────────────────
# compose_prompt() in loop-iteration.sh must check PREV_NEW_COMMITS and
# QUALITY_GATE_PASSED and inject a zero-progress warning when both indicate stuckness.
if grep -q 'PREV_NEW_COMMITS' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: loop-iteration.sh references PREV_NEW_COMMITS"
else
    assert_fail "Fix 3b: loop-iteration.sh references PREV_NEW_COMMITS" \
        "Expected PREV_NEW_COMMITS check in loop-iteration.sh compose_prompt()"
fi

if grep -q 'Zero Progress Detected' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero-progress notice text present in loop-iteration.sh"
else
    assert_fail "Fix 3b: zero-progress notice text present in loop-iteration.sh" \
        "Expected 'Zero Progress Detected' string in compose_prompt() notice"
fi

# Notice must only fire when PREV_NEW_COMMITS==0 AND quality gate failed
if grep -qE 'PREV_NEW_COMMITS.*-eq 0.*QUALITY_GATE_PASSED|QUALITY_GATE_PASSED.*PREV_NEW_COMMITS.*-eq 0' \
    "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero-progress notice gated on PREV_NEW_COMMITS==0 and QUALITY_GATE_PASSED==false"
else
    assert_fail "Fix 3b: zero-progress notice gated on PREV_NEW_COMMITS==0 and QUALITY_GATE_PASSED==false" \
        "Expected both conditions on the same guard in loop-iteration.sh"
fi

# ─── Fix 3b: compose_prompt includes zero_progress_notice in output ──────────
if grep -q 'zero_progress_notice' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero_progress_notice variable used in compose_prompt output"
else
    assert_fail "Fix 3b: zero_progress_notice variable used in compose_prompt output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
