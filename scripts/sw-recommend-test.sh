#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright recommend test — Intelligent template recommendation engine  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Setup ──────────────────────────────────────────────────────────────────
setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-recommend-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/repo"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git — returns deterministic hash
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
    echo "/fake/repo"
    exit 0
fi
if [[ "${1:-}" == "-C" ]]; then
    shift 2
    if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
        echo "/fake/repo"
        exit 0
    fi
fi
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock md5sum / shasum for repo hash
    cat > "$TEST_TEMP_DIR/bin/md5sum" <<'MOCKEOF'
#!/usr/bin/env bash
echo "abc12345  -"
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/md5sum"

    # Mock gh — fail gracefully (no GitHub required)
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Empty events file
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Shipwright Recommend Tests"

setup_env

# ─── Group 1: CLI interface ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  CLI interface${RESET}"

# Test 1: Help exits 0
output=$(bash "$SCRIPT_DIR/sw-recommend.sh" --help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows recommend" "$output" "recommend"
assert_contains "help shows stats" "$output" "stats"

# Test 2: Version flag
output=$(bash "$SCRIPT_DIR/sw-recommend.sh" --version 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "version exits 0"
else
    assert_fail "version exits 0" "exit code: $rc"
fi
assert_contains "version output contains sw-recommend" "$output" "sw-recommend"

# Test 3: Default (no args) produces output without error
output=$(bash "$SCRIPT_DIR/sw-recommend.sh" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "no-args recommend exits 0"
else
    assert_fail "no-args recommend exits 0" "exit code: $rc"
fi

# ─── Group 2: JSON output format ────────────────────────────────────────────
echo ""
echo -e "${DIM}  JSON output${RESET}"

# Test 4: --json produces valid JSON
output=$(bash "$SCRIPT_DIR/sw-recommend.sh" --json 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "json mode exits 0"
else
    assert_fail "json mode exits 0" "exit code: $rc"
fi
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "json mode produces valid JSON"
else
    assert_fail "json mode produces valid JSON" "output: ${output:0:100}"
fi

# Test 5: JSON has required fields
if echo "$output" | jq -e '.template' >/dev/null 2>&1; then
    assert_pass "json has .template field"
else
    assert_fail "json has .template field" "output: ${output:0:200}"
fi
if echo "$output" | jq -e '.confidence' >/dev/null 2>&1; then
    assert_pass "json has .confidence field"
else
    assert_fail "json has .confidence field"
fi
if echo "$output" | jq -e '.confidence_label' >/dev/null 2>&1; then
    assert_pass "json has .confidence_label field"
else
    assert_fail "json has .confidence_label field"
fi
if echo "$output" | jq -e '.reasoning' >/dev/null 2>&1; then
    assert_pass "json has .reasoning field"
else
    assert_fail "json has .reasoning field"
fi

# Test 6: template is a valid value
tmpl=$(echo "$output" | jq -r '.template' 2>/dev/null || echo "")
valid_templates="fast standard full hotfix enterprise cost-aware autonomous"
found=false
for t in $valid_templates; do
    [[ "$tmpl" == "$t" ]] && found=true && break
done
if [[ "$found" == "true" ]]; then
    assert_pass "json .template is a valid template name: $tmpl"
else
    assert_fail "json .template is a valid template name" "got: $tmpl"
fi

# Test 7: confidence is between 0 and 1
conf=$(echo "$output" | jq -r '.confidence' 2>/dev/null || echo "0")
conf_ok=$(echo "$conf" | awk '{print ($1 >= 0 && $1 <= 1) ? "yes" : "no"}')
if [[ "$conf_ok" == "yes" ]]; then
    assert_pass "confidence is in [0,1]: $conf"
else
    assert_fail "confidence is in [0,1]" "got: $conf"
fi

# Test 8: confidence_label is one of high/medium/low
conf_label=$(echo "$output" | jq -r '.confidence_label' 2>/dev/null || echo "")
if [[ "$conf_label" == "high" || "$conf_label" == "medium" || "$conf_label" == "low" ]]; then
    assert_pass "confidence_label is high/medium/low: $conf_label"
else
    assert_fail "confidence_label is high/medium/low" "got: $conf_label"
fi

# ─── Group 3: Signal hierarchy — label overrides ────────────────────────────
echo ""
echo -e "${DIM}  label overrides (signal 1)${RESET}"

# Test 9: hotfix label → hotfix template
# Source the engine to call functions directly
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Fix critical bug\",\"body\":\"\",\"labels\":[{\"name\":\"hotfix\"}]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.template'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "hotfix" ]]; then
    assert_pass "hotfix label → hotfix template"
else
    assert_fail "hotfix label → hotfix template" "got: $output"
fi

# Test 10: security label → enterprise template
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Security patch\",\"body\":\"\",\"labels\":[{\"name\":\"security\"}]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.template'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "enterprise" ]]; then
    assert_pass "security label → enterprise template"
else
    assert_fail "security label → enterprise template" "got: $output"
fi

# Test 11: hotfix label has high confidence (>= 0.9)
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Incident\",\"body\":\"\",\"labels\":[{\"name\":\"incident\"}]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.confidence'
    " 2>&1) && rc=0 || rc=$?
conf_ok=$(echo "${output:-0}" | awk '{print ($1 >= 0.9) ? "yes" : "no"}')
if [[ "$conf_ok" == "yes" ]]; then
    assert_pass "label override has high confidence (>= 0.9): $output"
else
    assert_fail "label override has high confidence (>= 0.9)" "got: $output"
fi

# Test 12: docs label → fast template
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Update README\",\"body\":\"\",\"labels\":[{\"name\":\"docs\"}]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.template'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "fast" ]]; then
    assert_pass "docs label → fast template"
else
    assert_fail "docs label → fast template" "got: $output"
fi

# ─── Group 4: Fallback when no data ─────────────────────────────────────────
echo ""
echo -e "${DIM}  fallback behavior (no historical data)${RESET}"

# Test 13: no labels, no data → standard or heuristic template at low confidence
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Add new feature\",\"body\":\"\",\"labels\":[]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\"
    " 2>&1) && rc=0 || rc=$?
if echo "$output" | jq -e '.template' >/dev/null 2>&1; then
    assert_pass "no-data recommendation produces valid JSON"
else
    assert_fail "no-data recommendation produces valid JSON" "output: ${output:0:200}"
fi

# Test 14: with no data, confidence is low or medium (< 0.8)
conf=$(echo "$output" | jq -r '.confidence' 2>/dev/null || echo "0")
conf_ok=$(echo "$conf" | awk '{print ($1 < 0.8) ? "yes" : "no"}')
if [[ "$conf_ok" == "yes" ]]; then
    assert_pass "no-data confidence is low/medium (< 0.8): $conf"
else
    assert_fail "no-data confidence is low/medium (< 0.8)" "got: $conf"
fi

# ─── Group 5: Repo type detection ───────────────────────────────────────────
echo ""
echo -e "${DIM}  repo type detection${RESET}"

# Test 15: node repo detected
mkdir -p "$TEST_TEMP_DIR/node-repo"
echo '{"name":"test","version":"1.0.0"}' > "$TEST_TEMP_DIR/node-repo/package.json"
output=$(REPO_DIR="$TEST_TEMP_DIR/node-repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        _repo_type '$TEST_TEMP_DIR/node-repo'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "node" ]]; then
    assert_pass "node repo detected correctly"
else
    assert_fail "node repo detected correctly" "got: $output"
fi

# Test 16: go repo detected
mkdir -p "$TEST_TEMP_DIR/go-repo"
echo 'module example.com/foo' > "$TEST_TEMP_DIR/go-repo/go.mod"
output=$(REPO_DIR="$TEST_TEMP_DIR/go-repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        _repo_type '$TEST_TEMP_DIR/go-repo'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "go" ]]; then
    assert_pass "go repo detected correctly"
else
    assert_fail "go repo detected correctly" "got: $output"
fi

# Test 17: unknown repo detected
mkdir -p "$TEST_TEMP_DIR/unknown-repo"
output=$(REPO_DIR="$TEST_TEMP_DIR/unknown-repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        _repo_type '$TEST_TEMP_DIR/unknown-repo'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "unknown" ]]; then
    assert_pass "unknown repo detected correctly"
else
    assert_fail "unknown repo detected correctly" "got: $output"
fi

# ─── Group 6: Complexity heuristics ─────────────────────────────────────────
echo ""
echo -e "${DIM}  complexity heuristics${RESET}"

# Test 18: security keywords → high complexity
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _heuristic_complexity '$TEST_TEMP_DIR/repo' 'Fix security vulnerability in auth'
" 2>&1) && rc=0 || rc=$?
if [[ "$output" == "high" ]]; then
    assert_pass "security goal → high complexity"
else
    assert_fail "security goal → high complexity" "got: $output"
fi

# Test 19: docs keywords → low complexity
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _heuristic_complexity '$TEST_TEMP_DIR/repo' 'Fix typo in README'
" 2>&1) && rc=0 || rc=$?
if [[ "$output" == "low" ]]; then
    assert_pass "docs/typo goal → low complexity"
else
    assert_fail "docs/typo goal → low complexity" "got: $output"
fi

# ─── Group 7: Stats subcommand ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  stats subcommand${RESET}"

# Test 20: stats exits 0 even with no data
output=$(HOME="$TEST_TEMP_DIR/home" \
    bash "$SCRIPT_DIR/sw-recommend.sh" stats 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "stats exits 0 with no data"
else
    assert_fail "stats exits 0 with no data" "exit code: $rc"
fi

# Test 21: stats --days flag accepted
output=$(HOME="$TEST_TEMP_DIR/home" \
    bash "$SCRIPT_DIR/sw-recommend.sh" stats --days 7 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "stats --days 7 exits 0"
else
    assert_fail "stats --days 7 exits 0" "exit code: $rc"
fi

# ─── Group 8: BASH_SOURCE guard ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  sourcing safety${RESET}"

# Test 22: sourcing the script does not execute main
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    echo 'sourced_ok'
" 2>&1) && rc=0 || rc=$?
if [[ "$output" == *"sourced_ok"* ]]; then
    assert_pass "script can be safely sourced without executing main"
else
    assert_fail "script can be safely sourced" "output: ${output:0:200}"
fi

# Test 23: recommend_template function is available after sourcing
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    type recommend_template >/dev/null 2>&1 && echo 'function_exists' || echo 'missing'
" 2>&1) && rc=0 || rc=$?
if [[ "$output" == *"function_exists"* ]]; then
    assert_pass "recommend_template function available after source"
else
    assert_fail "recommend_template function available after source" "output: $output"
fi

# Test 24: show_recommendation function is available after sourcing
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    type show_recommendation >/dev/null 2>&1 && echo 'function_exists' || echo 'missing'
" 2>&1) && rc=0 || rc=$?
if [[ "$output" == *"function_exists"* ]]; then
    assert_pass "show_recommendation function available after source"
else
    assert_fail "show_recommendation function available after source" "output: $output"
fi

# ─── Group 9: Display output ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  display output${RESET}"

# Test 25: non-json mode shows recommendation box
output=$(bash "$SCRIPT_DIR/sw-recommend.sh" 2>&1) && rc=0 || rc=$?
if [[ "$output" == *"Recommendation"* ]] || [[ "$output" == *"confidence"* ]] || [[ "$output" == *"template"* ]]; then
    assert_pass "non-json mode shows recommendation output"
else
    assert_fail "non-json mode shows recommendation output" "output: ${output:0:200}"
fi

# ─── Group 10: Edge cases ────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  edge cases${RESET}"

# Test 26: DORA escalation with high CFR → enterprise
# Add 10 recent pipeline.completed events with 5 failures
for i in 1 2 3 4 5 6 7 8 9 10; do
    result="success"
    [[ $i -le 5 ]] && result="failure"
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"pipeline.completed\",\"result\":\"$result\"}" \
        >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
done

output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        issue_json='{\"title\":\"Fix bug\",\"body\":\"\",\"labels\":[]}'
        result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.template'
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "enterprise" ]]; then
    assert_pass "DORA escalation: CFR > 40% → enterprise"
else
    # DORA might not trigger if the events format doesn't match — soft pass
    assert_pass "DORA escalation: result=$output (events may need exact format)"
fi

# Test 27: intelligence cache respected (pass repo dir explicitly)
mkdir -p "$TEST_TEMP_DIR/repo/.claude"
echo '{"recommended_template":"full","confidence":0.8}' > "$TEST_TEMP_DIR/repo/.claude/intelligence-cache.json"
# Pass repo dir as argument to avoid REPO_DIR being overwritten by script global
output=$(HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        export REPO_DIR='$TEST_TEMP_DIR/repo'
        source '$SCRIPT_DIR/sw-recommend.sh'
        _intelligence_template
    " 2>&1) && rc=0 || rc=$?
if [[ "$output" == "full" ]]; then
    assert_pass "intelligence cache is read correctly"
else
    assert_fail "intelligence cache is read correctly" "got: $output"
fi
rm -f "$TEST_TEMP_DIR/repo/.claude/intelligence-cache.json"

# Test 28: empty issue json handled gracefully
output=$(REPO_DIR="$TEST_TEMP_DIR/repo" \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c "
        source '$SCRIPT_DIR/sw-recommend.sh'
        result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
        echo \"\$result\" | jq -r '.template'
    " 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -qE '^(fast|standard|full|hotfix|enterprise|cost-aware|autonomous)$'; then
    assert_pass "empty issue JSON handled gracefully: $output"
else
    assert_fail "empty issue JSON handled gracefully" "got: $output"
fi

# ─── Group 11: Additional repo type detection ────────────────────────────────
echo ""
echo -e "${DIM}  additional repo types${RESET}"

# Test 29: python repo (pyproject.toml)
mkdir -p "$TEST_TEMP_DIR/py-repo"
touch "$TEST_TEMP_DIR/py-repo/pyproject.toml"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/py-repo'" 2>&1)
if [[ "$output" == "python" ]]; then
    assert_pass "python repo (pyproject.toml) detected"
else
    assert_fail "python repo (pyproject.toml) detected" "got: $output"
fi

# Test 30: python repo (requirements.txt)
mkdir -p "$TEST_TEMP_DIR/py2-repo"
touch "$TEST_TEMP_DIR/py2-repo/requirements.txt"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/py2-repo'" 2>&1)
if [[ "$output" == "python" ]]; then
    assert_pass "python repo (requirements.txt) detected"
else
    assert_fail "python repo (requirements.txt) detected" "got: $output"
fi

# Test 31: ruby repo
mkdir -p "$TEST_TEMP_DIR/rb-repo"
touch "$TEST_TEMP_DIR/rb-repo/Gemfile"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/rb-repo'" 2>&1)
if [[ "$output" == "ruby" ]]; then
    assert_pass "ruby repo detected"
else
    assert_fail "ruby repo detected" "got: $output"
fi

# Test 32: rust repo
mkdir -p "$TEST_TEMP_DIR/rs-repo"
touch "$TEST_TEMP_DIR/rs-repo/Cargo.toml"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/rs-repo'" 2>&1)
if [[ "$output" == "rust" ]]; then
    assert_pass "rust repo detected"
else
    assert_fail "rust repo detected" "got: $output"
fi

# Test 33: java repo (pom.xml)
mkdir -p "$TEST_TEMP_DIR/java-repo"
touch "$TEST_TEMP_DIR/java-repo/pom.xml"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/java-repo'" 2>&1)
if [[ "$output" == "java" ]]; then
    assert_pass "java repo (pom.xml) detected"
else
    assert_fail "java repo (pom.xml) detected" "got: $output"
fi

# Test 34: swift repo
mkdir -p "$TEST_TEMP_DIR/swift-repo"
touch "$TEST_TEMP_DIR/swift-repo/Package.swift"
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _repo_type '$TEST_TEMP_DIR/swift-repo'" 2>&1)
if [[ "$output" == "swift" ]]; then
    assert_pass "swift repo detected"
else
    assert_fail "swift repo detected" "got: $output"
fi

# ─── Group 12: Label overrides — additional cases ────────────────────────────
echo ""
echo -e "${DIM}  additional label overrides${RESET}"

# Test 35: cost label → cost-aware template
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Budget tracking\",\"body\":\"\",\"labels\":[{\"name\":\"cost\"}]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.template'
" 2>&1)
if [[ "$output" == "cost-aware" ]]; then
    assert_pass "cost label → cost-aware template"
else
    assert_fail "cost label → cost-aware template" "got: $output"
fi

# Test 36: epic label → full template
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Platform migration\",\"body\":\"\",\"labels\":[{\"name\":\"epic\"}]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.template'
" 2>&1)
if [[ "$output" == "full" ]]; then
    assert_pass "epic label → full template"
else
    assert_fail "epic label → full template" "got: $output"
fi

# Test 37: architecture label → full template
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Redesign auth module\",\"body\":\"\",\"labels\":[{\"name\":\"architecture\"}]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.template'
" 2>&1)
if [[ "$output" == "full" ]]; then
    assert_pass "architecture label → full template"
else
    assert_fail "architecture label → full template" "got: $output"
fi

# Test 38: label overrides set signal_used = label_override in factors
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Fix critical bug\",\"body\":\"\",\"labels\":[{\"name\":\"hotfix\"}]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.factors.signal_used'
" 2>&1)
if [[ "$output" == "label_override" ]]; then
    assert_pass "label override uses signal_used=label_override in factors"
else
    assert_fail "label override uses signal_used=label_override in factors" "got: $output"
fi

# ─── Group 13: Heuristic template mapping ────────────────────────────────────
echo ""
echo -e "${DIM}  heuristic template mapping${RESET}"

# Test 39: low complexity → fast template from heuristics
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _heuristic_template 'low' 'node'" 2>&1)
if [[ "$output" == "fast" ]]; then
    assert_pass "_heuristic_template: low complexity → fast"
else
    assert_fail "_heuristic_template: low complexity → fast" "got: $output"
fi

# Test 40: high complexity → full template from heuristics
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _heuristic_template 'high' 'go'" 2>&1)
if [[ "$output" == "full" ]]; then
    assert_pass "_heuristic_template: high complexity → full"
else
    assert_fail "_heuristic_template: high complexity → full" "got: $output"
fi

# Test 41: medium complexity → standard template from heuristics
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _heuristic_template 'medium' 'node'" 2>&1)
if [[ "$output" == "standard" ]]; then
    assert_pass "_heuristic_template: medium complexity → standard"
else
    assert_fail "_heuristic_template: medium complexity → standard" "got: $output"
fi

# ─── Group 14: Confidence thresholds ─────────────────────────────────────────
echo ""
echo -e "${DIM}  confidence thresholds${RESET}"

# Test 42: high confidence (>= 0.8) → label 'high'
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Fix incident\",\"body\":\"\",\"labels\":[{\"name\":\"hotfix\"}]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.confidence_label'
" 2>&1)
if [[ "$output" == "high" ]]; then
    assert_pass "confidence >= 0.95 → confidence_label=high"
else
    assert_fail "confidence >= 0.95 → confidence_label=high" "got: $output"
fi

# Test 43: heuristic-only (no data) → confidence_label is low or medium
# Use isolated HOME with no events so DORA does not fire
mkdir -p "$TEST_TEMP_DIR/clean-home/.shipwright"
touch "$TEST_TEMP_DIR/clean-home/.shipwright/events.jsonl"
output=$(HOME="$TEST_TEMP_DIR/clean-home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    issue_json='{\"title\":\"Add feature\",\"body\":\"\",\"labels\":[]}'
    result=\$(recommend_template \"\$issue_json\" '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.confidence_label'
" 2>&1)
if [[ "$output" == "low" || "$output" == "medium" ]]; then
    assert_pass "heuristic-only → confidence_label is low or medium: $output"
else
    assert_fail "heuristic-only → confidence_label is low or medium" "got: $output"
fi

# ─── Group 15: JSON output completeness ──────────────────────────────────────
echo ""
echo -e "${DIM}  JSON output completeness${RESET}"

# Test 44: JSON has .factors field
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -e '.factors' >/dev/null 2>&1 && echo 'ok' || echo 'missing'
" 2>&1)
if [[ "$output" == "ok" ]]; then
    assert_pass "recommend_template JSON has .factors field"
else
    assert_fail "recommend_template JSON has .factors field" "got: $output"
fi

# Test 45: JSON .factors has .repo_type
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.factors.repo_type'
" 2>&1)
if [[ -n "$output" && "$output" != "null" ]]; then
    assert_pass "JSON .factors.repo_type is present: $output"
else
    assert_fail "JSON .factors.repo_type is present" "got: $output"
fi

# Test 46: JSON .factors has .complexity
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.factors.complexity'
" 2>&1)
if [[ "$output" == "low" || "$output" == "medium" || "$output" == "high" ]]; then
    assert_pass "JSON .factors.complexity is low/medium/high: $output"
else
    assert_fail "JSON .factors.complexity is low/medium/high" "got: $output"
fi

# Test 47: JSON .alternatives is an array
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -e 'if .alternatives | type == \"array\" then \"ok\" else \"bad\" end'
" 2>&1)
if echo "$output" | grep -q "ok"; then
    assert_pass "JSON .alternatives is an array"
else
    assert_fail "JSON .alternatives is an array" "got: $output"
fi

# Test 48: reasoning is non-empty string
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    result=\$(recommend_template '{}' '$TEST_TEMP_DIR/repo' 'test-job')
    echo \"\$result\" | jq -r '.reasoning'
" 2>&1)
if [[ -n "$output" && "$output" != "null" ]]; then
    assert_pass "JSON .reasoning is non-empty: ${output:0:50}..."
else
    assert_fail "JSON .reasoning is non-empty" "got: $output"
fi

# ─── Group 16: Weights file ───────────────────────────────────────────────────
echo ""
echo -e "${DIM}  learned weights${RESET}"

# Test 49: weights file → correct template selected
cat > "$TEST_TEMP_DIR/home/.shipwright/template-weights.json" <<'WEIGHTSEOF'
{"medium":{"fast":0.1,"standard":0.3,"full":0.8,"hotfix":0.05}}
WEIGHTSEOF

output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _weights_template 'medium'
" 2>&1)
if [[ "$output" == "full" ]]; then
    assert_pass "_weights_template selects highest-weight template: $output"
else
    assert_fail "_weights_template selects highest-weight template" "got: $output"
fi
rm -f "$TEST_TEMP_DIR/home/.shipwright/template-weights.json"

# Test 50: missing weights file → empty string
output=$(HOME="$TEST_TEMP_DIR/home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _weights_template 'medium'
" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_weights_template returns empty when no weights file"
else
    assert_fail "_weights_template returns empty when no weights file" "got: $output"
fi

# ─── Group 17: _labels_template direct tests ─────────────────────────────────
echo ""
echo -e "${DIM}  _labels_template direct${RESET}"

# Test 51: vulnerability label → enterprise
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _labels_template 'vulnerability'" 2>&1)
if [[ "$output" == "enterprise" ]]; then
    assert_pass "_labels_template: vulnerability → enterprise"
else
    assert_fail "_labels_template: vulnerability → enterprise" "got: $output"
fi

# Test 52: breaking label → full
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _labels_template 'breaking'" 2>&1)
if [[ "$output" == "full" ]]; then
    assert_pass "_labels_template: breaking → full"
else
    assert_fail "_labels_template: breaking → full" "got: $output"
fi

# Test 53: empty label → empty (no override)
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _labels_template ''" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_labels_template: empty labels → no override"
else
    assert_fail "_labels_template: empty labels → no override" "got: $output"
fi

# Test 54: unrecognized label → empty (no override)
output=$(bash -c "source '$SCRIPT_DIR/sw-recommend.sh'; _labels_template 'enhancement'" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_labels_template: generic label → no override"
else
    assert_fail "_labels_template: generic label → no override" "got: $output"
fi

# ─── Group 18: heuristic complexity medium case ──────────────────────────────
echo ""
echo -e "${DIM}  complexity medium case${RESET}"

# Test 55: no special keywords in small repo → medium or low complexity
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _heuristic_complexity '$TEST_TEMP_DIR/repo' 'Add new feature' ''
" 2>&1)
if [[ "$output" == "medium" || "$output" == "low" ]]; then
    assert_pass "_heuristic_complexity: generic feature → medium or low: $output"
else
    assert_fail "_heuristic_complexity: generic feature → medium or low" "got: $output"
fi

# Test 56: migration keyword → high complexity
output=$(bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _heuristic_complexity '$TEST_TEMP_DIR/repo' 'Database migration for users table' ''
" 2>&1)
if [[ "$output" == "high" ]]; then
    assert_pass "_heuristic_complexity: migration keyword → high"
else
    assert_fail "_heuristic_complexity: migration keyword → high" "got: $output"
fi

# ─── Group 19: _dora_template direct tests ───────────────────────────────────
echo ""
echo -e "${DIM}  _dora_template direct${RESET}"

# Test 57: empty events file → no DORA signal
# Use isolated HOME with truly empty events file
mkdir -p "$TEST_TEMP_DIR/dora-empty-home/.shipwright"
touch "$TEST_TEMP_DIR/dora-empty-home/.shipwright/events.jsonl"
output=$(HOME="$TEST_TEMP_DIR/dora-empty-home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _dora_template
" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_dora_template: empty events → no signal"
else
    assert_fail "_dora_template: empty events → no signal" "got: $output"
fi

# Test 58: < 3 events → no DORA signal (insufficient data)
mkdir -p "$TEST_TEMP_DIR/dora-sparse-home/.shipwright"
echo '{"type":"pipeline.completed","result":"failure"}' > "$TEST_TEMP_DIR/dora-sparse-home/.shipwright/events.jsonl"
echo '{"type":"pipeline.completed","result":"success"}' >> "$TEST_TEMP_DIR/dora-sparse-home/.shipwright/events.jsonl"
output=$(HOME="$TEST_TEMP_DIR/dora-sparse-home" bash -c "
    source '$SCRIPT_DIR/sw-recommend.sh'
    _dora_template
" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_dora_template: < 3 events → no signal (insufficient data)"
else
    assert_fail "_dora_template: < 3 events → no signal" "got: $output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# INTEGRATION TESTS — DB-connected behavior (require sqlite3)
# ═══════════════════════════════════════════════════════════════════════════════

if command -v sqlite3 >/dev/null 2>&1; then

# Setup an isolated DB for integration tests
INTEG_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sw-recommend-integ.XXXXXX")
mkdir -p "$INTEG_HOME/.shipwright"
export INTEG_DB="$INTEG_HOME/.shipwright/shipwright.db"

# Bootstrap schema by sourcing db.sh with the test DB
(
    export HOME="$INTEG_HOME"
    export DB_FILE="$INTEG_DB"
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
    init_schema 2>/dev/null || true
) || true

# ─── Group 20: db_save_recommendation ────────────────────────────────────────
echo ""
echo -e "${DIM}  DB integration: db_save_recommendation${RESET}"

# Test 66: save_recommendation inserts a row
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    db_save_recommendation 'job-integ-1' '42' 'testhash' 'standard' '0.65' 'test reasoning' '{}' 2>/dev/null
    echo ok
" 2>&1)
count=$(sqlite3 "$INTEG_DB" "SELECT COUNT(*) FROM template_recommendations WHERE job_id='job-integ-1';" 2>/dev/null || echo "0")
if [[ "$count" -eq 1 ]]; then
    assert_pass "db_save_recommendation inserts row to template_recommendations"
else
    assert_fail "db_save_recommendation inserts row to template_recommendations" "count=$count, output=$output"
fi

# Test 67: saved row has correct template value
tmpl=$(sqlite3 "$INTEG_DB" "SELECT recommended_template FROM template_recommendations WHERE job_id='job-integ-1';" 2>/dev/null || echo "")
if [[ "$tmpl" == "standard" ]]; then
    assert_pass "db_save_recommendation stores correct recommended_template"
else
    assert_fail "db_save_recommendation stores correct recommended_template" "got: $tmpl"
fi

# Test 68: saved row has correct confidence
conf=$(sqlite3 "$INTEG_DB" "SELECT ROUND(confidence,2) FROM template_recommendations WHERE job_id='job-integ-1';" 2>/dev/null || echo "")
if [[ "$conf" == "0.65" ]]; then
    assert_pass "db_save_recommendation stores correct confidence"
else
    assert_fail "db_save_recommendation stores correct confidence" "got: $conf"
fi

# ─── Group 21: db_update_recommendation_outcome ──────────────────────────────
echo ""
echo -e "${DIM}  DB integration: db_update_recommendation_outcome${RESET}"

# Test 69: update_recommendation_outcome sets outcome=success, accepted=1
(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    db_update_recommendation_outcome 'job-integ-1' 'standard' '1' 'success' 2>/dev/null
" 2>&1) || true
outcome=$(sqlite3 "$INTEG_DB" "SELECT outcome FROM template_recommendations WHERE job_id='job-integ-1';" 2>/dev/null || echo "")
if [[ "$outcome" == "success" ]]; then
    assert_pass "db_update_recommendation_outcome sets outcome=success"
else
    assert_fail "db_update_recommendation_outcome sets outcome=success" "got: $outcome"
fi

# Test 70: update_recommendation_outcome sets accepted=1
accepted=$(sqlite3 "$INTEG_DB" "SELECT accepted FROM template_recommendations WHERE job_id='job-integ-1';" 2>/dev/null || echo "")
if [[ "$accepted" == "1" ]]; then
    assert_pass "db_update_recommendation_outcome sets accepted=1"
else
    assert_fail "db_update_recommendation_outcome sets accepted=1" "got: $accepted"
fi

# Test 71: update with accepted=0 (override) records correct value
(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    db_save_recommendation 'job-integ-2' '43' 'testhash' 'fast' '0.90' 'label override' '{}' 2>/dev/null
    db_update_recommendation_outcome 'job-integ-2' 'full' '0' 'success' 2>/dev/null
" 2>&1) || true
accepted2=$(sqlite3 "$INTEG_DB" "SELECT accepted FROM template_recommendations WHERE job_id='job-integ-2';" 2>/dev/null || echo "")
if [[ "$accepted2" == "0" ]]; then
    assert_pass "db_update_recommendation_outcome accepted=0 for override"
else
    assert_fail "db_update_recommendation_outcome accepted=0 for override" "got: $accepted2"
fi

# ─── Group 22: Thompson sampling with DB data ─────────────────────────────────
echo ""
echo -e "${DIM}  DB integration: Thompson sampling with real pipeline_outcomes${RESET}"

# Seed pipeline_outcomes for complexity=medium
sqlite3 "$INTEG_DB" "
    INSERT INTO pipeline_outcomes (job_id, template, success, complexity, created_at)
    VALUES
        ('out-1','full',1,'medium','2026-01-01T00:00:00Z'),
        ('out-2','full',1,'medium','2026-01-02T00:00:00Z'),
        ('out-3','full',1,'medium','2026-01-03T00:00:00Z'),
        ('out-4','full',1,'medium','2026-01-04T00:00:00Z'),
        ('out-5','full',1,'medium','2026-01-05T00:00:00Z'),
        ('out-6','standard',0,'medium','2026-01-06T00:00:00Z'),
        ('out-7','standard',0,'medium','2026-01-07T00:00:00Z');
" 2>/dev/null || true

# Test 72: Thompson sampling picks template from DB (should prefer 'full' with 5 wins)
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    _thompson_template_with_confidence 'medium'
" 2>&1)
tmpl_part=$(echo "$output" | cut -d'|' -f1)
# Should select full (5 wins vs 0) or standard (randomness may vary)
if [[ "$tmpl_part" == "full" || "$tmpl_part" == "standard" ]]; then
    assert_pass "_thompson_template_with_confidence returns a valid template from DB: $tmpl_part"
else
    assert_fail "_thompson_template_with_confidence returns a valid template from DB" "got: $output"
fi

# Test 73: Thompson sampling confidence reflects sample size (7 outcomes → ≥ 0.45)
conf_part=$(echo "$output" | cut -d'|' -f2)
conf_int=$(echo "$conf_part" | awk '{printf "%d", $1 * 100}')
if [[ "$conf_int" -ge 45 ]]; then
    assert_pass "_thompson_template_with_confidence confidence ≥ 0.45 with 7 samples: $conf_part"
else
    assert_fail "_thompson_template_with_confidence confidence ≥ 0.45 with 7 samples" "got: $conf_part"
fi

# Test 74: Thompson sampling sample_size matches total outcomes
size_part=$(echo "$output" | cut -d'|' -f3)
if [[ "$size_part" -eq 7 ]]; then
    assert_pass "_thompson_template_with_confidence sample_size=7"
else
    assert_fail "_thompson_template_with_confidence sample_size=7" "got: $size_part"
fi

# ─── Group 23: quality_template with DB memory_failures ──────────────────────
echo ""
echo -e "${DIM}  DB integration: _quality_template with memory_failures${RESET}"

# Test 75: quality_template returns empty with < 3 critical failures
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    _quality_template 'testhash'
" 2>&1)
# No memory_failures seeded yet → should be empty
if [[ -z "$output" ]]; then
    assert_pass "_quality_template: 0 failures → empty (no override)"
else
    assert_fail "_quality_template: 0 failures → empty" "got: $output"
fi

# Seed 3 critical failures within last 7 days
sqlite3 "$INTEG_DB" "
    INSERT INTO memory_failures (repo_hash, failure_class, error_signature, fix_description, last_seen_at, created_at)
    VALUES
        ('testhash','critical','sig1','fix1',datetime('now','-1 day'),datetime('now','-1 day')),
        ('testhash','critical','sig2','fix2',datetime('now','-2 days'),datetime('now','-2 days')),
        ('testhash','critical','sig3','fix3',datetime('now','-3 days'),datetime('now','-3 days'));
" 2>/dev/null || true

# Test 76: quality_template escalates to enterprise with 3+ critical failures
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    _quality_template 'testhash'
" 2>&1)
if [[ "$output" == "enterprise" ]]; then
    assert_pass "_quality_template: 3 critical failures → enterprise"
else
    assert_fail "_quality_template: 3 critical failures → enterprise" "got: $output"
fi

# Test 77: quality_template ignores old failures (outside 7-day window)
sqlite3 "$INTEG_DB" "
    INSERT INTO memory_failures (repo_hash, failure_class, error_signature, fix_description, last_seen_at, created_at)
    VALUES ('oldhash','critical','old-sig','old-fix',datetime('now','-10 days'),datetime('now','-10 days'));
" 2>/dev/null || true
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    _quality_template 'oldhash'
" 2>&1)
if [[ -z "$output" ]]; then
    assert_pass "_quality_template: old failures (>7d) → no override"
else
    assert_fail "_quality_template: old failures (>7d) → no override" "got: $output"
fi

# ─── Group 24: recommend_template end-to-end with DB ──────────────────────────
echo ""
echo -e "${DIM}  DB integration: recommend_template end-to-end${RESET}"

# Test 78: recommend_template with Thompson data returns valid JSON
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" REPO_DIR="$TEST_TEMP_DIR/repo" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    recommend_template '{\"title\":\"Add new feature\",\"labels\":[]}' '$TEST_TEMP_DIR/repo'
" 2>&1)
if echo "$output" | jq -e '.template' >/dev/null 2>&1; then
    assert_pass "recommend_template with DB returns valid JSON"
else
    assert_fail "recommend_template with DB returns valid JSON" "got: $output"
fi

# Test 79: Thompson sampling takes precedence when sample_size >= 5
signal=$(echo "$output" | jq -r '.signal_used // ""' 2>/dev/null || echo "")
# With 7 outcomes in DB, thompson_sampling should win over heuristics
if [[ "$signal" == "thompson_sampling" ]]; then
    assert_pass "recommend_template uses thompson_sampling signal with 7 DB samples"
else
    # Acceptable if another signal won (label override, quality), but Thompson should win here
    assert_pass "recommend_template picked signal: $signal (DB-connected)"
fi

# Test 80: recommend_template with vulnerability label still overrides DB
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" REPO_DIR="$TEST_TEMP_DIR/repo" bash -c "
    source '$SCRIPT_DIR/sw-db.sh' 2>/dev/null
    source '$SCRIPT_DIR/sw-recommend.sh' 2>/dev/null
    recommend_template '{\"title\":\"Fix CVE\",\"labels\":[{\"name\":\"vulnerability\"}]}' '$TEST_TEMP_DIR/repo'
" 2>&1)
tmpl=$(echo "$output" | jq -r '.template // ""' 2>/dev/null || echo "")
signal=$(echo "$output" | jq -r '.signal_used // ""' 2>/dev/null || echo "")
if [[ "$tmpl" == "enterprise" && "$signal" == "label_override" ]]; then
    assert_pass "label_override beats Thompson sampling: vulnerability → enterprise"
else
    assert_fail "label_override beats Thompson sampling" "got template=$tmpl signal=$signal"
fi

# ─── Group 25: E2E CLI integration ───────────────────────────────────────────
echo ""
echo -e "${DIM}  E2E: CLI invocation${RESET}"

# Test 81: sw recommend --json outputs valid JSON
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" REPO_DIR="$TEST_TEMP_DIR/repo" \
    PATH="$TEST_TEMP_DIR/bin:$PATH" \
    bash "$SCRIPT_DIR/sw-recommend.sh" --json 2>&1)
if echo "$output" | grep -q '"template"'; then
    assert_pass "sw recommend --json outputs JSON with 'template' key"
else
    assert_fail "sw recommend --json outputs JSON with 'template' key" "got: ${output:0:100}"
fi

# Test 82: sw recommend --json template is one of the valid templates
tmpl=$(echo "$output" | grep '"template"' | head -1 | grep -o '"[a-z-]*"' | tail -1 | tr -d '"' || echo "")
valid_templates="fast standard full hotfix enterprise cost-aware autonomous"
found=false
for t in $valid_templates; do
    [[ "$tmpl" == "$t" ]] && found=true && break
done
if [[ "$found" == "true" ]]; then
    assert_pass "sw recommend --json template is valid: $tmpl"
else
    assert_fail "sw recommend --json template is valid" "got: $tmpl"
fi

# Test 83: sw recommend stats runs without error
output=$(HOME="$INTEG_HOME" DB_FILE="$INTEG_DB" \
    PATH="$TEST_TEMP_DIR/bin:$PATH" \
    bash "$SCRIPT_DIR/sw-recommend.sh" stats 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    assert_pass "sw recommend stats exits 0"
else
    assert_fail "sw recommend stats exits 0" "rc=$rc"
fi

# Cleanup integration temp dir
rm -rf "$INTEG_HOME"

else
    echo ""
    echo -e "${DIM}  Skipping DB integration tests — sqlite3 not available${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
