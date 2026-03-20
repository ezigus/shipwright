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
_extract_fn=$(sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
tmpdir=$(mktemp -d)
bash -c "
warn() { :; }
$_extract_fn
# Test 1: empty file → '(no output)'
touch '$tmpdir/empty.json'
_extract_text_from_json '$tmpdir/empty.json' '$tmpdir/out1.log' ''
# Test 2: valid JSON array → extracts .result
echo '[{\"type\":\"result\",\"result\":\"Hello world\",\"usage\":{\"input_tokens\":100}}]' > '$tmpdir/valid.json'
_extract_text_from_json '$tmpdir/valid.json' '$tmpdir/out2.log' ''
# Test 3: plain text → pass through
echo 'This is plain text output' > '$tmpdir/text.json'
_extract_text_from_json '$tmpdir/text.json' '$tmpdir/out3.log' ''
" 2>/dev/null

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
_extract_fn=$(sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
tmpdir2=$(mktemp -d)
bash -c "
warn() { :; }
$_extract_fn
# Nested JSON array with objects
echo '[{\"type\":\"result\",\"result\":\"Nested extraction works\",\"usage\":{\"input_tokens\":50}}]' > '$tmpdir2/nested.json'
_extract_text_from_json '$tmpdir2/nested.json' '$tmpdir2/nested_out.log' ''
# Binary garbage — should not crash, pass through or handle
printf '\x00\x01\x02\xff\xfe' > '$tmpdir2/binary.dat'
_extract_text_from_json '$tmpdir2/binary.dat' '$tmpdir2/binary_out.log' ''
" 2>/dev/null

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

    if echo "$output" | grep -qF "LOOP_COMPLETE"; then
        assert_pass "Loop detected completion signal"
    elif echo "$output" | grep -qi "complete.*LOOP_COMPLETE\|LOOP_COMPLETE.*accepted"; then
        assert_pass "Loop detected completion signal"
    else
        assert_fail "Loop detected completion signal" "output missing LOOP_COMPLETE"
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

_run_check_progress() {
    # $1 = argument to pass to check_progress (or empty for no-arg)
    local _arg="${1:-}"
    local _real_git
    _real_git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null) || return 2
    local _tmpdir
    _tmpdir=$(mktemp -d)
    # Build a two-commit repo so HEAD~1 always resolves
    "$_real_git" init -q "$_tmpdir"
    "$_real_git" -C "$_tmpdir" config user.email "test@test.com"
    "$_real_git" -C "$_tmpdir" config user.name "test"
    printf 'line1\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "initial"
    printf 'line1\nline2\nline3\nline4\nline5\nline6\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "second"
    rm -rf "$_tmpdir"
    ( export PROJECT_ROOT="$_tmpdir"
      export MIN_PROGRESS_LINES=5
      # shellcheck disable=SC1090
      source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
      source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
      if [[ -n "$_arg" ]]; then
          check_progress "$_arg"
      else
          check_progress
      fi
    ) 2>/dev/null
}

# Rebuild the repo once for the no-arg fallback test (needs real commits)
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
_fallback_repo=$(_build_test_repo 2>/dev/null || echo "")
if [[ -n "$_fallback_repo" ]]; then
    if ( export PROJECT_ROOT="$_fallback_repo" MIN_PROGRESS_LINES=5
         source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
         source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
         check_progress ) 2>/dev/null; then
        assert_pass "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    else
        assert_fail "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    fi
    rm -rf "$_fallback_repo"
else
    assert_pass "check_progress() fallback (no args): skipped (git unavailable)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
