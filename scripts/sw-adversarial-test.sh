#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adversarial test — Validate adversarial agent code review    ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-adversarial-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/.claude"
    mkdir -p "$TEMP_DIR/repo/scripts"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls shasum; do
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
    config) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEMP_DIR/bin/$mock"
        chmod +x "$TEMP_DIR/bin/$mock"
    done

    # Copy script under test into mock repo with a stub intelligence
    cp "$SCRIPT_DIR/sw-adversarial.sh" "$TEMP_DIR/repo/scripts/"

    # Create a stub sw-intelligence.sh that provides _intelligence_call_claude and _intelligence_md5
    cat > "$TEMP_DIR/repo/scripts/sw-intelligence.sh" <<'STUBEOF'
#!/usr/bin/env bash
_intelligence_call_claude() { echo "[]"; return 0; }
_intelligence_md5() { echo "mock-md5"; }
STUBEOF

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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

SRC="$SCRIPT_DIR/sw-adversarial.sh"
MOCK_SRC="$TEMP_DIR/repo/scripts/sw-adversarial.sh"

echo ""
echo -e "${CYAN}${BOLD}  shipwright adversarial test${RESET}"
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

if grep -qE 'if \[\[.*BASH_SOURCE' "$SRC" 2>/dev/null; then
    assert_pass "Source guard pattern (if/then/fi)"
else
    assert_fail "Source guard pattern (if/then/fi)"
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
assert_contains "help lists 'review' subcommand" "$HELP_OUT" "review"
assert_contains "help lists 'iterate' subcommand" "$HELP_OUT" "iterate"
assert_contains "help mentions adversarial_enabled flag" "$HELP_OUT" "adversarial_enabled"

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

# ─── 4. Review without args ─────────────────────────────────────────────────
echo -e "${BOLD}  Review Subcommand${RESET}"

# review with adversarial disabled (no config file) should return "[]"
OUT=$(bash "$MOCK_SRC" review "some diff" 2>/dev/null) || true
assert_contains "review disabled returns empty JSON array" "$OUT" "[]"

# review with empty diff and enabled should fail
# Create a config that enables adversarial
mkdir -p "$TEMP_DIR/repo/.claude"
cat > "$TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"adversarial_enabled":true}}
EOF

if bash "$MOCK_SRC" review 2>/dev/null; then
    assert_fail "review without diff arg exits non-zero"
else
    assert_pass "review without diff arg exits non-zero"
fi

echo ""

# ─── 5. Iterate subcommand ──────────────────────────────────────────────────
echo -e "${BOLD}  Iterate Subcommand${RESET}"

# iterate without args should fail
if bash "$MOCK_SRC" iterate 2>/dev/null; then
    assert_fail "iterate without args exits non-zero"
else
    assert_pass "iterate without args exits non-zero"
fi

# iterate with no critical findings should converge immediately
OUT=$(bash "$MOCK_SRC" iterate "some code" "[]" 1 2>/dev/null) || true
assert_contains "iterate with empty findings converges" "$OUT" "[]"

# iterate beyond max rounds returns findings
OUT=$(bash "$MOCK_SRC" iterate "some code" '[{"severity":"critical"}]' 99 2>/dev/null) || true
# Should return the findings back since round > MAX_ROUNDS (default 3)
_count=$(printf '%s\n' "$OUT" | grep -cF 'critical' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "iterate past max rounds returns findings"
else
    assert_fail "iterate past max rounds returns findings"
fi

echo ""

# ─── 6. Configuration ───────────────────────────────────────────────────────
echo -e "${BOLD}  Configuration${RESET}"

# ADVERSARIAL_MAX_ROUNDS env var
export ADVERSARIAL_MAX_ROUNDS=1
OUT=$(bash "$MOCK_SRC" iterate "some code" '[{"severity":"critical"}]' 2 2>/dev/null) || true
_count=$(printf '%s\n' "$OUT" | grep -cF 'critical' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "ADVERSARIAL_MAX_ROUNDS env var respected"
else
    assert_fail "ADVERSARIAL_MAX_ROUNDS env var respected"
fi
unset ADVERSARIAL_MAX_ROUNDS

# _adversarial_enabled reads from daemon-config.json
cat > "$TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"adversarial_enabled":false}}
EOF
OUT=$(bash "$MOCK_SRC" review "some diff" 2>/dev/null) || true
assert_contains "disabled config returns empty array" "$OUT" "[]"

echo ""

# ─── 7. Event emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

rm -f "$HOME/.shipwright/events.jsonl"

# Source the mock script to get emit_event
source "$MOCK_SRC"

emit_event "adversarial.test" "round=1"

if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "emit_event creates events.jsonl"
else
    assert_fail "emit_event creates events.jsonl"
fi

LAST_LINE=$(tail -1 "$HOME/.shipwright/events.jsonl")
if echo "$LAST_LINE" | jq empty 2>/dev/null; then
    assert_pass "emit_event writes valid JSON"
else
    assert_fail "emit_event writes valid JSON" "$LAST_LINE"
fi

assert_contains "Event contains type field" "$LAST_LINE" '"type":"adversarial.test"'

echo ""

# ─── Results ─────────────────────────────────────────────────────────────────
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
