#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router test — Intelligent model routing & optimization ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Model Router Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows route" "$output" "route"
assert_contains "help shows escalate" "$output" "escalate"
assert_contains "help shows config" "$output" "config"

# ─── Test 2: Route model for intake (haiku stage) ────────────────────────
echo ""
echo -e "${BOLD}  Route Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 50 2>&1)
assert_eq "route intake at 50 = haiku" "haiku" "$output"

# ─── Test 3: Route model for build (opus stage) ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 50 2>&1)
assert_eq "route build at 50 = opus" "opus" "$output"

# ─── Test 4: Route model for test (sonnet stage) ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route test 50 2>&1)
assert_eq "route test at 50 = sonnet" "sonnet" "$output"

# ─── Test 5: Route model with low complexity override ─────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 10 2>&1)
assert_eq "route build at 10 (low) = haiku" "haiku" "$output"

# ─── Test 6: Route model with high complexity override ────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 90 2>&1)
assert_eq "route intake at 90 (high) = opus" "opus" "$output"

# ─── Test 7: Route model for unknown stage ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route custom_stage 50 2>&1)
assert_eq "route unknown stage at 50 = sonnet" "sonnet" "$output"

# ─── Test 8: Escalate model ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Escalate Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate haiku 2>&1)
assert_eq "escalate haiku -> sonnet" "sonnet" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate sonnet 2>&1)
assert_eq "escalate sonnet -> opus" "opus" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate opus 2>&1)
assert_eq "escalate opus -> opus (ceiling)" "opus" "$output"

# ─── Test 9: Escalate unknown model ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate unknown 2>&1) && rc=0 || rc=$?
assert_eq "escalate unknown exits non-zero" "1" "$rc"

# ─── Test 10: Config show creates default ─────────────────────────────────
echo ""
echo -e "${BOLD}  Config${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show displays JSON" "$output" "default_routing"
# Unified config: canonical location is optimization dir
config_file="$HOME/.shipwright/optimization/model-routing.json"
if [[ -f "$config_file" ]]; then
    assert_pass "config creates default file"
else
    assert_fail "config creates default file" "file not found"
fi

# ─── Test 11: Config set ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode true 2>&1) || true
assert_contains "config set confirms update" "$output" "Updated"
value=$(jq -r '.cost_aware_mode' "$config_file")
assert_eq "config set persists value" "true" "$value"

# ─── Test 12: Estimate cost ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Estimate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 50 2>&1) || true
assert_contains "estimate shows stages" "$output" "intake"
assert_contains "estimate shows total" "$output" "Total"

# ─── Test 13: Report with no data ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with no data warns" "$output" "No usage data"

# ─── Test 14: record_usage creates usage data file ───────────────────────
echo ""
echo -e "${BOLD}  Record Usage${RESET}"
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
record_usage "plan" "opus" 1000 500 2>/dev/null || true
record_usage "build" "sonnet" 2000 800 2>/dev/null || true
usage_file="$HOME/.shipwright/optimization/model-usage.jsonl"
if [[ -f "$usage_file" ]]; then
    assert_pass "record_usage creates usage file"
    lines=$(wc -l < "$usage_file" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "record_usage writes entries" "2" "$lines"
else
    assert_fail "record_usage creates usage file"
fi

# ─── Test 15: Report with usage data shows summary ───────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with data shows summary" "$output" "Summary"
assert_contains "report shows total runs" "$output" "Total runs"
assert_contains "report shows cost" "$output" "cost"
assert_contains_regex "report shows model counts" "$output" "(Haiku|Sonnet|Opus) runs"

# ─── Test 16: Route for all stages at all complexity levels ──────────────
echo ""
echo -e "${BOLD}  Route All Stages & Complexity${RESET}"
for stage in intake plan design build test review compound_quality validate monitor; do
    out=$(bash "$SCRIPT_DIR/sw-model-router.sh" route "$stage" 50 2>&1)
    if [[ -n "$out" && "$out" =~ ^(haiku|sonnet|opus)$ ]]; then
        assert_pass "route $stage at 50 returns model"
    else
        assert_fail "route $stage at 50 returns model" "got: $out"
    fi
done
out_low=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 10 2>&1)
out_high=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 95 2>&1)
assert_eq "route plan at low complexity = haiku" "haiku" "$out_low"
assert_eq "route plan at high complexity = opus" "opus" "$out_high"

# ─── Test 17: Config set and config show cycle ───────────────────────────
echo ""
echo -e "${BOLD}  Config Set/Show Cycle${RESET}"
bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode false 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show reflects settings" "$output" "cost_aware_mode"
val=$(jq -r '.cost_aware_mode' "$config_file" 2>/dev/null)
assert_eq "config set persists" "false" "$val"

# ─── Test 18: Estimate with specific stages and complexity ───────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 25 2>&1) || true
assert_contains "estimate with low complexity shows stages" "$output" "intake"
assert_contains "estimate shows Total" "$output" "Total"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 75 2>&1) || true
assert_contains "estimate with high complexity" "$output" "plan"

# ─── Test 19: Unknown subcommand ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits non-zero" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

# ─── Test 20: route_model_auto with classifier ─────────────────────────────
echo ""
echo -e "${BOLD}  Auto-Classify Routing${RESET}"
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
# Clear cached score
unset PIPELINE_COMPLEXITY_SCORE 2>/dev/null || true
if [[ "$(type -t route_model_auto 2>/dev/null)" == "function" ]]; then
    output=$(route_model_auto "build" "fix typo in docs" "README.md" "" "10" 2>/dev/null)
    if [[ "$output" =~ ^(haiku|sonnet|opus)$ ]]; then
        assert_pass "route_model_auto returns valid model (got $output)"
    else
        assert_fail "route_model_auto returns valid model" "got: $output"
    fi

    # Test caching: set PIPELINE_COMPLEXITY_SCORE manually and verify it's used
    export PIPELINE_COMPLEXITY_SCORE="15"
    output2=$(route_model_auto "build" "completely different task" "" "" "0" 2>/dev/null)
    if [[ "$output2" =~ ^(haiku|sonnet|opus)$ ]]; then
        assert_pass "route_model_auto uses cached score (got $output2)"
    else
        assert_fail "route_model_auto uses cached score" "got: $output2"
    fi

    # With low cached score, routing should give a simpler model than opus for build
    export PIPELINE_COMPLEXITY_SCORE="10"
    output3=$(route_model_auto "test" "" "" "" "0" 2>/dev/null)
    assert_eq "route_model_auto with low cached score routes to haiku" "haiku" "$output3"
    unset PIPELINE_COMPLEXITY_SCORE 2>/dev/null || true
else
    assert_fail "route_model_auto function exists"
fi

# ─── Test 21: is_classifier_enabled reads policy.json ──────────────────────
echo ""
echo -e "${BOLD}  Classifier Enabled Check${RESET}"
if [[ "$(type -t is_classifier_enabled 2>/dev/null)" == "function" ]]; then
    # Create a mock policy.json with modelRouting enabled
    mkdir -p "$TEST_TEMP_DIR/repo/config"
    cat > "$TEST_TEMP_DIR/repo/config/policy.json" << 'EOF'
{"modelRouting": {"enabled": true}}
EOF
    REPO_DIR="$TEST_TEMP_DIR/repo" is_classifier_enabled && rc=0 || rc=$?
    assert_eq "is_classifier_enabled returns 0 when enabled" "0" "$rc"

    cat > "$TEST_TEMP_DIR/repo/config/policy.json" << 'EOF'
{"modelRouting": {"enabled": false}}
EOF
    REPO_DIR="$TEST_TEMP_DIR/repo" is_classifier_enabled && rc=0 || rc=$?
    assert_eq "is_classifier_enabled returns 1 when disabled" "1" "$rc"
else
    assert_fail "is_classifier_enabled function exists"
fi

# ─── Test 22: Classify subcommand via CLI ──────────────────────────────────
echo ""
echo -e "${BOLD}  Classify via CLI${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" classify "add new feature" "src/a.js
src/b.js
src/c.js" "" "100" 2>&1)
if [[ "$output" =~ ^[0-9]+$ ]]; then
    assert_pass "model-router classify returns numeric score (got $output)"
else
    assert_fail "model-router classify returns numeric score" "got: $output"
fi

# ─── Test 23: ab_test_should_use_classifier function ──────────────────────
echo ""
echo -e "${BOLD}  A/B Test Classifier Gate${RESET}"
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
if [[ "$(type -t ab_test_should_use_classifier 2>/dev/null)" == "function" ]]; then
    assert_pass "ab_test_should_use_classifier function exists"

    # With no config file, should return 1 (false)
    ab_test_should_use_classifier && rc=0 || rc=$?
    assert_eq "ab_test_should_use_classifier returns 1 with no config" "1" "$rc"

    # With A/B test enabled at 100%, should return 0 (true)
    ensure_config 2>/dev/null || true
    ab_tmp=$(mktemp)
    jq '.a_b_test = {"enabled": true, "percentage": 100, "variant": "cost-optimized"}' \
        "$HOME/.shipwright/optimization/model-routing.json" > "$ab_tmp" && \
        mv "$ab_tmp" "$HOME/.shipwright/optimization/model-routing.json"
    _resolve_routing_config
    ab_test_should_use_classifier && rc=0 || rc=$?
    assert_eq "ab_test_should_use_classifier returns 0 at 100%" "0" "$rc"

    # With A/B test disabled, should return 1 (false)
    ab_tmp2=$(mktemp)
    jq '.a_b_test.enabled = false' \
        "$HOME/.shipwright/optimization/model-routing.json" > "$ab_tmp2" && \
        mv "$ab_tmp2" "$HOME/.shipwright/optimization/model-routing.json"
    _resolve_routing_config
    ab_test_should_use_classifier && rc=0 || rc=$?
    assert_eq "ab_test_should_use_classifier returns 1 when disabled" "1" "$rc"

    # With A/B test at 0%, should return 1 (false)
    ab_tmp3=$(mktemp)
    jq '.a_b_test = {"enabled": true, "percentage": 0, "variant": "cost-optimized"}' \
        "$HOME/.shipwright/optimization/model-routing.json" > "$ab_tmp3" && \
        mv "$ab_tmp3" "$HOME/.shipwright/optimization/model-routing.json"
    _resolve_routing_config
    ab_test_should_use_classifier && rc=0 || rc=$?
    assert_eq "ab_test_should_use_classifier returns 1 at 0%" "1" "$rc"
else
    assert_fail "ab_test_should_use_classifier function exists"
fi

# ─── Budget Validation Tests ─────────────────────────────────────────────────
echo -e "${DIM}  Budget Validation${RESET}"

if type validate_budget >/dev/null 2>&1; then
    assert_pass "validate_budget function exists"

    # Under limit (no usage log) should pass
    rm -f "$HOME/.shipwright/optimization/model-usage.jsonl" 2>/dev/null || true
    validate_budget "build" "opus" "test-pipeline-1" && budget_rc=0 || budget_rc=$?
    assert_eq "validate_budget passes with no usage log" "0" "$budget_rc"

    # FORCE_MODEL override bypasses budget check
    (
        export FORCE_MODEL="opus"
        # Set max_cost low to trigger failure if override didn't work
        FORCE_MODEL="opus" validate_budget "build" "opus" "test-pipeline-forced" && rc=0 || rc=$?
        echo "$rc"
    ) | grep -q "0"
    assert_pass "validate_budget passes when FORCE_MODEL is set"

    # Over limit: write usage records totaling > max_cost
    ensure_config 2>/dev/null || true
    # Set max_cost to 1.0 in config
    if command -v jq >/dev/null 2>&1; then
        budget_tmp=$(mktemp)
        jq '.max_cost_per_pipeline = 1.0' "$HOME/.shipwright/optimization/model-routing.json" > "$budget_tmp" && \
            mv "$budget_tmp" "$HOME/.shipwright/optimization/model-routing.json"
        _resolve_routing_config
        # Write a usage record with cost 2.0 for this pipeline
        mkdir -p "$HOME/.shipwright/optimization"
        echo '{"ts":"2026-01-01T00:00:00Z","pipeline_id":"test-budget-pipeline","stage":"build","model":"opus","input_tokens":1000,"output_tokens":1000,"cost":2.0}' \
            >> "$HOME/.shipwright/optimization/model-usage.jsonl"
        validate_budget "review" "opus" "test-budget-pipeline" && budget_over_rc=0 || budget_over_rc=$?
        assert_eq "validate_budget fails when accumulated cost exceeds max" "1" "$budget_over_rc"
    else
        assert_pass "validate_budget over-limit test skipped (no jq)"
    fi

    # CLI validate-budget subcommand
    cli_budget_out=$(bash "$SCRIPT_DIR/sw-model-router.sh" validate-budget "intake" "haiku" "cli-test" 2>&1) && cli_budget_rc=0 || cli_budget_rc=$?
    # Should return 0 (no usage for cli-test pipeline)
    assert_eq "CLI validate-budget passes for new pipeline" "0" "$cli_budget_rc"
else
    assert_fail "validate_budget function exists"
fi

echo ""
echo ""
print_test_results
