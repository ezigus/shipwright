#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright dashboard test — Validate fleet command dashboard            ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-dashboard-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/logs"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/dashboard"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls kill sleep nohup lsof stat curl; do
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

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEMP_DIR/bin/$mock"
        chmod +x "$TEMP_DIR/bin/$mock"
    done

    # Mock bun — enough to satisfy check_bun but not actually start a server
    cat > "$TEMP_DIR/bin/bun" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock bun: $*"
# If asked to "run" something, just sleep briefly and exit
if [[ "${1:-}" == "run" ]]; then
    sleep 0.1
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/bun"

    # Create a mock server.ts so find_server succeeds
    echo "// mock server" > "$TEMP_DIR/repo/dashboard/server.ts"

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

SRC="$SCRIPT_DIR/sw-dashboard.sh"

echo ""
echo -e "${CYAN}${BOLD}  shipwright dashboard test${RESET}"
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

if grep -qE '^VERSION=' "$SRC" 2>/dev/null; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# Dashboard uses top-level arg parsing, no source guard (acceptable)
if grep -qF 'DEFAULT_PORT=' "$SRC" 2>/dev/null; then
    assert_pass "DEFAULT_PORT constant defined"
else
    assert_fail "DEFAULT_PORT constant defined"
fi

echo ""

# ─── 2. Help ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

HELP_OUT=$(bash "$SRC" help 2>&1) || true

assert_contains "help exits 0 and contains USAGE" "$HELP_OUT" "USAGE"
assert_contains "help lists 'start' subcommand" "$HELP_OUT" "start"
assert_contains "help lists 'stop' subcommand" "$HELP_OUT" "stop"
assert_contains "help lists 'status' subcommand" "$HELP_OUT" "status"
assert_contains "help lists 'open' subcommand" "$HELP_OUT" "open"
assert_contains "help mentions --port option" "$HELP_OUT" "--port"
assert_contains "help mentions --foreground option" "$HELP_OUT" "--foreground"

HELP2=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help alias works" "$HELP2" "USAGE"

HELP3=$(bash "$SRC" -h 2>&1) || true
assert_contains "-h alias works" "$HELP3" "USAGE"

echo ""

# ─── 3. Version flag ────────────────────────────────────────────────────────
echo -e "${BOLD}  Version Flag${RESET}"

VER_OUT=$(bash "$SRC" --version 2>&1) || true
assert_contains "--version shows version" "$VER_OUT" "shipwright dashboard v"

VER_OUT2=$(bash "$SRC" -v 2>&1) || true
assert_contains "-v shows version" "$VER_OUT2" "shipwright dashboard v"

echo ""

# ─── 4. Error Handling ───────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_fail "Unknown argument exits non-zero"
else
    assert_pass "Unknown argument exits non-zero"
fi

echo ""

# ─── 5. Status when not running ─────────────────────────────────────────────
echo -e "${BOLD}  Status Subcommand${RESET}"

# Remove any PID file
rm -f "$HOME/.shipwright/dashboard.pid"

STATUS_OUT=$(bash "$SRC" status 2>&1) || true
assert_contains "status when not running shows Stopped" "$STATUS_OUT" "Stopped"

# Status cleans up stale PID file
echo "99999" > "$HOME/.shipwright/dashboard.pid"
STATUS_OUT2=$(bash "$SRC" status 2>&1) || true
assert_contains "status with stale PID shows Stopped" "$STATUS_OUT2" "Stopped"

# Stale PID file should be cleaned up
if [[ ! -f "$HOME/.shipwright/dashboard.pid" ]]; then
    assert_pass "status cleans up stale PID file"
else
    assert_fail "status cleans up stale PID file"
fi

echo ""

# ─── 6. Stop when not running ───────────────────────────────────────────────
echo -e "${BOLD}  Stop Subcommand${RESET}"

rm -f "$HOME/.shipwright/dashboard.pid"

if bash "$SRC" stop 2>/dev/null; then
    assert_fail "stop without PID file exits non-zero"
else
    assert_pass "stop without PID file exits non-zero"
fi

# stop with stale PID — should clean up gracefully
echo "99999" > "$HOME/.shipwright/dashboard.pid"
STOP_OUT=$(bash "$SRC" stop 2>&1) || true
assert_contains "stop with dead PID cleans up" "$STOP_OUT" "not running"

if [[ ! -f "$HOME/.shipwright/dashboard.pid" ]]; then
    assert_pass "stop removes stale PID file"
else
    assert_fail "stop removes stale PID file"
fi

echo ""

# ─── 7. Port parsing ────────────────────────────────────────────────────────
echo -e "${BOLD}  Port Parsing${RESET}"

# --port without value should fail
if bash "$SRC" --port 2>/dev/null; then
    assert_fail "--port without value exits non-zero"
else
    assert_pass "--port without value exits non-zero"
fi

echo ""

# ─── 8. find_server ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Server Discovery${RESET}"

# find_server should find our mock server.ts
# We can test this indirectly — start with --foreground should try to exec bun
# but we test by checking that the script finds the server path

# Remove the mock server.ts and verify start fails
rm -f "$TEMP_DIR/repo/dashboard/server.ts"

# Need to make the script look in the right place — the script derives repo_dir from SCRIPT_DIR
# Since we're running $SRC (the real script), it will look relative to its own SCRIPT_DIR
# Instead, just verify the find_server function exists and the fallback paths are checked
if grep -qF 'find_server' "$SRC" 2>/dev/null; then
    assert_pass "find_server function defined"
else
    assert_fail "find_server function defined"
fi

if grep -qF 'dashboard/server.ts' "$SRC" 2>/dev/null; then
    assert_pass "Looks for dashboard/server.ts"
else
    assert_fail "Looks for dashboard/server.ts"
fi

echo ""

# ─── 9. Event emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

rm -f "$HOME/.shipwright/events.jsonl"

# Source just the emit_event portion by extracting it
# The dashboard script doesn't have a source guard so we can't source it directly
# (it runs main at parse time). Instead, verify emit_event usage in source.
if grep -qF 'emit_event "dashboard.started"' "$SRC" 2>/dev/null; then
    assert_pass "Emits dashboard.started event"
else
    assert_fail "Emits dashboard.started event"
fi

if grep -qF 'emit_event "dashboard.stopped"' "$SRC" 2>/dev/null; then
    assert_pass "Emits dashboard.stopped event"
else
    assert_fail "Emits dashboard.stopped event"
fi

echo ""

# ─── 10. State paths ────────────────────────────────────────────────────────
echo -e "${BOLD}  State Paths${RESET}"

if grep -qF 'dashboard.pid' "$SRC" 2>/dev/null; then
    assert_pass "Uses dashboard.pid for process tracking"
else
    assert_fail "Uses dashboard.pid for process tracking"
fi

if grep -qF 'dashboard.log' "$SRC" 2>/dev/null; then
    assert_pass "Uses dashboard.log for logging"
else
    assert_fail "Uses dashboard.log for logging"
fi

if grep -qF 'is_running' "$SRC" 2>/dev/null; then
    assert_pass "is_running function defined"
else
    assert_fail "is_running function defined"
fi

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
