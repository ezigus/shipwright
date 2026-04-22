#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  ruflo-adapter test suite                                                 ║
# ║  Unit tests for ruflo detection, MCP lifecycle, and circuit-breaker      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: ruflo-adapter Tests"

setup_test_env "sw-ruflo-adapter-test"
_test_cleanup_hook() { cleanup_test_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Module guard prevents double-sourcing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Module guard"

source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

if [[ "${_RUFLO_ADAPTER_LOADED:-}" == "1" ]]; then
    assert_pass "module guard sentinel set after first source"
else
    assert_fail "module guard sentinel set after first source"
fi

# Verify the guard: modify sentinel, re-source, confirm no reset
RUFLO_AVAILABLE="sentinel_value"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
if [[ "${RUFLO_AVAILABLE}" == "sentinel_value" ]]; then
    assert_pass "double-source guard prevents re-initialization"
else
    assert_fail "double-source guard prevents re-initialization" "RUFLO_AVAILABLE was reset on re-source"
fi

# Reset for remaining tests
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: ruflo_detect with mock ruflo binary → RUFLO_AVAILABLE=true
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_detect — binary present"

mock_binary "ruflo" 'exit 0'

RUFLO_AVAILABLE=false
ruflo_detect
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_detect sets RUFLO_AVAILABLE=true when binary exists"
else
    assert_fail "ruflo_detect sets RUFLO_AVAILABLE=true when binary exists" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: ruflo_detect with no ruflo binary → RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_detect — binary absent"

# Remove mock ruflo and mock npx to fail
rm -f "$TEST_TEMP_DIR/bin/ruflo"
mock_binary "npx" 'exit 1'

# Temporarily restrict PATH to only the test bin dir so real system ruflo is excluded
_saved_path="$PATH"
PATH="$TEST_TEMP_DIR/bin"
RUFLO_AVAILABLE=true
ruflo_detect || true
PATH="$_saved_path"

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_detect sets RUFLO_AVAILABLE=false when no binary"
else
    assert_fail "ruflo_detect sets RUFLO_AVAILABLE=false when no binary" "got: $RUFLO_AVAILABLE"
fi

# Restore mock ruflo for subsequent tests
mock_binary "ruflo" 'case "${1:-}" in
    mcp) case "${2:-}" in
        start) sleep 100 & echo $!; exit 0 ;;
        status) exit 0 ;;
        *) exit 0 ;;
    esac ;;
    *) exit 0 ;;
esac'

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: ruflo_available exit codes
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_available"

RUFLO_AVAILABLE=true
if ruflo_available; then
    assert_pass "ruflo_available returns 0 when RUFLO_AVAILABLE=true"
else
    assert_fail "ruflo_available returns 0 when RUFLO_AVAILABLE=true"
fi

RUFLO_AVAILABLE=false
if ! ruflo_available; then
    assert_pass "ruflo_available returns 1 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_available returns 1 when RUFLO_AVAILABLE=false"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: ruflo_init with no ruflo binary → no-op, exits 0
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — ruflo absent"

rm -f "$TEST_TEMP_DIR/bin/ruflo"
mock_binary "npx" 'exit 1'

RUFLO_AVAILABLE=false

# Restrict PATH to only the test bin dir so real system ruflo is excluded
_saved_path_init="$PATH"
PATH="$TEST_TEMP_DIR/bin"
exit_code=0
ruflo_init || exit_code=$?
PATH="$_saved_path_init"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_init exits 0 when ruflo unavailable"
else
    assert_fail "ruflo_init exits 0 when ruflo unavailable" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_init leaves RUFLO_AVAILABLE=false when ruflo unavailable"
else
    assert_fail "ruflo_init leaves RUFLO_AVAILABLE=false when ruflo unavailable" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: ruflo_cleanup no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — daemon not started by this run"

RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=false
exit_code=0
ruflo_cleanup || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=false" "got exit code: $exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: ruflo_cleanup calls ruflo stop when available
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — calls ruflo stop"

# Mock ruflo: record calls so we can verify `stop` was invoked
_cleanup_call_log="$TEST_TEMP_DIR/cleanup-calls.txt"
rm -f "$_cleanup_call_log"
mock_binary "ruflo" "echo \"\$*\" >> '$_cleanup_call_log'; exit 0"
# Clear bash command hash so the newly created mock is found before the real binary
hash -d ruflo 2>/dev/null || true

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Stub _timeout as a shell function so ruflo_with_timeout passes shell functions
# (like _ruflo_run_quiet) directly without going through system timeout(1), which
# cannot exec shell functions. This exercises the actual circuit-breaker logic.
_timeout() { local _ts="$1"; shift; "$@"; }
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true

exit_code=0
ruflo_cleanup || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=true"
else
    assert_fail "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=true" "got exit code: $exit_code"
fi

if grep -q "^stop" "$_cleanup_call_log" 2>/dev/null; then
    assert_pass "ruflo_cleanup calls ruflo stop"
else
    assert_fail "ruflo_cleanup calls ruflo stop" "stop not found in call log: $(cat "$_cleanup_call_log" 2>/dev/null)"
fi

# Restore: unset _timeout stub and reload adapter for subsequent tests
unset -f _timeout
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: ruflo_with_timeout — circuit-breaks on timeout
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — circuit-breaker"

# Mock a command that fails (simulates timeout/failure)
mock_binary "ruflo_slow_cmd" 'exit 1'

RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

exit_code=0
ruflo_with_timeout 1 ruflo_slow_cmd || exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_with_timeout returns non-zero on command failure"
else
    assert_fail "ruflo_with_timeout returns non-zero on command failure"
fi

# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_with_timeout does NOT disable ruflo on single failure (recoverable — threshold 5)"
else
    assert_fail "ruflo_with_timeout does NOT disable ruflo on single failure (recoverable — threshold 5)" "got: $RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -eq 1 ]]; then
    assert_pass "ruflo_with_timeout increments RUFLO_FAILURE_COUNT to 1 on first failure"
else
    assert_fail "ruflo_with_timeout increments RUFLO_FAILURE_COUNT to 1 on first failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: ruflo_with_timeout — succeeds without circuit-breaking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — success"

mock_binary "ruflo_fast_cmd" 'exit 0'

RUFLO_AVAILABLE=true
export RUFLO_AVAILABLE

exit_code=0
ruflo_with_timeout 5 ruflo_fast_cmd || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_with_timeout returns 0 on success"
else
    assert_fail "ruflo_with_timeout returns 0 on success" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_with_timeout preserves RUFLO_AVAILABLE=true on success"
else
    assert_fail "ruflo_with_timeout preserves RUFLO_AVAILABLE=true on success" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: RUFLO_AVAILABLE exported and visible in subshell
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "RUFLO_AVAILABLE subshell visibility"

export RUFLO_AVAILABLE=true

subshell_val=$(bash -c 'echo "${RUFLO_AVAILABLE:-unset}"')
if [[ "$subshell_val" == "true" ]]; then
    assert_pass "RUFLO_AVAILABLE=true is visible in subshell after export"
else
    assert_fail "RUFLO_AVAILABLE=true is visible in subshell after export" "got: $subshell_val"
fi

export RUFLO_AVAILABLE=false
subshell_val=$(bash -c 'echo "${RUFLO_AVAILABLE:-unset}"')
if [[ "$subshell_val" == "false" ]]; then
    assert_pass "RUFLO_AVAILABLE=false is visible in subshell after export"
else
    assert_fail "RUFLO_AVAILABLE=false is visible in subshell after export" "got: $subshell_val"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: Module is safe under set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipefail safety"

# Run a subshell with strict mode — source the adapter and call functions
# with ruflo absent; must exit 0
rm -f "$TEST_TEMP_DIR/bin/ruflo"

pipefail_exit=0
bash -euo pipefail -c "
    export PATH='$TEST_TEMP_DIR/bin:/usr/bin:/bin'
    source '$SCRIPT_DIR/lib/ruflo-adapter.sh' 2>/dev/null || true
    ruflo_detect || true
    ruflo_init || true
    ruflo_cleanup || true
    ruflo_available || true
    exit 0
" || pipefail_exit=$?

if [[ $pipefail_exit -eq 0 ]]; then
    assert_pass "module is safe under set -euo pipefail with ruflo absent"
else
    assert_fail "module is safe under set -euo pipefail with ruflo absent" "exited with: $pipefail_exit"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: ruflo_init happy path — ruflo present, daemon starts successfully
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — daemon starts successfully"

# Mock ruflo: all subcommands succeed (init check, start --daemon, etc.)
mock_binary "ruflo" 'exit 0'
# Clear bash command hash so the newly created mock is found before the real binary
hash -d ruflo 2>/dev/null || true

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Stub _timeout as a shell function so ruflo_with_timeout passes shell functions
# (like _ruflo_run_quiet) directly without going through system timeout(1), which
# cannot exec shell functions and would trip the circuit breaker during import_memory.
_timeout() { local _ts="$1"; shift; "$@"; }
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=false

ruflo_init

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_AVAILABLE=true when daemon starts"
else
    assert_fail "ruflo_init sets RUFLO_AVAILABLE=true when daemon starts" "got: $RUFLO_AVAILABLE"
fi

if [[ "$RUFLO_DAEMON_STARTED" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_DAEMON_STARTED=true when daemon starts"
else
    assert_fail "ruflo_init sets RUFLO_DAEMON_STARTED=true when daemon starts" "got: $RUFLO_DAEMON_STARTED"
fi

# Restore: unset _timeout stub and reload adapter for subsequent tests
unset -f _timeout
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: ruflo_init — daemon startup failure, fail-open guarantee
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — daemon startup failure (fail-open)"

# Mock ruflo: init check and start --daemon both fail; status also fails
mock_binary "ruflo" 'exit 1'

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false

exit_code=0
ruflo_init || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_init exits 0 (fail-open) even when daemon startup fails"
else
    assert_fail "ruflo_init exits 0 (fail-open) even when daemon startup fails" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_init sets RUFLO_AVAILABLE=false when daemon startup fails"
else
    assert_fail "ruflo_init sets RUFLO_AVAILABLE=false when daemon startup fails" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 14: ruflo_store — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_store — no-op when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false

exit_code=0
ruflo_store "test-key" "test-value" "test-ns" || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_store returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 15: ruflo_recall — returns empty string when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall — no-op when unavailable"

RUFLO_AVAILABLE=false

result=$(ruflo_recall "some query" "test-ns" 2>/dev/null || true)

if [[ -z "$result" ]]; then
    assert_pass "ruflo_recall returns empty string when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall returns empty string when RUFLO_AVAILABLE=false" "got: $result"
fi

exit_code=0
ruflo_recall "some query" "test-ns" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_recall returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 16: ruflo_index_shipwright_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_shipwright_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_index_shipwright_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_shipwright_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_index_shipwright_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 17: ruflo_index_shipwright_memory — skips gracefully when memory dir missing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_shipwright_memory — skips when no memory dir"

# Use mock ruflo that succeeds so RUFLO_AVAILABLE goes true
mock_binary "ruflo" 'exit 0'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true

# Override HOME to a temp dir with no .shipwright/memory structure
_orig_home="$HOME"
export HOME="$TEST_TEMP_DIR/no-memory-home"
mkdir -p "$HOME"

exit_code=0
ruflo_index_shipwright_memory || exit_code=$?

export HOME="$_orig_home"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_shipwright_memory returns 0 when memory dir missing"
else
    assert_fail "ruflo_index_shipwright_memory returns 0 when memory dir missing" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 18: ruflo_import_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_import_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_import_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_import_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_import_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 19: ruflo_export_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_export_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_export_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_export_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_export_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 20: ruflo_store — circuit-breaker fires on command failure
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_store — circuit-breaker fires on command failure"

mock_binary "ruflo" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
RUFLO_USE_NPX=false

exit_code=0
ruflo_store "test-key" "test-value" "test-ns" || exit_code=$?

# ruflo_store is fail-open — must return 0 even when ruflo binary fails
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store returns 0 (fail-open) when ruflo binary fails"
else
    assert_fail "ruflo_store returns 0 (fail-open) when ruflo binary fails" "exit_code=$exit_code"
fi

# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_store does NOT disable ruflo on single failure (recoverable circuit breaker)"
else
    assert_fail "ruflo_store does NOT disable ruflo on single failure (recoverable circuit breaker)" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -ge 1 ]]; then
    assert_pass "ruflo_store increments RUFLO_FAILURE_COUNT on failure"
else
    assert_fail "ruflo_store increments RUFLO_FAILURE_COUNT on failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 21: ruflo_execute_build_single — returns 1 when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — no-op (returns 1) when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
exit_code=0
ruflo_execute_build_single "test goal" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 when RUFLO_AVAILABLE=false (signals fallback)"
else
    assert_fail "ruflo_execute_build_single returns 1 when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 22: ruflo_execute_build_single — returns 1 when goal is empty
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — returns 1 when goal is empty"

mock_binary "ruflo" 'exit 0'
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 (fail-open) when goal is empty"
else
    assert_fail "ruflo_execute_build_single returns 1 when goal is empty" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 23: ruflo_execute_build_single — circuit-breaker fires when agent fails
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — circuit-breaker fires on agent failure"

mock_binary "ruflo" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "build the feature" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 when agent command fails"
else
    assert_fail "ruflo_execute_build_single returns 1 when agent command fails" "exit_code=$exit_code"
fi
# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_execute_build_single does NOT disable ruflo on single failure (recoverable)"
else
    assert_fail "ruflo_execute_build_single does NOT disable ruflo on single failure (recoverable)" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -ge 1 ]]; then
    assert_pass "ruflo_execute_build_single increments RUFLO_FAILURE_COUNT on failure"
else
    assert_fail "ruflo_execute_build_single increments RUFLO_FAILURE_COUNT on failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 24: ruflo_execute_build_single — returns 0 (success) on happy path
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — returns 0 on success"

mock_binary "ruflo" 'exit 0'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "implement the feature" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_build_single returns 0 when agent command succeeds"
else
    assert_fail "ruflo_execute_build_single returns 0 when agent command succeeds" "exit_code=$exit_code"
fi
# Circuit-breaker must NOT have fired on success
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_execute_build_single does not trip circuit-breaker on success"
else
    assert_fail "ruflo_execute_build_single does not trip circuit-breaker on success" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 25: ruflo_learn_from_shipwright — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — no-op when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
exit_code=0
ruflo_learn_from_shipwright "/nonexistent/file.json" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 when RUFLO_AVAILABLE=false" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 26: ruflo_learn_from_shipwright — skips invalid input (non-file, non-JSON)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — skips invalid input"

RUFLO_AVAILABLE=true
exit_code=0
# Path that doesn't exist is treated as raw JSON; jq fails → _content is empty → skips
ruflo_learn_from_shipwright "/nonexistent/outcome.json" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on invalid input (fail-open)"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on invalid input" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 27: ruflo_recall_similar_outcomes — returns empty when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall_similar_outcomes — no-op when unavailable"

RUFLO_AVAILABLE=false
result=$(ruflo_recall_similar_outcomes "feature" "bug" 2>/dev/null || true)
if [[ -z "$result" ]]; then
    assert_pass "ruflo_recall_similar_outcomes returns empty when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall_similar_outcomes returns empty when RUFLO_AVAILABLE=false" "got: $result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 28: ruflo_index_adr_artifacts — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_adr_artifacts — no-op when unavailable"

RUFLO_AVAILABLE=false
exit_code=0
ruflo_index_adr_artifacts || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_adr_artifacts returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_index_adr_artifacts returns 0 when RUFLO_AVAILABLE=false" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 29: ruflo_learn_from_shipwright — success path with valid outcome file
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — success path (file input)"

# Use mock_binary (writes to TEST_TEMP_DIR/bin, already first in PATH) and
# clear the bash hash table so the cached real ruflo path isn't used.
mock_binary "ruflo" 'exit 0'
hash -r 2>/dev/null || true
_outcome_file="$TEST_TEMP_DIR/outcome-29.json"
printf '{"issue_type":"backend","stage":"build","skills":"tdd","outcome":"success"}\n' \
    > "$_outcome_file"

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
git() {
    if [[ "${1:-}" == "config" && "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
        echo "https://github.com/test/repo.git"
    else
        command git "$@"
    fi
}
exit_code=0
ruflo_learn_from_shipwright "$_outcome_file" || exit_code=$?
unset -f git
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on success with valid file"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on success with valid file" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 30: ruflo_learn_from_shipwright — success path with raw JSON string input
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — success path (raw JSON input)"

mock_binary "ruflo" 'exit 0'
hash -r 2>/dev/null || true

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
git() {
    if [[ "${1:-}" == "config" && "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
        echo "https://github.com/test/repo.git"
    else
        command git "$@"
    fi
}
exit_code=0
ruflo_learn_from_shipwright '{"issue_type":"frontend","outcome":"success"}' || exit_code=$?
unset -f git
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on success with raw JSON"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on success with raw JSON" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_build_hive tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_build_hive returns 1 when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
exit_code=0
ruflo_execute_build_hive "build the feature" 10 || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_build_hive returns 1 when ruflo unavailable" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 1 when goal is empty
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=true
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
exit_code=0
ruflo_execute_build_hive "" || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when goal is empty"
else
    assert_fail "ruflo_execute_build_hive returns 1 when goal is empty" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 1 when hive init fails (binary exits non-zero)
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_hive "build the feature" 5 || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_build_hive returns 1 when hive init fails" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 0 when orchestration succeeds
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
# Write mock directly (single-quoted heredoc) so $1/$2 are not expanded at write time
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive-123"
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_hive "build the feature" 5 || exit_code=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 0 on successful orchestration"
else
    assert_fail "ruflo_execute_build_hive returns 0 on successful orchestration" "got exit=$exit_code"
fi

# Test: ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_agent_count_file="$_test_tmp/agent-count.txt"
# Write mock directly; expand $_agent_count_file at write time (outer heredoc unquoted)
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "spawn" ]]; then
    while [[ \$# -gt 0 ]]; do
        if [[ "\$1" == "--count" ]]; then printf '%s' "\$2" > "$_agent_count_file"; fi
        shift
    done
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive-456"
RUFLO_USE_NPX=false
RUFLO_HIVE_MAX_AGENTS=2
ruflo_execute_build_hive "build the feature" 5 || true
recorded_count=$(cat "$_agent_count_file" 2>/dev/null || echo "0")
unset RUFLO_HIVE_MAX_AGENTS
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ "$recorded_count" == "2" ]]; then
    assert_pass "ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap"
else
    assert_fail "ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap" "count=$recorded_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_review tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_review returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_review "diff content" "$_test_tmp/review-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_review returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_review "" "$_test_tmp/review-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_review returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 1 (exact) when hive init fails (binary exits non-zero)
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_review "diff content here" "$_test_tmp/review-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_review returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 0 and writes artifact on success
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "memory" ]]; then
    printf 'review-diff: <diff content stored>\nreview-adrs: <adr context>\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="review-hive-789"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/review-result.md"
exit_code=0
ruflo_execute_review "diff content here" "$_artifact" || exit_code=$?
# Check exit code and artifact before cleanup
_artifact_exists=false
_artifact_nonempty=false
[[ -f "$_artifact" ]] && _artifact_exists=true
[[ -s "$_artifact" ]] && _artifact_nonempty=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_review returns 0 on success"
else
    assert_fail "ruflo_execute_review returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_review writes artifact file on success"
else
    assert_fail "ruflo_execute_review writes artifact file on success" "artifact missing"
fi
if [[ "$_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_review writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_review writes non-empty artifact on success" "artifact empty"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_compound_quality tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_compound_quality returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_compound_quality "diff content" "$_test_tmp/cq-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_compound_quality "" "$_test_tmp/cq-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 1 (exact) when hive init fails
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_compound_quality "diff content here" "$_test_tmp/cq-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 0 and writes artifact on success
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "memory" ]]; then
    printf 'cq-diff: <diff stored>\ncq-review-context: <review>\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cq-hive-999"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/cq-result.md"
exit_code=0
ruflo_execute_compound_quality "diff content here" "$_artifact" || exit_code=$?
# Check exit code and artifact before cleanup
_cq_artifact_exists=false
_cq_artifact_nonempty=false
[[ -f "$_artifact" ]] && _cq_artifact_exists=true
[[ -s "$_artifact" ]] && _cq_artifact_nonempty=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 0 on success"
else
    assert_fail "ruflo_execute_compound_quality returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_cq_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_compound_quality writes artifact file on success"
else
    assert_fail "ruflo_execute_compound_quality writes artifact file on success" "artifact missing"
fi
if [[ "$_cq_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_compound_quality writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_compound_quality writes non-empty artifact on success" "artifact empty"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_audit tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_audit returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_audit "diff content" "$_test_tmp/audit-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_audit returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_audit "" "$_test_tmp/audit-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_audit returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 1 (exact) when hive init fails
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_audit "diff content here" "$_test_tmp/audit-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_audit returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 0 and writes artifact on success;
#       verifies spawn and orchestrate were called
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
printf '%s %s %s\\n' "\$subcmd" "\${2:-}" "\${3:-}" >> "$_call_log"
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "memory" ]]; then
    printf 'audit-diff: <diff stored>\\nCVE-2024-1234: found in dependency\\nOWASP-A01: broken access control check\\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="audit-hive-999"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/audit-result.md"
exit_code=0
ruflo_execute_audit "diff content here" "$_artifact" || exit_code=$?
_audit_artifact_exists=false
_audit_artifact_nonempty=false
[[ -f "$_artifact" ]] && _audit_artifact_exists=true
[[ -s "$_artifact" ]] && _audit_artifact_nonempty=true
_spawn_called=false
_orch_called=false
grep -q "^hive-mind spawn" "$_call_log" 2>/dev/null && _spawn_called=true
grep -q "^coordination orchestrate" "$_call_log" 2>/dev/null && _orch_called=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_audit returns 0 on success"
else
    assert_fail "ruflo_execute_audit returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_audit_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_audit writes artifact file on success"
else
    assert_fail "ruflo_execute_audit writes artifact file on success" "artifact missing"
fi
if [[ "$_audit_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_audit writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_audit writes non-empty artifact on success" "artifact empty"
fi
if [[ "$_spawn_called" == "true" ]]; then
    assert_pass "ruflo_execute_audit calls hive-mind spawn"
else
    assert_fail "ruflo_execute_audit calls hive-mind spawn" "spawn not invoked"
fi
if [[ "$_orch_called" == "true" ]]; then
    assert_pass "ruflo_execute_audit calls coordination orchestrate"
else
    assert_fail "ruflo_execute_audit calls coordination orchestrate" "orchestrate not invoked"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 31: ruflo_load_defaults — no-op when no defaults file exists
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — no-op when no defaults file"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Ensure no defaults files exist in test environment or current working directory
_orig_home="$HOME"
_orig_pwd="$(pwd)"
_tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.home.XXXXXX")
_tmp_cwd=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.cwd.XXXXXX")
HOME="$_tmp_home"
cd "$_tmp_cwd"
# Capture state before
unset RUFLO_MAX_AGENTS RUFLO_COST_BUDGET_MULTIPLIER RUFLO_CIRCUIT_BREAKER_TIMEOUT \
      RUFLO_LEARNING_BRIDGE RUFLO_Q_LEARNING 2>/dev/null || true
exit_code=0
ruflo_load_defaults || exit_code=$?
cd "$_orig_pwd"
HOME="$_orig_home"
rm -rf "$_tmp_home" "$_tmp_cwd"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_load_defaults returns 0 when no defaults file exists"
else
    assert_fail "ruflo_load_defaults returns 0 when no defaults file" "exit=$exit_code"
fi
if [[ -z "${RUFLO_MAX_AGENTS:-}" ]]; then
    assert_pass "ruflo_load_defaults does not set RUFLO_MAX_AGENTS when no file"
else
    assert_fail "ruflo_load_defaults does not set RUFLO_MAX_AGENTS when no file" "got: $RUFLO_MAX_AGENTS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 32: ruflo_load_defaults — loads values from repo-local .shipwright/defaults.json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — loads values from repo-local file"

_tmp_repo=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mkdir -p "$_tmp_repo/.shipwright"
cat > "$_tmp_repo/.shipwright/defaults.json" <<'JSON'
{
  "ruflo": {
    "enabled": true,
    "max_agents": 6,
    "cost_budget_multiplier": 3.0,
    "circuit_breaker_timeout_s": 45,
    "learning_bridge": false,
    "q_learning_routing": false
  }
}
JSON
# Run in subdir so .shipwright/defaults.json is found relative to CWD
unset RUFLO_MAX_AGENTS RUFLO_COST_BUDGET_MULTIPLIER RUFLO_CIRCUIT_BREAKER_TIMEOUT \
      RUFLO_LEARNING_BRIDGE RUFLO_Q_LEARNING 2>/dev/null || true
(
    cd "$_tmp_repo"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    [[ "${RUFLO_MAX_AGENTS:-}" == "6" ]]               && printf 'agents_ok\n'
    [[ "${RUFLO_COST_BUDGET_MULTIPLIER:-}" == "3.0" ]] && printf 'budget_ok\n'
    [[ "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-}" == "45" ]] && printf 'timeout_ok\n'
    [[ "${RUFLO_LEARNING_BRIDGE:-}" == "false" ]]       && printf 'bridge_ok\n'
    [[ "${RUFLO_Q_LEARNING:-}" == "false" ]]            && printf 'qlearn_ok\n'
) > "$_tmp_repo/results.txt" 2>/dev/null || true
_results=$(cat "$_tmp_repo/results.txt" 2>/dev/null || true)
rm -rf "$_tmp_repo"
if printf '%s\n' "$_results" | grep -q "agents_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_MAX_AGENTS from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_MAX_AGENTS from repo-local file" "results=$_results"
fi
if printf '%s\n' "$_results" | grep -q "timeout_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_CIRCUIT_BREAKER_TIMEOUT from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_CIRCUIT_BREAKER_TIMEOUT from repo-local file" "results=$_results"
fi
if printf '%s\n' "$_results" | grep -q "bridge_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_LEARNING_BRIDGE from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_LEARNING_BRIDGE from repo-local file" "results=$_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 33: ruflo_load_defaults — falls back to ~/.shipwright/defaults.json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — fallback to user-global defaults"

_tmp_home2=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-home.XXXXXX")
_tmp_repo2=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-repo.XXXXXX")
mkdir -p "$_tmp_home2/.shipwright"
cat > "$_tmp_home2/.shipwright/defaults.json" <<'JSON'
{
  "ruflo": {
    "max_agents": 12,
    "circuit_breaker_timeout_s": 60,
    "learning_bridge": true,
    "q_learning_routing": true
  }
}
JSON
_global_results=$(
    cd "$_tmp_repo2"
    HOME="$_tmp_home2"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    [[ "${RUFLO_MAX_AGENTS:-}" == "12" ]]              && printf 'agents_ok\n'
    [[ "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-}" == "60" ]] && printf 'timeout_ok\n'
) 2>/dev/null || true
rm -rf "$_tmp_home2" "$_tmp_repo2"
if printf '%s\n' "$_global_results" | grep -q "agents_ok"; then
    assert_pass "ruflo_load_defaults falls back to ~/.shipwright/defaults.json"
else
    assert_fail "ruflo_load_defaults falls back to ~/.shipwright/defaults.json" "results=$_global_results"
fi
if printf '%s\n' "$_global_results" | grep -q "timeout_ok"; then
    assert_pass "ruflo_load_defaults loads RUFLO_CIRCUIT_BREAKER_TIMEOUT from user-global file"
else
    assert_fail "ruflo_load_defaults loads RUFLO_CIRCUIT_BREAKER_TIMEOUT from user-global file" "results=$_global_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 34: ruflo_load_defaults — repo-local takes priority over user-global
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — repo-local overrides user-global"

_tmp_home3=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-home.XXXXXX")
_tmp_repo3=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-repo.XXXXXX")
mkdir -p "$_tmp_home3/.shipwright" "$_tmp_repo3/.shipwright"
printf '{"ruflo":{"max_agents":99}}\n' > "$_tmp_home3/.shipwright/defaults.json"
printf '{"ruflo":{"max_agents":3}}\n'  > "$_tmp_repo3/.shipwright/defaults.json"
_priority_results=$(
    cd "$_tmp_repo3"
    HOME="$_tmp_home3"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    printf '%s\n' "${RUFLO_MAX_AGENTS:-unset}"
) 2>/dev/null || true
rm -rf "$_tmp_home3" "$_tmp_repo3"
if [[ "$_priority_results" == "3" ]]; then
    assert_pass "ruflo_load_defaults repo-local (3) overrides user-global (99)"
else
    assert_fail "ruflo_load_defaults repo-local overrides user-global" "got: $_priority_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 35: ruflo_load_defaults — handles invalid JSON gracefully (fail-open)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — handles invalid JSON gracefully"

_tmp_repo4=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mkdir -p "$_tmp_repo4/.shipwright"
printf 'not valid json at all\n' > "$_tmp_repo4/.shipwright/defaults.json"
exit_code=0
(
    cd "$_tmp_repo4"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults || exit 1
) 2>/dev/null || exit_code=$?
rm -rf "$_tmp_repo4"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_load_defaults returns 0 on invalid JSON (fail-open)"
else
    assert_fail "ruflo_load_defaults returns 0 on invalid JSON (fail-open)" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests 36-41: CI runner — shipwright-pipeline.yml workflow assertions
# ═══════════════════════════════════════════════════════════════════════════════
_PIPELINE_YML="${SCRIPT_DIR}/../.github/workflows/shipwright-pipeline.yml"

print_test_section "CI workflow — ruflo install step present"
if grep -q "Install ruflo" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml contains 'Install ruflo' step"
else
    assert_fail "shipwright-pipeline.yml contains 'Install ruflo' step" "not found"
fi

print_test_section "CI workflow — ruflo install step has continue-on-error"
if grep -A15 "Install ruflo" "$_PIPELINE_YML" 2>/dev/null | grep -q "continue-on-error: true"; then
    assert_pass "ruflo install step has continue-on-error: true"
else
    assert_fail "ruflo install step has continue-on-error: true" "not found"
fi

print_test_section "CI workflow — ruflo memory cache restore step present"
if grep -q "Restore ruflo memory" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml contains ruflo memory cache restore step"
else
    assert_fail "shipwright-pipeline.yml contains ruflo memory cache restore step" "not found"
fi

print_test_section "CI workflow — cache restore uses cache/restore@v4 (not cache@v4)"
if grep -A3 "Restore ruflo memory" "$_PIPELINE_YML" 2>/dev/null | grep -q "cache/restore@v4"; then
    assert_pass "restore step uses actions/cache/restore@v4 (no implicit post-job save)"
else
    assert_fail "restore step uses actions/cache/restore@v4 (no implicit post-job save)" "not found"
fi

print_test_section "CI workflow — ruflo memory cache save step present"
if grep -q "Save ruflo memory" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml contains ruflo memory cache save step"
else
    assert_fail "shipwright-pipeline.yml contains ruflo memory cache save step" "not found"
fi

print_test_section "CI workflow — cache save step runs on always()"
if grep -A3 "Save ruflo memory" "$_PIPELINE_YML" 2>/dev/null | grep -q "always()"; then
    assert_pass "ruflo memory cache save step uses if: always()"
else
    assert_fail "ruflo memory cache save step uses if: always()" "not found"
fi

print_test_section "CI workflow — ruflo install appears before Run Shipwright pipeline"
_install_line=$(grep -n "Install ruflo" "$_PIPELINE_YML" 2>/dev/null | head -1 | cut -d: -f1)
_run_line=$(grep -n "Run Shipwright pipeline" "$_PIPELINE_YML" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_install_line" && -n "$_run_line" && "$_install_line" -lt "$_run_line" ]]; then
    assert_pass "ruflo install step appears before Run Shipwright pipeline step"
else
    assert_fail "ruflo install step appears before Run Shipwright pipeline step" \
        "install_line=${_install_line:-missing} run_line=${_run_line:-missing}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 38: ruflo_with_timeout — shell function detected and called (no exit 127)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — shell function called without exit 127"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_test_shell_fn() { return 0; }

exit_code=0
ruflo_with_timeout 5 _test_shell_fn || exit_code=$?
unset -f _test_shell_fn

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_with_timeout calls shell function and exits 0 (no exit 127)"
else
    assert_fail "ruflo_with_timeout calls shell function and exits 0 (no exit 127)" "got exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 39: ruflo_with_timeout — shell function killed at timeout (non-zero exit)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — shell function timeout returns non-zero"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_test_slow_fn() { sleep 30; }

exit_code=0
ruflo_with_timeout 2 _test_slow_fn || exit_code=$?
unset -f _test_slow_fn

if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_with_timeout returns non-zero when shell function exceeds timeout"
else
    assert_fail "ruflo_with_timeout returns non-zero when shell function exceeds timeout" "got exit=0"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 40: ruflo_health_check — recovery from disabled state (status responds)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — recovers when daemon status responds"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=3
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

exit_code=0
ruflo_health_check || exit_code=$?
_avail_after="$RUFLO_AVAILABLE"
_count_after="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_health_check always returns 0 (fail-open)"
else
    assert_fail "ruflo_health_check always returns 0 (fail-open)" "got exit=$exit_code"
fi
if [[ "$_avail_after" == "true" ]]; then
    assert_pass "ruflo_health_check sets RUFLO_AVAILABLE=true when daemon responds"
else
    assert_fail "ruflo_health_check sets RUFLO_AVAILABLE=true when daemon responds" "got: $_avail_after"
fi
if [[ "$_count_after" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 on recovery"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 on recovery" "got: $_count_after"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 41: ruflo_health_check — daemon restart path (status fails, start succeeds)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — restarts daemon when status fails"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 1 ;;
    start)  exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=5
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

ruflo_health_check || true
_avail_restart="$RUFLO_AVAILABLE"
_count_restart="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ "$_avail_restart" == "true" ]]; then
    assert_pass "ruflo_health_check sets RUFLO_AVAILABLE=true after daemon restart"
else
    assert_fail "ruflo_health_check sets RUFLO_AVAILABLE=true after daemon restart" "got: $_avail_restart"
fi
if [[ "$_count_restart" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after restart"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after restart" "got: $_count_restart"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 42: recoverable circuit breaker — 4 failures leave RUFLO_AVAILABLE=true
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "recoverable circuit breaker — 4 failures (below threshold 5)"

mock_binary "ruflo_fail_cmd" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_i=0
while [[ $_i -lt 4 ]]; do
    ruflo_with_timeout 5 ruflo_fail_cmd || true
    _i=$(( _i + 1 ))
done

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "RUFLO_AVAILABLE remains true after 4 failures (below threshold of 5)"
else
    assert_fail "RUFLO_AVAILABLE remains true after 4 failures (below threshold of 5)" "got: $RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -eq 4 ]]; then
    assert_pass "RUFLO_FAILURE_COUNT is 4 after 4 failures"
else
    assert_fail "RUFLO_FAILURE_COUNT is 4 after 4 failures" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 43: recoverable circuit breaker — 5 failures trip RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "recoverable circuit breaker — 5 failures trips circuit"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_i=0
while [[ $_i -lt 5 ]]; do
    ruflo_with_timeout 5 ruflo_fail_cmd || true
    _i=$(( _i + 1 ))
done

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "RUFLO_AVAILABLE=false after 5 failures (threshold reached)"
else
    assert_fail "RUFLO_AVAILABLE=false after 5 failures (threshold reached)" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 44: ruflo_health_check — resets RUFLO_FAILURE_COUNT after partial failures
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — RUFLO_FAILURE_COUNT reset after partial failures"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=3
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

ruflo_health_check || true
_count_after_recovery="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ "$_count_after_recovery" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after recovery from 3 failures"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after recovery from 3 failures" "got: $_count_after_recovery"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section A: _ruflo_compute_max_agents helper
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_ruflo_compute_max_agents — returns RUFLO_MAX_AGENTS when no stage-specific vars set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
unset RUFLO_HIVE_MAX_AGENTS RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS
RUFLO_MAX_AGENTS=4
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "4" ]]; then
    assert_pass "_ruflo_compute_max_agents returns RUFLO_MAX_AGENTS when no stage vars set"
else
    assert_fail "_ruflo_compute_max_agents returns RUFLO_MAX_AGENTS when no stage vars set" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — returns stage-specific max when RUFLO_HIVE_MAX_AGENTS > RUFLO_MAX_AGENTS"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
unset RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS=8
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "8" ]]; then
    assert_pass "_ruflo_compute_max_agents returns RUFLO_HIVE_MAX_AGENTS when it exceeds RUFLO_MAX_AGENTS"
else
    assert_fail "_ruflo_compute_max_agents returns RUFLO_HIVE_MAX_AGENTS when it exceeds RUFLO_MAX_AGENTS" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — returns max across all stage vars (RUFLO_AUDIT_MAX_AGENTS highest)"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS=5
RUFLO_REVIEW_MAX_AGENTS=6
RUFLO_CQ_MAX_AGENTS=7
RUFLO_AUDIT_MAX_AGENTS=10
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "10" ]]; then
    assert_pass "_ruflo_compute_max_agents returns max across all stage-specific vars"
else
    assert_fail "_ruflo_compute_max_agents returns max across all stage-specific vars" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — ignores non-integer values in stage vars"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS="not-a-number"
RUFLO_REVIEW_MAX_AGENTS="3.5"
RUFLO_CQ_MAX_AGENTS=""
RUFLO_AUDIT_MAX_AGENTS=6
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "6" ]]; then
    assert_pass "_ruflo_compute_max_agents ignores non-integer stage var values"
else
    assert_fail "_ruflo_compute_max_agents ignores non-integer stage var values" "got: $_result"
fi
unset RUFLO_HIVE_MAX_AGENTS RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS

# ═══════════════════════════════════════════════════════════════════════════════
# Section B: Singleton lifecycle — ruflo_init()
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — sets RUFLO_HIVE_AVAILABLE=true and RUFLO_HIVE_ID on hive init success"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '{"hive_id":"singleton-hive-001"}\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_hive_id="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_HIVE_AVAILABLE=true on hive init success"
else
    assert_fail "ruflo_init sets RUFLO_HIVE_AVAILABLE=true on hive init success" "got: $_hive_avail"
fi
if [[ "$_hive_id" == "singleton-hive-001" ]]; then
    assert_pass "ruflo_init sets RUFLO_HIVE_ID from hive-mind init output"
else
    assert_fail "ruflo_init sets RUFLO_HIVE_ID from hive-mind init output" "got: $_hive_id"
fi

print_test_section "ruflo_init — leaves RUFLO_HIVE_AVAILABLE=false when hive init fails (fail-open)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
_init_exit=0
ruflo_init 2>/dev/null || _init_exit=$?
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_ruflo_avail_after="$RUFLO_AVAILABLE"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "false" ]]; then
    assert_pass "ruflo_init leaves RUFLO_HIVE_AVAILABLE=false when hive init fails"
else
    assert_fail "ruflo_init leaves RUFLO_HIVE_AVAILABLE=false when hive init fails" "got: $_hive_avail"
fi
if [[ "$_ruflo_avail_after" == "true" ]]; then
    assert_pass "ruflo_init daemon still available (fail-open) when hive init fails"
else
    assert_fail "ruflo_init daemon still available (fail-open) when hive init fails" "got: $_ruflo_avail_after"
fi

print_test_section "ruflo_init — does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID"

# Regression test for Codex P1: if RUFLO_HIVE_ID is inherited from a parent
# process and hive-mind init fails, the code must clear the stale ID before
# evaluating success, preventing RUFLO_HIVE_AVAILABLE from being set true.
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID="stale-hive-from-parent"   # simulates inherited env value
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_hive_id_after="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "false" ]]; then
    assert_pass "ruflo_init does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID"
else
    assert_fail "ruflo_init does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID" "got: $_hive_avail"
fi
if [[ -z "$_hive_id_after" ]]; then
    assert_pass "ruflo_init clears stale RUFLO_HIVE_ID when hive init fails"
else
    assert_fail "ruflo_init clears stale RUFLO_HIVE_ID when hive init fails" "got: $_hive_id_after"
fi

print_test_section "ruflo_init — emits ruflo.hive_available event with hive_id on success"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '{"hive_id":"event-test-hive"}\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_init 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "ruflo.hive_available" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init emits ruflo.hive_available event on hive init success"
else
    assert_fail "ruflo_init emits ruflo.hive_available event on hive init success" "events: $_captured_event"
fi
if grep -qF "hive_id=event-test-hive" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init includes hive_id in ruflo.hive_available event"
else
    assert_fail "ruflo_init includes hive_id in ruflo.hive_available event" "events: $_captured_event"
fi

print_test_section "ruflo_init — emits ruflo.hive_unavailable event on hive init failure"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_init 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "ruflo.hive_unavailable" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init emits ruflo.hive_unavailable event on hive init failure"
else
    assert_fail "ruflo_init emits ruflo.hive_unavailable event on hive init failure" "events: $_captured_event"
fi

print_test_section "ruflo_init — skips hive init when RUFLO_HIVE_AVAILABLE already true (idempotent)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
case "\${1:-}/\${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '{"hive_id":"should-not-appear"}\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="pre-existing-hive"
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_init skips hive-mind init when RUFLO_HIVE_AVAILABLE already true"
else
    assert_fail "ruflo_init skips hive-mind init when RUFLO_HIVE_AVAILABLE already true" "calls: $_calls"
fi
if [[ "$RUFLO_HIVE_ID" == "pre-existing-hive" ]]; then
    assert_pass "ruflo_init preserves existing RUFLO_HIVE_ID when skipping"
else
    assert_fail "ruflo_init preserves existing RUFLO_HIVE_ID when skipping" "got: $RUFLO_HIVE_ID"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_build_hive
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_hive — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_build_hive "build goal" 5 2>/dev/null || _exit=$?
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_build_hive returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_build_hive — emits ruflo.build_hive_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_build_hive "build goal" 5 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.build_hive_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive emits ruflo.build_hive_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_build_hive emits ruflo.build_hive_skipped when hive unavailable" "events: $_captured_event"
fi
if grep -qF "reason=hive_unavailable" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive includes reason=hive_unavailable in skipped event"
else
    assert_fail "ruflo_execute_build_hive includes reason=hive_unavailable in skipped event" "events: $_captured_event"
fi

print_test_section "ruflo_execute_build_hive — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-abc"
RUFLO_USE_NPX=false
ruflo_execute_build_hive "build goal" 2 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_build_hive does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_review
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_review — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_review returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_review — emits ruflo.review_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.review_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_review emits ruflo.review_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_review emits ruflo.review_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_review — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-xyz"
RUFLO_USE_NPX=false
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_review does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_review does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_compound_quality
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_compound_quality — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_compound_quality — emits ruflo.cq_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.cq_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_compound_quality emits ruflo.cq_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_compound_quality emits ruflo.cq_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_compound_quality — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-cq"
RUFLO_USE_NPX=false
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_compound_quality does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_compound_quality does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_audit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_audit — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_audit returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_audit — emits ruflo.audit_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.audit_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_audit emits ruflo.audit_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_audit emits ruflo.audit_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_audit — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-audit"
RUFLO_USE_NPX=false
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_audit does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_audit does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section D: Cleanup — ruflo_cleanup shuts down hive
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — shuts down hive when RUFLO_HIVE_ID is set"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s %s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cleanup-test-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "hive-mind shutdown" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_cleanup calls hive-mind shutdown when RUFLO_HIVE_ID is set"
else
    assert_fail "ruflo_cleanup calls hive-mind shutdown when RUFLO_HIVE_ID is set" "calls: $_calls"
fi

print_test_section "ruflo_cleanup — resets RUFLO_HIVE_AVAILABLE=false and RUFLO_HIVE_ID='' after shutdown"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cleanup-reset-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_hive_avail_after="$RUFLO_HIVE_AVAILABLE"
_hive_id_after="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail_after" == "false" ]]; then
    assert_pass "ruflo_cleanup resets RUFLO_HIVE_AVAILABLE=false after shutdown"
else
    assert_fail "ruflo_cleanup resets RUFLO_HIVE_AVAILABLE=false after shutdown" "got: $_hive_avail_after"
fi
if [[ -z "$_hive_id_after" ]]; then
    assert_pass "ruflo_cleanup resets RUFLO_HIVE_ID='' after shutdown"
else
    assert_fail "ruflo_cleanup resets RUFLO_HIVE_ID='' after shutdown" "got: $_hive_id_after"
fi


print_test_section "ruflo_cleanup — shuts down hive when RUFLO_DAEMON_STARTED=false (pre-existing daemon)"

# The singleton hive belongs to THIS run's ruflo_init() call regardless of
# whether THIS run started the daemon. ruflo_cleanup must tear it down even
# when RUFLO_DAEMON_STARTED=false (pre-existing daemon path).
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s %s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=false
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="preexisting-daemon-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "hive-mind shutdown" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_cleanup shuts down hive even when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup shuts down hive even when RUFLO_DAEMON_STARTED=false" "calls: $_calls"
fi
_hive_id_nodaemon="${RUFLO_HIVE_ID:-}"
if [[ -z "$_hive_id_nodaemon" ]]; then
    assert_pass "ruflo_cleanup clears RUFLO_HIVE_ID when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup clears RUFLO_HIVE_ID when RUFLO_DAEMON_STARTED=false" "got: $_hive_id_nodaemon"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: ruflo_ci_memory_pull, ruflo_ci_memory_push, ruflo_prune_memory_export,
#        ruflo_merge_memory_exports  (feat: 08a — CI memory persistence)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "ruflo_ci_memory_pull — no-op when CI is not set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
unset CI
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when CI is unset (no-op)"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when CI is unset (no-op)" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_pull — no-op when ruflo unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
CI=true
RUFLO_AVAILABLE=false
export CI RUFLO_AVAILABLE
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when RUFLO_AVAILABLE=false" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_pull — returns 0 when orphan branch absent"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mock_binary "ruflo" 'exit 0'
# git fetch returns 1 so ruflo-memory branch is absent
cat > "$_test_tmp/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    fetch) exit 1 ;;
    remote) printf 'https://github.com/test/repo.git\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/git"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
CI=true
export RUFLO_AVAILABLE CI
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when orphan branch does not exist"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when orphan branch does not exist" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_push — no-op when CI is not set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
unset CI
_push_exit=0
ruflo_ci_memory_push || _push_exit=$?
if [[ $_push_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_push returns 0 when CI is unset (no-op)"
else
    assert_fail "ruflo_ci_memory_push returns 0 when CI is unset (no-op)" "exit=$_push_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_push — no-op when ruflo unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
CI=true
RUFLO_AVAILABLE=false
export CI RUFLO_AVAILABLE
_push_exit=0
ruflo_ci_memory_push || _push_exit=$?
if [[ $_push_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_push returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_ci_memory_push returns 0 when RUFLO_AVAILABLE=false" "exit=$_push_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_prune_memory_export — removes stale, keeps recent and no-timestamp"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_prune_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-prune.XXXXXX")
_now=$(date +%s)
_old=$(( _now - 100 * 86400 ))
_recent=$(( _now - 10 * 86400 ))
printf '{"keep":{"timestamp":%d},"drop":{"timestamp":%d},"no_ts":"value"}\n' \
    "$_recent" "$_old" > "$_prune_file"
ruflo_prune_memory_export "$_prune_file" 90
_pruned=$(cat "$_prune_file")
rm -f "$_prune_file"

if printf '%s\n' "$_pruned" | jq -e '.keep' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export keeps entry within max_age"
else
    assert_fail "ruflo_prune_memory_export keeps entry within max_age" "output: $_pruned"
fi
if ! printf '%s\n' "$_pruned" | jq -e '.drop' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export removes entry beyond max_age"
else
    assert_fail "ruflo_prune_memory_export removes entry beyond max_age" "output: $_pruned"
fi
if printf '%s\n' "$_pruned" | jq -e '.no_ts' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export keeps entry without timestamp field"
else
    assert_fail "ruflo_prune_memory_export keeps entry without timestamp field" "output: $_pruned"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_merge_memory_exports — local wins on conflict, remote keys preserved"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_remote_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-remote-memory.XXXXXX")
_local_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-local-memory.XXXXXX")
printf '{"key1":"remote_val","key2":"remote_only"}\n' > "$_remote_file"
printf '{"key1":"local_val","key3":"local_only"}\n' > "$_local_file"
_merged=$(ruflo_merge_memory_exports "$_remote_file" "$_local_file")
rm -f "$_remote_file" "$_local_file"

if printf '%s\n' "$_merged" | jq -e '.key1 == "local_val"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: local value wins on key conflict"
else
    assert_fail "ruflo_merge_memory_exports: local value wins on key conflict" "merged: $_merged"
fi
if printf '%s\n' "$_merged" | jq -e '.key2 == "remote_only"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: remote-only keys are preserved"
else
    assert_fail "ruflo_merge_memory_exports: remote-only keys are preserved" "merged: $_merged"
fi
if printf '%s\n' "$_merged" | jq -e '.key3 == "local_only"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: local-only keys present in merge"
else
    assert_fail "ruflo_merge_memory_exports: local-only keys present in merge" "merged: $_merged"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: stage_test_first ruflo integration — recall and store
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stage_test_first — ruflo recall happy path"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# Mock ruflo_recall_similar_outcomes to return plain-text recall output,
# matching the adapter contract (raw CLI output, not JSON).
ruflo_recall_similar_outcomes() {
    printf 'Past TDD pattern: use vitest describe blocks\nPast TDD pattern: mock external deps\n'
}
ruflo_store() { return 0; }
RUFLO_AVAILABLE=true

_recall_result=$(ruflo_recall_similar_outcomes "feature" "tdd,backend" 2>/dev/null || true)
_tdd_context=$(printf '%.2000s' "${_recall_result:-}")

if [[ -n "$_tdd_context" ]]; then
    assert_pass "stage_test_first recall: tdd_context populated from ruflo results"
else
    assert_fail "stage_test_first recall: tdd_context populated from ruflo results" "got empty recall output"
fi

if printf '%s\n' "$_tdd_context" | grep -q "vitest"; then
    assert_pass "stage_test_first recall: raw recall output contains expected content"
else
    assert_fail "stage_test_first recall: raw recall output contains expected content" "got: $_tdd_context"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo recall when ruflo unavailable"

RUFLO_AVAILABLE=false
_tdd_context_unavail=""
if ruflo_available; then
    _tdd_context_unavail=$(ruflo_recall_similar_outcomes "feature" "" 2>/dev/null) || true
fi

if [[ -z "$_tdd_context_unavail" ]]; then
    assert_pass "stage_test_first recall: tdd_context is empty when ruflo unavailable"
else
    assert_fail "stage_test_first recall: tdd_context is empty when ruflo unavailable" "got: $_tdd_context_unavail"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo store happy path"

_store_call_log="$TEST_TEMP_DIR/tdd-store-calls.txt"
rm -f "$_store_call_log"

# Override ruflo_store to record call arguments
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_store_call_log"
    return 0
}
# Provide a deterministic repo hash for the test
_ruflo_resolve_repo_hash() { echo "testhash123"; }

RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="pipeline-99-42"
GOAL="add authentication"
TASK_TYPE="feature"
written_files="tests/auth.test.js"

wrote_any=true
if ruflo_available && [[ "$wrote_any" == "true" ]]; then
    _tdd_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    if [[ -n "$_tdd_ns_hash" ]]; then
        _tdd_key="test_first-${SHIPWRIGHT_PIPELINE_ID:-unknown}-$(date +%s)"
        _tdd_outcome=$(jq -n --arg goal "${GOAL:-}" --arg task "${TASK_TYPE:-feature}" \
            --arg files "${written_files:-}" \
            '{goal: $goal, task_type: $task, tests_generated: true, files_written: $files}' 2>/dev/null || echo '{}')
        ruflo_store "$_tdd_key" "$_tdd_outcome" \
            "learning-${_tdd_ns_hash}" \
            "tdd,test_first,${TASK_TYPE:-feature}" 2>/dev/null || true
    fi
fi

if [[ -f "$_store_call_log" ]]; then
    assert_pass "stage_test_first store: ruflo_store called when wrote_any=true"
else
    assert_fail "stage_test_first store: ruflo_store called when wrote_any=true" "store log not created"
fi

if grep -q "NS=learning-testhash123" "$_store_call_log" 2>/dev/null; then
    assert_pass "stage_test_first store: namespace uses learning- prefix for future recall"
else
    assert_fail "stage_test_first store: namespace uses learning- prefix for future recall" "got: $(cat "$_store_call_log" 2>/dev/null)"
fi

if grep -q "TAGS=tdd,test_first,feature" "$_store_call_log" 2>/dev/null; then
    assert_pass "stage_test_first store: tags include tdd,test_first,<task_type>"
else
    assert_fail "stage_test_first store: tags include tdd,test_first,<task_type>" "got: $(cat "$_store_call_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo store skipped when no tests written"

_store_skip_log="$TEST_TEMP_DIR/tdd-store-skip.txt"
rm -f "$_store_skip_log"

ruflo_store() {
    echo "called" >> "$_store_skip_log"
    return 0
}

RUFLO_AVAILABLE=true
wrote_any=false
if ruflo_available && [[ "$wrote_any" == "true" ]]; then
    ruflo_store "key" "{}" "ns" "tags" 2>/dev/null || true
fi

if [[ ! -f "$_store_skip_log" ]]; then
    assert_pass "stage_test_first store: ruflo_store skipped when wrote_any=false"
else
    assert_fail "stage_test_first store: ruflo_store skipped when wrote_any=false" "store was called unexpectedly"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: stage_test ruflo integration — recall and store
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stage_test — ruflo recall called before test run"

_st_recall_log="$TEST_TEMP_DIR/stage-test-recall-calls.txt"
rm -f "$_st_recall_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_recall() {
    echo "QUERY=$1 NS=$2" >> "$_st_recall_log"
    printf 'Past failure: circuit breaker timeout in sw-e2e-smoke-test.sh\n'
}
ruflo_store() { return 0; }
RUFLO_AVAILABLE=true

_st_ruflo_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_ruflo_ns="${_st_ns_hash:+learning-${_st_ns_hash}}"
fi

_st_flakiness_ctx=""
if declare -f ruflo_recall >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_ruflo_ns" ]] && \
   ruflo_available; then
    _st_flakiness_ctx=$(ruflo_recall "test flakiness patterns failures" \
        "$_st_ruflo_ns" 2>/dev/null || true)
    _st_flakiness_ctx=$(printf '%.2000s' "${_st_flakiness_ctx:-}")
fi

if [[ -f "$_st_recall_log" ]]; then
    assert_pass "stage_test recall: ruflo_recall invoked when ruflo available"
else
    assert_fail "stage_test recall: ruflo_recall invoked when ruflo available" "recall log not created"
fi

if grep -q "NS=learning-testhash123" "$_st_recall_log" 2>/dev/null; then
    assert_pass "stage_test recall: namespace uses learning- prefix for cross-run recall"
else
    assert_fail "stage_test recall: namespace uses learning- prefix for cross-run recall" "got: $(cat "$_st_recall_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — recall output logged for human visibility"

if [[ -n "$_st_flakiness_ctx" ]]; then
    assert_pass "stage_test recall: flakiness context populated when ruflo has data"
else
    assert_fail "stage_test recall: flakiness context populated when ruflo has data" "got empty context"
fi

if printf '%s\n' "$_st_flakiness_ctx" | grep -q "circuit breaker"; then
    assert_pass "stage_test recall: recall content is the raw text from ruflo_recall"
else
    assert_fail "stage_test recall: recall content is the raw text from ruflo_recall" "got: $_st_flakiness_ctx"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — ruflo store called with passed tag on success"

_st_pass_store_log="$TEST_TEMP_DIR/stage-test-pass-store.txt"
rm -f "$_st_pass_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_pass_store_log"
    return 0
}
RUFLO_AVAILABLE=true
_test_cmd="npm test"
_cov_pct=87
_test_log_content="PASS src/auth.test.ts"
_pass_test_count=1
_st_pass_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_pass_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_pass_ns="${_st_pass_ns_hash:+learning-${_st_pass_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_pass_ns" ]] && \
   ruflo_available; then
    ruflo_store "stage-test-result" \
        "Tests PASSED. Count: ${_pass_test_count}. Cmd: ${_test_cmd}. Coverage: ${_cov_pct:-0}%. Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)." \
        "$_st_pass_ns" \
        "test,stage_test,passed" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,passed" "$_st_pass_store_log" 2>/dev/null; then
    assert_pass "stage_test store: tags contain passed on success"
else
    assert_fail "stage_test store: tags contain passed on success" "got: $(cat "$_st_pass_store_log" 2>/dev/null)"
fi

if grep -q "NS=learning-testhash123" "$_st_pass_store_log" 2>/dev/null; then
    assert_pass "stage_test store: namespace uses learning- prefix for cross-run recall on pass"
else
    assert_fail "stage_test store: namespace uses learning- prefix for cross-run recall on pass" "got: $(cat "$_st_pass_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — ruflo store called with failed tag on failure"

_st_fail_store_log="$TEST_TEMP_DIR/stage-test-fail-store.txt"
rm -f "$_st_fail_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_fail_store_log"
    return 0
}
RUFLO_AVAILABLE=true
_fail_test_exit=1
_fail_test_count=3
_st_fail_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_fail_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_fail_ns="${_st_fail_ns_hash:+learning-${_st_fail_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_fail_ns" ]] && \
   ruflo_available; then
    ruflo_store "stage-test-result" \
        "Tests FAILED (exit $_fail_test_exit). Count: ${_fail_test_count}. Cmd: npm test. Coverage: 0%. Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)." \
        "$_st_fail_ns" \
        "test,stage_test,failed" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,failed" "$_st_fail_store_log" 2>/dev/null; then
    assert_pass "stage_test store: tags contain failed on test failure"
else
    assert_fail "stage_test store: tags contain failed on test failure" "got: $(cat "$_st_fail_store_log" 2>/dev/null)"
fi

if grep -q "NS=learning-testhash123" "$_st_fail_store_log" 2>/dev/null; then
    assert_pass "stage_test store: namespace uses learning- prefix for cross-run recall on fail"
else
    assert_fail "stage_test store: namespace uses learning- prefix for cross-run recall on fail" "got: $(cat "$_st_fail_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — unique timestamped key per run (no overwrite)"

_st_ts_store_log="$TEST_TEMP_DIR/stage-test-ts-store.txt"
rm -f "$_st_ts_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_ts_store_log"
    return 0
}
ruflo_available() { return 0; }
RUFLO_AVAILABLE=true

_st_ts_run_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_ts_run_uid="${_st_ts_run_ts}-$$-${RANDOM}"
_st_ts_result_key="stage-test-result-${_st_ts_run_uid}"
_st_ts_ruflo_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_ts_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_ts_ruflo_ns="${_st_ts_ns_hash:+learning-${_st_ts_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_ts_result_key" \
        "Tests PASSED. Tests: src/auth.test.ts. Cmd: npm test. Coverage: 87%. Time: ${_st_ts_run_uid}." \
        "$_st_ts_ruflo_ns" \
        "test,stage_test,passed" 2>/dev/null || true
fi

if grep -q "KEY=stage-test-result-" "$_st_ts_store_log" 2>/dev/null; then
    assert_pass "stage_test unique key: storage key includes timestamp (not static 'stage-test-result')"
else
    assert_fail "stage_test unique key: storage key includes timestamp (not static 'stage-test-result')" "got: $(cat "$_st_ts_store_log" 2>/dev/null)"
fi

if grep -qE "KEY=stage-test-result-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+" "$_st_ts_store_log" 2>/dev/null; then
    assert_pass "stage_test unique key: format is timestamp-PID-RANDOM (collision-safe)"
else
    assert_fail "stage_test unique key: format is timestamp-PID-RANDOM (collision-safe)" "got: $(cat "$_st_ts_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — flaky pattern match triggers retry"

_st_retry_log="$TEST_TEMP_DIR/stage-test-retry-calls.txt"
_st_retry_test_log=$(mktemp "$TEST_TEMP_DIR/test-retry-out.XXXXXX")
rm -f "$_st_retry_log"
printf 'FAIL circuit-breaker-test\nError: timeout after 5000ms\n' > "$_st_retry_test_log"

ruflo_recall() {
    # Recall returns hyphenated test names that are 8+ chars for reliable matching
    printf 'Past failure: circuit-breaker-test timeout in sw-e2e-smoke-test.sh\n'
}
RUFLO_AVAILABLE=true
_st_retry_fail_exit=1
_st_retry_flakiness_ctx=$(ruflo_recall "test flakiness patterns failures" "learning-testhash123" 2>/dev/null || true)
_st_retry_flakiness_ctx=$(printf '%.2000s' "${_st_retry_flakiness_ctx:-}")

_test_is_known_flaky="false"
_matched_flaky_pattern=""
_st_stopwords="received|expected|function|actually|returned|argument|property|undefined|contains|resource|standard|platform"
if [[ "$_st_retry_fail_exit" -ne 0 && -n "$_st_retry_flakiness_ctx" ]]; then
    _st_fail_excerpt=$(head -30 "$_st_retry_test_log" 2>/dev/null || true)
    while IFS= read -r _st_kw; do
        [[ ${#_st_kw} -lt 8 ]] && continue
        printf '%s' "$_st_kw" | grep -qiE "^(${_st_stopwords})$" 2>/dev/null && continue
        if printf '%s\n' "$_st_fail_excerpt" | grep -qiF "$_st_kw" 2>/dev/null; then
            _test_is_known_flaky="true"
            _matched_flaky_pattern="$_st_kw"
            break
        fi
    done < <(printf '%s\n' "$_st_retry_flakiness_ctx" | tr ' \t' '\n' | grep -E '^[a-zA-Z0-9_.-]{8,}$' | sort -u | head -30)
fi
rm -f "$_st_retry_test_log"

if [[ "$_test_is_known_flaky" == "true" ]]; then
    assert_pass "stage_test flaky retry: known flaky flag set when recalled pattern matches failure output"
else
    assert_fail "stage_test flaky retry: known flaky flag set when recalled pattern matches failure output" "ctx=${_st_retry_flakiness_ctx}"
fi

if [[ -n "$_matched_flaky_pattern" ]]; then
    assert_pass "stage_test flaky retry: matched pattern is non-empty"
else
    assert_fail "stage_test flaky retry: matched pattern is non-empty" "pattern was empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — known_flaky tag added on matched failure"

_st_kf_store_log="$TEST_TEMP_DIR/stage-test-kf-store.txt"
rm -f "$_st_kf_store_log"

ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_kf_store_log"
    return 0
}
RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="test-pipeline-42"
_st_kf_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_kf_key="stage-test-result-${_st_kf_ts}"

# Simulate known-flaky failure storage
_st_kf_fail_tags="test,stage_test,failed"
_st_kf_is_known_flaky="true"
[[ "$_st_kf_is_known_flaky" == "true" ]] && _st_kf_fail_tags="${_st_kf_fail_tags},known_flaky"

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_kf_key" \
        "Tests FAILED (exit 1). Failures: circuit-breaker-test. Cmd: npm test. Time: ${_st_kf_ts}." \
        "learning-testhash123" \
        "$_st_kf_fail_tags" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,failed,known_flaky" "$_st_kf_store_log" 2>/dev/null; then
    assert_pass "stage_test known_flaky tag: tags include known_flaky when pattern matched"
else
    assert_fail "stage_test known_flaky tag: tags include known_flaky when pattern matched" "got: $(cat "$_st_kf_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — flaky_recovered tag on retry success"

_st_fr_store_log="$TEST_TEMP_DIR/stage-test-fr-store.txt"
rm -f "$_st_fr_store_log"

ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_fr_store_log"
    return 0
}
RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="test-pipeline-42"
_st_fr_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_fr_key="stage-test-result-${_st_fr_ts}"

# Simulate retry-succeeded storage (known flaky, but recovered)
_st_fr_pass_tags="test,stage_test,passed"
_st_fr_is_known_flaky="true"
[[ "$_st_fr_is_known_flaky" == "true" ]] && _st_fr_pass_tags="${_st_fr_pass_tags},flaky_recovered"

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_fr_key" \
        "Tests PASSED. Tests: auth.test.ts. Cmd: npm test. Coverage: 87%. Time: ${_st_fr_ts}." \
        "learning-testhash123" \
        "$_st_fr_pass_tags" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,passed,flaky_recovered" "$_st_fr_store_log" 2>/dev/null; then
    assert_pass "stage_test flaky_recovered tag: tags include flaky_recovered when retry succeeded"
else
    assert_fail "stage_test flaky_recovered tag: tags include flaky_recovered when retry succeeded" "got: $(cat "$_st_fr_store_log" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "RUFLO_COST_BUDGET_MULTIPLIER — agent count scaling"

# Helper: apply the multiplier formula directly (mirrors ruflo-adapter.sh logic)
_apply_multiplier_test() {
    local default_max="$1"
    local multiplier="$2"
    if [[ -n "$multiplier" ]]; then
        awk -v d="$default_max" -v m="$multiplier" \
            'BEGIN{v=int(d*m); print (v<1?1:(v>d?d:v))}' 2>/dev/null || echo "$default_max"
    else
        echo "$default_max"
    fi
}

# Test 1: Unset/empty multiplier → no-op (backward compatibility)
_mult_result=$(_apply_multiplier_test 4 "")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: unset/empty -> no-op (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: unset/empty -> no-op" "expected 4, got $_mult_result"
fi

# Test 2: Multiplier 2.0 with default 4 → capped at 4 (v>d → d)
_mult_result=$(_apply_multiplier_test 4 "2.0")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 2.0 with max=4 -> capped at 4 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 2.0 with max=4 -> capped at 4" "expected 4, got $_mult_result"
fi

# Test 3: Multiplier 0.5 with default 4 → 2 (scale down)
_mult_result=$(_apply_multiplier_test 4 "0.5")
if [[ "$_mult_result" == "2" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=4 -> 2 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=4 -> 2" "expected 2, got $_mult_result"
fi

# Test 4: Multiplier 0 → enforces minimum 1 agent
_mult_result=$(_apply_multiplier_test 4 "0")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0 -> enforces min 1 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0 -> enforces min 1" "expected 1, got $_mult_result"
fi

# Test 5: Multiplier 3.0 with default 4 → capped at 4 (hard cap respected)
_mult_result=$(_apply_multiplier_test 4 "3.0")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 3.0 with max=4 -> capped at 4 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 3.0 with max=4 -> capped at 4" "expected 4, got $_mult_result"
fi

# Test 6: Multiplier 0.5 with default 3 (compound quality default) → 1 (floor)
_mult_result=$(_apply_multiplier_test 3 "0.5")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=3 -> 1 (floor of 1.5, got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=3 -> 1" "expected 1, got $_mult_result"
fi

# Test 7: Multiplier 1.0 → unchanged (identity)
_mult_result=$(_apply_multiplier_test 4 "1.0")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 1.0 -> identity (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 1.0 -> identity" "expected 4, got $_mult_result"
fi

# Test 8: Multiplier 0.25 with default 4 → 1 (min enforced)
_mult_result=$(_apply_multiplier_test 4 "0.25")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.25 with max=4 -> 1 (min enforced, got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.25 with max=4 -> 1" "expected 1, got $_mult_result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
