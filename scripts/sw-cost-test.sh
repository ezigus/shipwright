#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost test — Validate token usage & cost intelligence         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock sqlite3
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Cost Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows COMMANDS" "$output" "COMMANDS"
assert_contains "help mentions show" "$output" "show"
assert_contains "help mentions budget" "$output" "budget"
assert_contains "help mentions calculate" "$output" "calculate"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-cost.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: cost dir creation ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

# Running 'show' should create cost files
bash "$SCRIPT_DIR/sw-cost.sh" show >/dev/null 2>&1 || true
if [[ -f "$HOME/.shipwright/costs.json" ]]; then
    assert_pass "costs.json created on first use"
else
    assert_fail "costs.json created on first use"
fi
if [[ -f "$HOME/.shipwright/budget.json" ]]; then
    assert_pass "budget.json created on first use"
else
    assert_fail "budget.json created on first use"
fi

# ─── Test 4: costs.json has valid structure ─────────────────────────────────
cost_valid=$(jq -e '.entries' "$HOME/.shipwright/costs.json" >/dev/null 2>&1&& echo "yes" || echo "no")
assert_eq "costs.json has entries array" "yes" "$cost_valid"

# ─── Test 5: budget.json has valid structure ────────────────────────────────
budget_valid=$(jq -e '.daily_budget_usd' "$HOME/.shipwright/budget.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "budget.json has daily_budget_usd" "yes" "$budget_valid"

# ─── Test 6: budget set command ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  budget commands${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget set 50.00 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget set exits 0"
else
    assert_fail "budget set exits 0" "exit code: $rc"
fi

# Verify budget was written
budget_val=$(jq -r '.daily_budget_usd' "$HOME/.shipwright/budget.json" 2>/dev/null || echo "")
assert_eq "budget set to 50" "50.00" "$budget_val"

# ─── Test 7: budget show command ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget show 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget show exits 0"
else
    assert_fail "budget show exits 0" "exit code: $rc"
fi

# ─── Test 8: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 9: calculate command ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  calculate${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" calculate 50000 10000 opus 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "calculate exits 0"
else
    assert_fail "calculate exits 0" "exit code: $rc"
fi

# ─── Test 10: set -euo pipefail ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test: context efficiency section in dashboard ─────────────────────────
echo ""
echo -e "${DIM}  context efficiency in cost dashboard${RESET}"

if grep -q 'CONTEXT EFFICIENCY' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard has CONTEXT EFFICIENCY section"
else
    assert_fail "Cost dashboard has CONTEXT EFFICIENCY section"
fi

if grep -q 'loop.context_efficiency' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard reads loop.context_efficiency events"
else
    assert_fail "Cost dashboard reads loop.context_efficiency events"
fi

if grep -q 'Avg budget used' "$SCRIPT_DIR/sw-cost.sh" && grep -q 'Chars discarded' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Context efficiency reports utilization and waste"
else
    assert_fail "Context efficiency reports utilization and waste"
fi

# Functional test: write mock events and verify dashboard parses them
# Use dynamic epoch (yesterday) so the test doesn't rot as time passes
_mock_epoch=$(( $(date +%s) - 86400 ))
_mock_ts=$(date -u -r "$_mock_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
           date -u -d "@$_mock_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || \
  { echo "ERROR: date command failed on both macOS and GNU formats" >&2; exit 1; }
[[ -z "$_mock_ts" ]] && { echo "ERROR: timestamp is empty after date command" >&2; exit 1; }
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
cat > "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" <<EVTEOF
{"ts":"${_mock_ts}","type":"loop.context_efficiency","iteration":"1","raw_prompt_chars":"200000","trimmed_prompt_chars":"180000","trim_ratio":"10.0","budget_utilization":"100.0","budget_chars":"180000","job_id":"test-1"}
{"ts":"${_mock_ts}","type":"loop.context_efficiency","iteration":"2","raw_prompt_chars":"150000","trimmed_prompt_chars":"150000","trim_ratio":"0.0","budget_utilization":"83.3","budget_chars":"180000","job_id":"test-1"}
EVTEOF

# Also need cost data for the dashboard to run
cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<COSTEOF
{"entries":[{"ts":"${_mock_ts}","ts_epoch":${_mock_epoch},"input_tokens":50000,"output_tokens":10000,"cost_usd":1.50,"model":"opus","stage":"build","issue":"1"}],"summary":{}}
COSTEOF
cat > "$TEST_TEMP_DIR/home/.shipwright/budget.json" <<'BUDEOF'
{"daily_budget_usd":0,"enabled":false}
BUDEOF

dash_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --period 30 2>&1) || true

if echo "$dash_output" | grep -q "CONTEXT EFFICIENCY"; then
    assert_pass "Dashboard renders CONTEXT EFFICIENCY with event data"
else
    assert_fail "Dashboard renders CONTEXT EFFICIENCY with event data" "output: $(echo "$dash_output" | tail -5)"
fi

if echo "$dash_output" | grep -q "Avg budget used"; then
    assert_pass "Dashboard shows avg budget utilization"
else
    assert_fail "Dashboard shows avg budget utilization"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: per-iteration and stage-level cost attribution (issue #87)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Per-Iteration and Stage-Level Cost Attribution${RESET}"

# ── Test 1: cost_generate_breakdown with sidecar data ──────────────────────────
_bd_dir="$TEST_TEMP_DIR/breakdown-test"
mkdir -p "$_bd_dir"
_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '%s\n' \
    "{\"iteration\":1,\"input_tokens\":5000,\"output_tokens\":2000,\"cost_usd\":0.045,\"ts\":\"${_now}\"}" \
    "{\"iteration\":2,\"input_tokens\":4000,\"output_tokens\":1800,\"cost_usd\":0.039,\"ts\":\"${_now}\"}" \
    "{\"iteration\":3,\"input_tokens\":3500,\"output_tokens\":1500,\"cost_usd\":0.033,\"ts\":\"${_now}\"}" \
    > "$_bd_dir/loop-iteration-costs.jsonl"
printf '%s\n' \
    "{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"review\",\"input_tokens\":3000,\"output_tokens\":1000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    > "$_bd_dir/stage-costs.jsonl"

_bd_out=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_dir" "test-pipeline" "87" 2>&1) || true

if [[ -f "$_bd_dir/cost-breakdown.json" ]]; then
    assert_pass "cost_generate_breakdown creates cost-breakdown.json"
    _iter_count=$(jq '.summary.iteration_count' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    _stage_count=$(jq '.by_stage | length' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    _iter_len=$(jq '.by_iteration | length' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    if [[ "$_iter_count" == "3" ]]; then
        assert_pass "breakdown: summary.iteration_count == 3"
    else
        assert_fail "breakdown: summary.iteration_count == 3" "got: ${_iter_count}"
    fi
    if [[ "$_stage_count" == "2" ]]; then
        assert_pass "breakdown: by_stage has 2 entries"
    else
        assert_fail "breakdown: by_stage has 2 entries" "got: ${_stage_count}"
    fi
    if [[ "$_iter_len" == "3" ]]; then
        assert_pass "breakdown: by_iteration has 3 entries"
    else
        assert_fail "breakdown: by_iteration has 3 entries" "got: ${_iter_len}"
    fi
else
    assert_fail "cost_generate_breakdown creates cost-breakdown.json" "output: $(echo "$_bd_out" | tail -3)"
    assert_fail "breakdown: summary.iteration_count == 3"
    assert_fail "breakdown: by_stage has 2 entries"
    assert_fail "breakdown: by_iteration has 3 entries"
fi

# ── Test 2: cost_generate_breakdown with no sidecars ───────────────────────────
_bd_empty="$TEST_TEMP_DIR/breakdown-empty"
mkdir -p "$_bd_empty"
env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_empty" "empty-pipeline" "" 2>&1 || true

if [[ -f "$_bd_empty/cost-breakdown.json" ]]; then
    _empty_iter=$(jq '.by_iteration | length' "$_bd_empty/cost-breakdown.json" 2>/dev/null || echo "err")
    _empty_stage=$(jq '.by_stage | length' "$_bd_empty/cost-breakdown.json" 2>/dev/null || echo "err")
    if [[ "$_empty_iter" == "0" && "$_empty_stage" == "0" ]]; then
        assert_pass "breakdown with no sidecars produces valid JSON with empty arrays"
    else
        assert_fail "breakdown with no sidecars produces valid JSON with empty arrays" \
            "by_iteration=${_empty_iter} by_stage=${_empty_stage}"
    fi
else
    assert_fail "breakdown with no sidecars produces valid JSON with empty arrays"
fi

# ── Test 3: --by-iteration flag ─────────────────────────────────────────────────
_bd_flag_dir="$TEST_TEMP_DIR/breakdown-flag"
mkdir -p "$_bd_flag_dir"
printf '%s\n' \
    "{\"pipeline_id\":\"p1\",\"issue\":\"87\",\"generated_at\":\"${_now}\",\"summary\":{\"total_input_tokens\":12500,\"total_output_tokens\":5300,\"iteration_count\":2,\"stage_count\":1},\"by_stage\":[{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300}],\"by_iteration\":[{\"iteration\":1,\"input_tokens\":5000,\"output_tokens\":2000,\"cost_usd\":0.045,\"ts\":\"${_now}\"},{\"iteration\":2,\"input_tokens\":4000,\"output_tokens\":1800,\"cost_usd\":0.039,\"ts\":\"${_now}\"}]}" \
    > "$_bd_flag_dir/cost-breakdown.json"

_iter_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    ARTIFACTS_DIR="$_bd_flag_dir" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --by-iteration 2>&1) || true
if echo "$_iter_output" | grep -qi "by iteration\|BY ITERATION"; then
    assert_pass "--by-iteration flag renders iteration section"
else
    assert_fail "--by-iteration flag renders iteration section" "output: $(echo "$_iter_output" | grep -i iter | head -3)"
fi

_no_iter_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --by-iteration 2>&1) || true
if echo "$_no_iter_output" | grep -qi "no iteration data\|no.*iteration\|iteration.*data"; then
    assert_pass "--by-iteration with no artifact shows graceful message"
else
    assert_fail "--by-iteration with no artifact shows graceful message" "output: $(echo "$_no_iter_output" | tail -3)"
fi

# ── Test 4: record_iteration_cost from lib/loop-cost.sh ───────────────────────
_loop_cost_lib="$SCRIPT_DIR/lib/loop-cost.sh"
if [[ -f "$_loop_cost_lib" ]]; then
    _iter_sidecar="$TEST_TEMP_DIR/test-iter-costs.jsonl"
    (
        # Source the lib in a subshell to avoid polluting test environment
        ITER_COST_JSONL="$_iter_sidecar"
        LOOP_INPUT_TOKENS=0
        LOOP_OUTPUT_TOKENS=0
        LOOP_COST_MILLICENTS=0
        # shellcheck source=/dev/null
        source "$_loop_cost_lib"
        # Iteration 1
        _ITER_SNAP_INPUT=0; _ITER_SNAP_OUTPUT=0; _ITER_SNAP_COST_MC=0
        LOOP_INPUT_TOKENS=5000; LOOP_OUTPUT_TOKENS=2000; LOOP_COST_MILLICENTS=450
        record_iteration_cost 1
        # Iteration 2
        _ITER_SNAP_INPUT=5000; _ITER_SNAP_OUTPUT=2000; _ITER_SNAP_COST_MC=450
        LOOP_INPUT_TOKENS=9000; LOOP_OUTPUT_TOKENS=3800; LOOP_COST_MILLICENTS=840
        record_iteration_cost 2
        # Iteration 3
        _ITER_SNAP_INPUT=9000; _ITER_SNAP_OUTPUT=3800; _ITER_SNAP_COST_MC=840
        LOOP_INPUT_TOKENS=12500; LOOP_OUTPUT_TOKENS=5300; LOOP_COST_MILLICENTS=1170
        record_iteration_cost 3
    )
    _line_count=$(wc -l < "$_iter_sidecar" 2>/dev/null | tr -d ' ' || echo "0")
    _iter3_num=$(jq -r 'select(.iteration==3) | .iteration' "$_iter_sidecar" 2>/dev/null | head -1 || echo "")
    _iter1_input=$(jq -r 'select(.iteration==1) | .input_tokens' "$_iter_sidecar" 2>/dev/null | head -1 || echo "")
    if [[ "$_line_count" == "3" ]]; then
        assert_pass "record_iteration_cost: sidecar has 3 lines"
    else
        assert_fail "record_iteration_cost: sidecar has 3 lines" "got: ${_line_count}"
    fi
    if [[ "$_iter3_num" == "3" ]]; then
        assert_pass "record_iteration_cost: iteration numbers are 1/2/3"
    else
        assert_fail "record_iteration_cost: iteration numbers are 1/2/3" "got iter3: ${_iter3_num}"
    fi
    if [[ "$_iter1_input" == "5000" ]]; then
        assert_pass "record_iteration_cost: iteration 1 delta input_tokens correct (5000)"
    else
        assert_fail "record_iteration_cost: iteration 1 delta input_tokens correct (5000)" "got: ${_iter1_input}"
    fi
else
    assert_fail "record_iteration_cost: lib/loop-cost.sh exists" "file not found: $_loop_cost_lib"
    assert_fail "record_iteration_cost: sidecar has 3 lines"
    assert_fail "record_iteration_cost: iteration numbers are 1/2/3"
    assert_fail "record_iteration_cost: iteration 1 delta input_tokens correct (5000)"
fi

# ── Test 5: record_stage_cost_start/end from lib/stage-cost.sh ─────────────────
_stage_cost_lib="$SCRIPT_DIR/lib/stage-cost.sh"
if [[ -f "$_stage_cost_lib" ]]; then
    _stage_sidecar_dir="$TEST_TEMP_DIR/stage-cost-test"
    mkdir -p "$_stage_sidecar_dir"
    (
        ARTIFACTS_DIR="$_stage_sidecar_dir"
        TOTAL_INPUT_TOKENS=0
        TOTAL_OUTPUT_TOKENS=0
        MODEL="sonnet"
        ISSUE_NUMBER="87"
        # Stub cost_record as noop so the lib works without sw-cost.sh loaded
        cost_record() { return 0; }
        emit_event() { return 0; }
        # shellcheck source=/dev/null
        source "$_stage_cost_lib"
        record_stage_cost_start "plan"
        TOTAL_INPUT_TOKENS=8000
        TOTAL_OUTPUT_TOKENS=3000
        record_stage_cost_end "plan"
    )
    if [[ -f "$_stage_sidecar_dir/stage-costs.jsonl" ]]; then
        _sc_stage=$(jq -r '.stage' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        _sc_input=$(jq -r '.input_tokens' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        if [[ "$_sc_stage" == "plan" ]]; then
            assert_pass "record_stage_cost_end: stage-costs.jsonl has stage=plan"
        else
            assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan" "got: ${_sc_stage}"
        fi
        if [[ "$_sc_input" == "8000" ]]; then
            assert_pass "record_stage_cost_end: input_tokens delta correct (8000)"
        else
            assert_fail "record_stage_cost_end: input_tokens delta correct (8000)" "got: ${_sc_input}"
        fi
    else
        assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan" "file not created"
        assert_fail "record_stage_cost_end: input_tokens delta correct (8000)"
    fi
else
    assert_fail "record_stage_cost_end: lib/stage-cost.sh exists" "file not found: $_stage_cost_lib"
    assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan"
    assert_fail "record_stage_cost_end: input_tokens delta correct (8000)"
fi

# ── Test 6: AC#1 regression — 4 distinct stages in by_stage ──────────────────
_bd_ac1="$TEST_TEMP_DIR/breakdown-ac1"
mkdir -p "$_bd_ac1"
printf '%s\n' \
    "{\"stage\":\"plan\",\"input_tokens\":8000,\"output_tokens\":3000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"design\",\"input_tokens\":6000,\"output_tokens\":2500,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"review\",\"input_tokens\":3000,\"output_tokens\":1000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    > "$_bd_ac1/stage-costs.jsonl"

env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_ac1" "ac1-test" "87" 2>&1 || true

if [[ -f "$_bd_ac1/cost-breakdown.json" ]]; then
    _ac1_stages=$(jq '[.by_stage[].stage] | sort | unique | length' "$_bd_ac1/cost-breakdown.json" 2>/dev/null || echo "0")
    _ac1_all_nonzero=$(jq '[.by_stage[] | select(.input_tokens > 0)] | length' "$_bd_ac1/cost-breakdown.json" 2>/dev/null || echo "0")
    if [[ "$_ac1_stages" == "4" ]]; then
        assert_pass "AC#1 regression: by_stage has 4 distinct stage names (not just 'pipeline')"
    else
        assert_fail "AC#1 regression: by_stage has 4 distinct stage names" "got: ${_ac1_stages}"
    fi
    if [[ "$_ac1_all_nonzero" == "4" ]]; then
        assert_pass "AC#1 regression: all 4 stages have non-zero input_tokens"
    else
        assert_fail "AC#1 regression: all 4 stages have non-zero input_tokens" "got: ${_ac1_all_nonzero}"
    fi
else
    assert_fail "AC#1 regression: by_stage has 4 distinct stage names"
    assert_fail "AC#1 regression: all 4 stages have non-zero input_tokens"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
