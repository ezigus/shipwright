#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pr-lifecycle test — Validate autonomous PR management       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-pr-lifecycle-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/.claude"
    mkdir -p "$TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls chmod; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    pr)
        case "${2:-}" in
            view) echo '{"number":42,"title":"Test PR","body":"closes #10","state":"OPEN","headRefName":"feat/test","baseRefName":"main","statusCheckRollup":[],"reviews":[],"commits":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","mergeStateStatus":"CLEAN","reviewDecision":"PENDING"}' ;;
            list) echo '[]' ;;
            diff) echo "diff --git a/file.sh b/file.sh
+added line
-removed line" ;;
            comment) echo "comment posted" ;;
            merge) echo "merged" ;;
            checks) echo '[]' ;;
            close) echo "closed" ;;
        esac ;;
    issue)
        case "${2:-}" in
            comment) echo "comment posted" ;;
            view) echo '{"body":"closes #10"}' ;;
        esac ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock claude and tmux
    for mock in claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEMP_DIR/bin/$mock"
        chmod +x "$TEMP_DIR/bin/$mock"
    done

    # Create minimal daemon config for pr_lifecycle
    echo '{"pr_lifecycle":{"auto_merge_enabled":"false","stale_days":"14"}}' > "$TEMP_DIR/repo/.claude/daemon-config.json"

    # Copy compat.sh if available
    if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
        cp "$SCRIPT_DIR/lib/compat.sh" "$TEMP_DIR/repo/scripts/lib/compat.sh"
    fi

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

SRC="$SCRIPT_DIR/sw-pr-lifecycle.sh"

echo ""
echo -e "${CYAN}${BOLD}  Shipwright PR Lifecycle Test Suite${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

# ─── 1. Script Safety ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SRC"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "trap.*ERR" "$SRC"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -q '^VERSION=' "$SRC"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

ver=$(grep -m1 '^VERSION=' "$SRC" | sed 's/VERSION="//' | sed 's/"//')
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    assert_pass "VERSION is semver: $ver"
else
    assert_fail "VERSION is semver" "got: $ver"
fi

echo ""

# ─── 2. Source Guard ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Source Guard${RESET}"

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SRC"; then
    assert_pass "source guard pattern present"
else
    assert_fail "source guard pattern present"
fi

# Must use if/then/fi, NOT [[ ]] && main
if grep -q 'if \[\[.*BASH_SOURCE' "$SRC"; then
    assert_pass "source guard uses if/then/fi (not && pattern)"
else
    assert_fail "source guard uses if/then/fi (not && pattern)"
fi

echo ""

# ─── 3. Help Output ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

setup_env

help_output=$(bash "$SRC" help 2>&1) || true

assert_contains "help mentions review command" "$help_output" "review"
assert_contains "help mentions merge command" "$help_output" "merge"
assert_contains "help mentions cleanup command" "$help_output" "cleanup"
assert_contains "help mentions status command" "$help_output" "status"
assert_contains "help mentions patrol command" "$help_output" "patrol"

# --help flag
help_flag_output=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help works" "$help_flag_output" "review"

echo ""

# ─── 4. Unknown Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if ! bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_pass "unknown command exits non-zero"
else
    assert_fail "unknown command exits non-zero"
fi

unknown_output=$(bash "$SRC" nonexistent-cmd 2>&1) || true
assert_contains "unknown command shows error" "$unknown_output" "Unknown command"

echo ""

# ─── 5. Default Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Default Behavior${RESET}"

default_output=$(bash "$SRC" 2>&1) || true
assert_contains "no-arg defaults to help" "$default_output" "review"

echo ""

# ─── 6. Review Requires PR Number ────────────────────────────────────────────
echo -e "${BOLD}  Argument Validation${RESET}"

if ! bash "$SRC" review 2>/dev/null; then
    assert_pass "review without PR number exits non-zero"
else
    assert_fail "review without PR number exits non-zero"
fi

review_no_arg=$(bash "$SRC" review 2>&1) || true
assert_contains "review without arg shows error" "$review_no_arg" "PR number required"

if ! bash "$SRC" merge 2>/dev/null; then
    assert_pass "merge without PR number exits non-zero"
else
    assert_fail "merge without PR number exits non-zero"
fi

merge_no_arg=$(bash "$SRC" merge 2>&1) || true
assert_contains "merge without arg shows error" "$merge_no_arg" "PR number required"

echo ""

# ─── 7. Cleanup Subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  Cleanup Subcommand${RESET}"

cleanup_output=$(bash "$SRC" cleanup 2>&1) || true
assert_contains "cleanup runs" "$cleanup_output" "stale"

echo ""

# ─── 8. Status Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Status Subcommand${RESET}"

status_output=$(bash "$SRC" status 2>&1) || true
assert_contains "status shows PR info" "$status_output" "Pull Requests"

echo ""

# ─── 9. Configuration Helpers ────────────────────────────────────────────────
echo -e "${BOLD}  Configuration${RESET}"

if grep -q 'get_pr_config' "$SRC"; then
    assert_pass "get_pr_config helper defined"
else
    assert_fail "get_pr_config helper defined"
fi

if grep -q 'auto_merge_enabled' "$SRC"; then
    assert_pass "auto_merge_enabled config check present"
else
    assert_fail "auto_merge_enabled config check present"
fi

if grep -q 'stale_days' "$SRC"; then
    assert_pass "stale_days config present"
else
    assert_fail "stale_days config present"
fi

echo ""

# ─── 10. Event Emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

if grep -q 'emit_event.*pr\.' "$SRC"; then
    assert_pass "emits pr lifecycle events"
else
    assert_fail "emits pr lifecycle events"
fi

if grep -q 'pr.review_complete' "$SRC"; then
    assert_pass "emits pr.review_complete event"
else
    assert_fail "emits pr.review_complete event"
fi

if grep -q 'pr.merged' "$SRC"; then
    assert_pass "emits pr.merged event"
else
    assert_fail "emits pr.merged event"
fi

echo ""

# ─── 11. Code Quality Patterns ───────────────────────────────────────────────
echo -e "${BOLD}  Code Quality Checks${RESET}"

if grep -q 'HACK\|TODO\|FIXME' "$SRC"; then
    assert_pass "review checks for HACK/TODO/FIXME patterns"
else
    assert_fail "review checks for HACK/TODO/FIXME patterns"
fi

if grep -q 'console\.' "$SRC"; then
    assert_pass "review checks for console.log statements"
else
    assert_fail "review checks for console.log statements"
fi

echo ""

# ─── 12. Triage Function Existence ───────────────────────────────────────────
echo -e "${BOLD}  Review Comment Triage${RESET}"

if grep -q 'triage_review_comments' "$SRC"; then
    assert_pass "triage_review_comments function defined"
else
    assert_fail "triage_review_comments function defined"
fi

if grep -q 'fetch_review_comments' "$SRC"; then
    assert_pass "fetch_review_comments function defined"
else
    assert_fail "fetch_review_comments function defined"
fi

if grep -q 'classify_comment' "$SRC"; then
    assert_pass "classify_comment function defined"
else
    assert_fail "classify_comment function defined"
fi

if grep -q 'inject_review_feedback' "$SRC"; then
    assert_pass "inject_review_feedback function defined"
else
    assert_fail "inject_review_feedback function defined"
fi

if grep -q 'dismiss_comment' "$SRC"; then
    assert_pass "dismiss_comment function defined"
else
    assert_fail "dismiss_comment function defined"
fi

echo ""

# ─── 13. Bot Detection ──────────────────────────────────────────────────────
echo -e "${BOLD}  Bot Detection${RESET}"

if grep -qE 'is_bot|bot_pattern' "$SRC"; then
    assert_pass "bot detection logic present"
else
    assert_fail "bot detection logic present"
fi

if grep -q 'botAuthorPatterns' "$SRC"; then
    assert_pass "reads botAuthorPatterns from policy"
else
    assert_fail "reads botAuthorPatterns from policy"
fi

echo ""

# ─── 14. NO_GITHUB Guard ───────────────────────────────────────────────────
echo -e "${BOLD}  NO_GITHUB Guard${RESET}"

if grep -q 'NO_GITHUB' "$SRC"; then
    assert_pass "NO_GITHUB guard present in triage functions"
else
    assert_fail "NO_GITHUB guard present in triage functions"
fi

echo ""

# ─── 15. Triage CLI Command ────────────────────────────────────────────────
echo -e "${BOLD}  Triage CLI Command${RESET}"

if ! bash "$SRC" triage 2>/dev/null; then
    assert_pass "triage without PR number exits non-zero"
else
    assert_fail "triage without PR number exits non-zero"
fi

triage_no_arg=$(bash "$SRC" triage 2>&1) || true
assert_contains "triage without arg shows error" "$triage_no_arg" "PR number required"

help_output2=$(bash "$SRC" help 2>&1) || true
assert_contains "help mentions triage command" "$help_output2" "triage"

echo ""

# ─── 16. Review Feedback File ──────────────────────────────────────────────
echo -e "${BOLD}  Review Feedback Integration${RESET}"

if grep -q 'review-feedback.json' "$SRC"; then
    assert_pass "review-feedback.json referenced in source"
else
    assert_fail "review-feedback.json referenced in source"
fi

if grep -q 'review-triage.json' "$SRC"; then
    assert_pass "review-triage.json referenced in source"
else
    assert_fail "review-triage.json referenced in source"
fi

echo ""

# ─── 17. Event Emission (Triage) ───────────────────────────────────────────
echo -e "${BOLD}  Triage Events${RESET}"

if grep -q 'pr.comment_triaged' "$SRC"; then
    assert_pass "emits pr.comment_triaged event"
else
    assert_fail "emits pr.comment_triaged event"
fi

if grep -q 'pr.comment_dismissed' "$SRC"; then
    assert_pass "emits pr.comment_dismissed event"
else
    assert_fail "emits pr.comment_dismissed event"
fi

echo ""

# ─── 18. Atomic Write Pattern ──────────────────────────────────────────────
echo -e "${BOLD}  Atomic Writes${RESET}"

if grep -qE '\.tmp\.\$\$' "$SRC"; then
    assert_pass "atomic write pattern (tmp.$$) present"
else
    assert_fail "atomic write pattern (tmp.$$) present"
fi

echo ""

# ─── 19. Classification Model Config ───────────────────────────────────────
echo -e "${BOLD}  Classification Config${RESET}"

if grep -qE 'classificationModel|classification_model' "$SRC"; then
    assert_pass "classification model config referenced"
else
    assert_fail "classification model config referenced"
fi

if grep -q 'get_triage_policy' "$SRC"; then
    assert_pass "get_triage_policy helper defined"
else
    assert_fail "get_triage_policy helper defined"
fi

echo ""

# ─── 20. Heuristic Fallback ────────────────────────────────────────────────
echo -e "${BOLD}  Heuristic Fallback${RESET}"

if grep -qE 'Heuristic.*fallback|heuristic.*classification|Heuristic:' "$SRC"; then
    assert_pass "heuristic fallback classification present"
else
    assert_fail "heuristic fallback classification present"
fi

echo ""

# ─── 21. Dismiss Reply Template ────────────────────────────────────────────
echo -e "${BOLD}  Dismiss Reply${RESET}"

if grep -q 'dismissReplyTemplate' "$SRC"; then
    assert_pass "dismiss reply template from policy referenced"
else
    assert_fail "dismiss reply template from policy referenced"
fi

if grep -q '{{reason}}' "$SRC"; then
    assert_pass "dismiss template interpolates reason"
else
    assert_fail "dismiss template interpolates reason"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
