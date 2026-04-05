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

exit_code=0
ruflo_init || exit_code=$?

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
export RUFLO_AVAILABLE

exit_code=0
ruflo_with_timeout 1 ruflo_slow_cmd || exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_with_timeout returns non-zero on command failure"
else
    assert_fail "ruflo_with_timeout returns non-zero on command failure"
fi

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_with_timeout sets RUFLO_AVAILABLE=false on failure (circuit-break)"
else
    assert_fail "ruflo_with_timeout sets RUFLO_AVAILABLE=false on failure (circuit-break)" "got: $RUFLO_AVAILABLE"
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
RUFLO_USE_NPX=false

exit_code=0
ruflo_store "test-key" "test-value" "test-ns" || exit_code=$?

# ruflo_store is fail-open — must return 0 even when ruflo binary fails
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store returns 0 (fail-open) when ruflo binary fails"
else
    assert_fail "ruflo_store returns 0 (fail-open) when ruflo binary fails" "exit_code=$exit_code"
fi

# After a failure, RUFLO_AVAILABLE should be false (circuit-breaker tripped)
if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_store circuit-breaker disables ruflo after failure"
else
    assert_fail "ruflo_store circuit-breaker disables ruflo after failure" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
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
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "build the feature" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 when agent command fails"
else
    assert_fail "ruflo_execute_build_single returns 1 when agent command fails" "exit_code=$exit_code"
fi
if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_execute_build_single circuit-breaker disables ruflo after agent failure"
else
    assert_fail "ruflo_execute_build_single circuit-breaker disables ruflo after agent failure" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
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

_test_tmp=$(mktemp -d)
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_outcome_file="$_test_tmp/outcome.json"
printf '{"issue_type":"backend","stage":"build","skills":"tdd","outcome":"success"}\n' \
    > "$_outcome_file"

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
PATH="$_test_tmp:$PATH"
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
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on success with valid file"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on success with valid file" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 30: ruflo_learn_from_shipwright — success path with raw JSON string input
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — success path (raw JSON input)"

_test_tmp=$(mktemp -d)
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
PATH="$_test_tmp:$PATH"
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
rm -rf "$_test_tmp"
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
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "init" ]]; then
    printf '{"hive_id":"test-hive-123"}\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
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
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "init" ]]; then
    printf '{"hive_id":"test-hive-456"}\n'
    exit 0
fi
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
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "init" ]]; then
    printf '{"hive_id":"review-hive-789"}\n'
    exit 0
fi
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
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "init" ]]; then
    printf '{"hive_id":"cq-hive-999"}\n'
    exit 0
fi
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
print_test_results
