#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright task-classifier test — Complexity scoring unit tests         ║
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
    diff)
        if [[ "${2:-}" == "--name-only" ]]; then
            echo "file1.sh"
            echo "file2.sh"
        elif [[ "${2:-}" == "--numstat" ]]; then
            echo "10	5	file1.sh"
            echo "20	10	file2.sh"
        fi ;;
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
print_test_header "Shipwright Task Classifier Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# Source the classifier for function-level testing
source "$SCRIPT_DIR/sw-task-classifier.sh" 2>/dev/null || true

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-task-classifier.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows scoring" "$output" "SCORING"
assert_contains "help shows tiers" "$output" "TIERS"

# ─── Test 2: Simple task classification (docs, 1 file) ────────────────────
echo ""
echo -e "${BOLD}  Simple Task Classification${RESET}"
score=$(classify_task "fix typo in README" "README.md" "" "10")
if [[ "$score" -lt 30 ]]; then
    assert_pass "simple docs task scores < 30 (got $score)"
else
    assert_fail "simple docs task scores < 30" "got $score"
fi

# ─── Test 3: Medium task classification (feature, 3-5 files) ──────────────
echo ""
echo -e "${BOLD}  Medium Task Classification${RESET}"
file_list="src/auth.js
src/middleware.js
src/routes.js
src/tests/auth.test.js"
score=$(classify_task "add authentication feature" "$file_list" "" "150")
if [[ "$score" -ge 30 ]] && [[ "$score" -lt 80 ]]; then
    assert_pass "medium feature task scores 30-79 (got $score)"
else
    assert_fail "medium feature task scores 30-79" "got $score"
fi

# ─── Test 4: Complex task classification (architecture, 10+ files) ─────────
echo ""
echo -e "${BOLD}  Complex Task Classification${RESET}"
file_list=$(for i in $(seq 1 15); do echo "file${i}.sh"; done)
score=$(classify_task "redesign pipeline architecture" "$file_list" "systemic failure across modules" "600")
if [[ "$score" -ge 80 ]]; then
    assert_pass "complex architecture task scores >= 80 (got $score)"
else
    assert_fail "complex architecture task scores >= 80" "got $score"
fi

# ─── Test 5: File count scoring ────────────────────────────────────────────
echo ""
echo -e "${BOLD}  File Count Scoring${RESET}"
score=$(_score_file_count "file1.sh")
assert_eq "1 file scores 10" "10" "$score"

score=$(_score_file_count "a.sh
b.sh
c.sh
d.sh")
assert_eq "4 files scores 40" "40" "$score"

score=$(_score_file_count "$(for i in $(seq 1 8); do echo "f${i}.sh"; done)")
assert_eq "8 files scores 70" "70" "$score"

score=$(_score_file_count "$(for i in $(seq 1 15); do echo "f${i}.sh"; done)")
assert_eq "15 files scores 90" "90" "$score"

score=$(_score_file_count "")
assert_eq "empty file list scores 50" "50" "$score"

# ─── Test 6: Change size scoring ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Change Size Scoring${RESET}"
score=$(_score_change_size "20")
assert_eq "<50 lines scores 10" "10" "$score"

score=$(_score_change_size "100")
assert_eq "100 lines scores 40" "40" "$score"

score=$(_score_change_size "300")
assert_eq "300 lines scores 70" "70" "$score"

score=$(_score_change_size "800")
assert_eq "800 lines scores 90" "90" "$score"

score=$(_score_change_size "0")
assert_eq "0 lines scores 10" "10" "$score"

score=$(_score_change_size "abc")
assert_eq "non-numeric line count scores 50" "50" "$score"

# ─── Test 7: Error complexity scoring ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Complexity Scoring${RESET}"
score=$(_score_error_complexity "")
assert_eq "no error context scores 10" "10" "$score"

score=$(_score_error_complexity "syntax error in file.js")
assert_eq "syntax error scores 20" "20" "$score"

score=$(_score_error_complexity "logic error causing regression")
assert_eq "logic error scores 50" "50" "$score"

score=$(_score_error_complexity "systemic failure across modules")
assert_eq "systemic error scores 80" "80" "$score"

score=$(_score_error_complexity "some random error happened")
assert_eq "generic error scores 35" "35" "$score"

# ─── Test 8: Keyword scoring ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Keyword Scoring${RESET}"
score=$(_score_keywords "update documentation and readme")
assert_eq "docs keywords score 10" "10" "$score"

score=$(_score_keywords "fix login bug on the dashboard")
assert_eq "fix keywords score 30" "30" "$score"

score=$(_score_keywords "add new feature for user registration")
assert_eq "feature keywords score 40" "40" "$score"

score=$(_score_keywords "refactor the authentication module")
assert_eq "refactor keywords score 60" "60" "$score"

score=$(_score_keywords "architect new pipeline redesign")
assert_eq "architecture keywords score 90" "90" "$score"

score=$(_score_keywords "")
assert_eq "empty body scores 50" "50" "$score"

# ─── Test 9: Complexity to tier mapping ─────────────────────────────────────
echo ""
echo -e "${BOLD}  Complexity to Tier${RESET}"
tier=$(complexity_to_tier 10 30 80)
assert_eq "score 10 → haiku" "haiku" "$tier"

tier=$(complexity_to_tier 50 30 80)
assert_eq "score 50 → sonnet" "sonnet" "$tier"

tier=$(complexity_to_tier 90 30 80)
assert_eq "score 90 → opus" "opus" "$tier"

tier=$(complexity_to_tier 29 30 80)
assert_eq "score 29 → haiku (boundary)" "haiku" "$tier"

tier=$(complexity_to_tier 30 30 80)
assert_eq "score 30 → sonnet (boundary)" "sonnet" "$tier"

tier=$(complexity_to_tier 79 30 80)
assert_eq "score 79 → sonnet (boundary)" "sonnet" "$tier"

tier=$(complexity_to_tier 80 30 80)
assert_eq "score 80 → opus (boundary)" "opus" "$tier"

# ─── Test 10: Edge cases ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Edge Cases${RESET}"
score=$(classify_task "" "" "" "0")
if [[ "$score" =~ ^[0-9]+$ ]]; then
    assert_pass "empty inputs produce valid score (got $score)"
else
    assert_fail "empty inputs produce valid score" "got: $score"
fi

score=$(classify_task "fix bug" "a.sh" "" "notanumber")
if [[ "$score" =~ ^[0-9]+$ ]]; then
    assert_pass "invalid line count handled gracefully (got $score)"
else
    assert_fail "invalid line count handled gracefully" "got: $score"
fi

# ─── Test 11: Classify from git (mock) ────────────────────────────────────
echo ""
echo -e "${BOLD}  Classify from Git${RESET}"
score=$(classify_task_from_git "fix small bug" "" 2>/dev/null) || score="error"
if [[ "$score" =~ ^[0-9]+$ ]]; then
    assert_pass "classify_task_from_git returns valid score (got $score)"
else
    assert_fail "classify_task_from_git returns valid score" "got: $score"
fi

# ─── Test 12: CLI classify subcommand ──────────────────────────────────────
echo ""
echo -e "${BOLD}  CLI Subcommands${RESET}"
output=$(bash "$SCRIPT_DIR/sw-task-classifier.sh" classify "fix typo" "README.md" "" "5" 2>&1)
if [[ "$output" =~ ^[0-9]+$ ]]; then
    assert_pass "CLI classify returns numeric score (got $output)"
else
    assert_fail "CLI classify returns numeric score" "got: $output"
fi

output=$(bash "$SCRIPT_DIR/sw-task-classifier.sh" tier "redesign architecture" "$(for i in $(seq 1 12); do echo "f${i}"; done)" "systemic failure" "700" 2>&1)
if [[ "$output" =~ ^(haiku|sonnet|opus)$ ]]; then
    assert_pass "CLI tier returns model name (got $output)"
else
    assert_fail "CLI tier returns model name" "got: $output"
fi

echo ""
echo ""
print_test_results
