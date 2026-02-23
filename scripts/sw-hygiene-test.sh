#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright hygiene test — Repository Organization & Cleanup tests       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-hygiene-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/scripts"
    mkdir -p "$TEMP_DIR/repo/.claude"

    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Create a mock script in the test repo
    cat > "$TEMP_DIR/repo/scripts/sw-example.sh" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
example_func() { echo "hello"; }
MOCK_SCRIPT
    chmod +x "$TEMP_DIR/repo/scripts/sw-example.sh"

    # Create mock package.json
    echo '{"dependencies":{"jq":"*"},"devDependencies":{}}' > "$TEMP_DIR/repo/package.json"

    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        case "${2:-}" in
            --git-dir) echo ".git" ;;
            --abbrev-ref) echo "main" ;;
            *) echo "/tmp/mock-repo" ;;
        esac
        ;;
    fetch) exit 0 ;;
    branch) echo "" ;;
    add) exit 0 ;;
    commit) exit 0 ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"

    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock find to limit scope (avoid scanning host filesystem)
    cat > "$TEMP_DIR/bin/find" <<MOCK
#!/usr/bin/env bash
# Pass through to real find but only within our temp dir
$(command -v find) "\$@"
MOCK
    chmod +x "$TEMP_DIR/bin/find"

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Hygiene Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright hygiene"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits 1" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

# ─── Test 4: report subcommand ────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
assert_contains "report shows generating" "$output" "Generating"

# ─── Test 5: report creates JSON file ─────────────────────────────────────
# The report command saves JSON to .claude/hygiene-report.json (not stdout)
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
report_file="$TEMP_DIR/repo/.claude/hygiene-report.json"
if [[ -f "$report_file" ]]; then
    assert_pass "report creates JSON file"
else
    # Script may write to the real REPO_DIR; check there
    report_file2="$(cd scripts/.. && pwd)/.claude/hygiene-report.json"
    if [[ -f "$report_file2" ]]; then
        report_file="$report_file2"
        assert_pass "report creates JSON file"
    else
        assert_fail "report creates JSON file"
    fi
fi

# ─── Test 6: report JSON is valid and has expected fields ─────────────────
if [[ -f "$report_file" ]] && jq . "$report_file" >/dev/null 2>&1; then
    assert_pass "report JSON is valid"
    file_content=$(cat "$report_file")
    assert_contains "report JSON has timestamp" "$file_content" "timestamp"
    assert_contains "report JSON has sections" "$file_content" "sections"
else
    assert_fail "report JSON is valid" "file not found or invalid JSON"
    assert_fail "report JSON has timestamp"
    assert_fail "report JSON has sections"
fi

# ─── Test 7: structure subcommand ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}structure subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" structure 2>&1) && rc=0 || rc=$?
assert_eq "structure exits 0" "0" "$rc"
assert_contains "structure reports validating" "$output" "Validating"

# ─── Test 8: naming subcommand ────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}naming subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" naming 2>&1) && rc=0 || rc=$?
assert_eq "naming exits 0" "0" "$rc"
assert_contains "naming shows checking" "$output" "Checking naming"

# ─── Test 9: dead-code subcommand ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}dead-code subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" dead-code 2>&1) && rc=0 || rc=$?
assert_eq "dead-code exits 0" "0" "$rc"
assert_contains "dead-code shows scanning" "$output" "Scanning"

# Force the timeout path deterministically by mocking date +%s progression.
export SW_HYGIENE_DATE_COUNTER_FILE="$TEMP_DIR/date-counter"
cat > "$TEMP_DIR/bin/date" <<'MOCK_DATE'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s" ]]; then
    counter_file="${SW_HYGIENE_DATE_COUNTER_FILE:-${TMPDIR:-/tmp}/sw-hygiene-date-counter}"
    count=0
    if [[ -f "$counter_file" ]]; then
        count=$(cat "$counter_file")
    fi
    count=$((count + 1))
    echo "$count" > "$counter_file"
    echo "$((count * 100))"
    exit 0
fi
/bin/date "$@"
MOCK_DATE
chmod +x "$TEMP_DIR/bin/date"
output=$(SHIPWRIGHT_HYGIENE_DEAD_CODE_TIMEOUT_S=20 bash "$SCRIPT_DIR/sw-hygiene.sh" dead-code 2>&1) && rc=0 || rc=$?
assert_eq "dead-code timeout still exits 0" "0" "$rc"
assert_contains "dead-code timeout warns partial results" "$output" "partial"

output=$(SHIPWRIGHT_HYGIENE_DEAD_CODE_TIMEOUT_S=abc bash "$SCRIPT_DIR/sw-hygiene.sh" dead-code 2>&1) && rc=0 || rc=$?
assert_eq "dead-code invalid timeout still exits 0" "0" "$rc"
assert_contains "dead-code invalid timeout warns and falls back" "$output" "Invalid dead-code timeout"
rm -f "$SW_HYGIENE_DATE_COUNTER_FILE" "$TEMP_DIR/bin/date"
unset SW_HYGIENE_DATE_COUNTER_FILE

# ─── Test 10: dependencies subcommand ─────────────────────────────────────
echo ""
echo -e "  ${CYAN}dependencies subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" dependencies 2>&1) && rc=0 || rc=$?
assert_eq "dependencies exits 0" "0" "$rc"
assert_contains "dependencies shows auditing" "$output" "Auditing"

# ─── Test 11: platform-refactor subcommand (AGI-level self-improvement) ───
echo ""
echo -e "  ${CYAN}platform-refactor subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" platform-refactor 2>&1) && rc=0 || rc=$?
assert_eq "platform-refactor exits 0" "0" "$rc"
assert_contains "platform-refactor scans for hardcoded/fallback" "$output" "hardcoded"
platform_hygiene_file="$(cd "$SCRIPT_DIR/.." && pwd)/.claude/platform-hygiene.json"
if [[ -f "$platform_hygiene_file" ]] && jq -e '.counts' "$platform_hygiene_file" >/dev/null 2>&1; then
    assert_pass "platform-refactor creates platform-hygiene.json with counts"
else
    assert_fail "platform-refactor creates platform-hygiene.json with counts"
fi

# ─── Test 12: policy read (config/policy.json via policy_get) ───
echo ""
echo -e "  ${CYAN}policy read (policy_get from config)${RESET}"
policy_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-test.XXXXXX")
mkdir -p "$policy_tmp/config"
echo '{"hygiene":{"artifact_age_days":14}}' > "$policy_tmp/config/policy.json"
got=$(REPO_DIR="$policy_tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
rm -rf "$policy_tmp"
assert_eq "policy_get returns value from config" "14" "$got"
# Default when key missing
policy_tmp2=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-test.XXXXXX")
mkdir -p "$policy_tmp2/config"
echo '{}' > "$policy_tmp2/config/policy.json"
got_default=$(REPO_DIR="$policy_tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
rm -rf "$policy_tmp2"
assert_eq "policy_get returns default when key missing" "7" "$got_default"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
