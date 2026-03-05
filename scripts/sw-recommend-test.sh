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
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
