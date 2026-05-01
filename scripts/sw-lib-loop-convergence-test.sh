#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/loop-convergence test — Stuckness throttle (issue #447)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Verifies that detect_stuckness() throttles ruflo_store / ruflo_recall by
# fingerprinting (signals, reasons) and skipping subprocess spawns when the
# fingerprint matches the prior detection. emit_event and warn must fire on
# every detection regardless of throttle (observability is non-negotiable).
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: loop-convergence stuckness throttle (#447)"

setup_test_env "sw-lib-loop-convergence-test"
_test_cleanup_hook() { cleanup_test_env; }

# ── Counter files (mocks may run in $(...) subshells — file counters survive) ─
STORE_CALLS="$TEST_TEMP_DIR/store-calls.txt"
RECALL_CALLS="$TEST_TEMP_DIR/recall-calls.txt"
EMIT_CALLS="$TEST_TEMP_DIR/emit-calls.txt"
WARN_CALLS="$TEST_TEMP_DIR/warn-calls.txt"
: > "$STORE_CALLS"; : > "$RECALL_CALLS"; : > "$EMIT_CALLS"; : > "$WARN_CALLS"
export STORE_CALLS RECALL_CALLS EMIT_CALLS WARN_CALLS

# ── Required env for detect_stuckness ─────────────────────────────────────────
export PROJECT_ROOT="$TEST_TEMP_DIR"
export LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"
export STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"
export ITERATION=5
export MAX_ITERATIONS=20
export STUCKNESS_COUNT=0
export STUCKNESS_DIAGNOSIS=""
export STUCKNESS_HINT=""
export REPO_HASH="testrepo"
export TEST_PASSED="false"
export AUDIT_RESULT=""

# ── Mock external functions ──────────────────────────────────────────────────
emit_event() { printf '%s\n' "$*" >> "$EMIT_CALLS"; }
warn()       { printf '%s\n' "$*" >> "$WARN_CALLS"; }
info()       { :; }
success()    { :; }
error()      { :; }
ruflo_store() {
    # signature: ruflo_store <key> <value> <namespace> <tags>
    printf 'STORE: key=%s value=%s\n' "${1:-}" "${2:-}" >> "$STORE_CALLS"
    return 0
}
ruflo_recall() {
    # signature: ruflo_recall <query> <namespace>
    printf 'RECALL: query=%s ns=%s\n' "${1:-}" "${2:-}" >> "$RECALL_CALLS"
    echo "MOCK_RECALL_PAYLOAD"
    return 0
}
QUALITY_GATE_PASSED() { return 1; }

# ── Source the module under test (fresh load) ────────────────────────────────
_LOOP_CONVERGENCE_LOADED=""
unset _STUCKNESS_RECALL_CACHE _STUCKNESS_RECALL_CACHE_FP || true
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/loop-convergence.sh"

# Helper: count lines in a counter file (handles missing file as 0)
_count() { wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# Helper: write a tracking-file fixture that triggers ≥2 stuckness signals.
#   Args: $1 = number of identical lines, $2 = error hash (use "none" to skip Signal 3)
_write_fixture() {
    local n="${1:-5}"
    local err="${2:-deadbeef}"
    : > "$STUCKNESS_TRACKING_FILE"
    local i
    for ((i = 0; i < n; i++)); do
        printf '%s|%s|1\n' "abchash" "$err" >> "$STUCKNESS_TRACKING_FILE"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1 — first detection writes fingerprint and calls store + recall once
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Test 1: first detection fires both ruflo calls"

_write_fixture 5 deadbeef
detect_stuckness > /dev/null 2>&1 || true

_t1_store=$(_count "$STORE_CALLS")
_t1_recall=$(_count "$RECALL_CALLS")
assert_eq "Test 1: ruflo_store fired exactly once on first detection" "1" "$_t1_store"
assert_eq "Test 1: ruflo_recall fired exactly once on first detection" "1" "$_t1_recall"

if [[ -f "$LOG_DIR/.last-stuckness-fingerprint" ]]; then
    _t1_fp=$(cat "$LOG_DIR/.last-stuckness-fingerprint")
    if [[ "${#_t1_fp}" -eq 12 ]] && [[ "$_t1_fp" =~ ^[0-9a-f]+$ ]]; then
        assert_pass "Test 1: fingerprint file contains 12-char hex string"
    else
        assert_fail "Test 1: fingerprint file contains 12-char hex string" "got: '$_t1_fp' (len=${#_t1_fp})"
    fi
else
    assert_fail "Test 1: fingerprint file written" "missing $LOG_DIR/.last-stuckness-fingerprint"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2 — second detection with identical signals → throttled
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Test 2: identical detection skips ruflo_store and reuses cache"

# Same fixture, advance iteration counter (key embeds iter, but fingerprint must not).
export ITERATION=6
detect_stuckness > /dev/null 2>&1 || true

_t2_store=$(_count "$STORE_CALLS")
_t2_recall=$(_count "$RECALL_CALLS")
assert_eq "Test 2: ruflo_store NOT called again (still 1 total)" "1" "$_t2_store"
assert_eq "Test 2: ruflo_recall NOT called again (cache hit, still 1 total)" "1" "$_t2_recall"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3 — detection with changed reasons → throttle re-arms
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Test 3: changed reasons re-fires store + recall"

# Switch error hash to "none" → Signal 3 ("same error in last 3 iterations") drops out.
# Reasons array changes → fingerprint changes → both calls fire again.
_write_fixture 5 none
export ITERATION=7
_t3_fp_before=$(cat "$LOG_DIR/.last-stuckness-fingerprint" 2>/dev/null || echo "")
detect_stuckness > /dev/null 2>&1 || true

_t3_store=$(_count "$STORE_CALLS")
_t3_recall=$(_count "$RECALL_CALLS")
assert_eq "Test 3: ruflo_store fired again on changed reasons (now 2 total)" "2" "$_t3_store"
assert_eq "Test 3: ruflo_recall fired again on changed reasons (now 2 total)" "2" "$_t3_recall"

_t3_fp_after=$(cat "$LOG_DIR/.last-stuckness-fingerprint" 2>/dev/null || echo "")
if [[ -n "$_t3_fp_after" ]] && [[ "$_t3_fp_after" != "$_t3_fp_before" ]]; then
    assert_pass "Test 3: fingerprint file updated after reasons change"
else
    assert_fail "Test 3: fingerprint file updated after reasons change" "before='$_t3_fp_before' after='$_t3_fp_after'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4 — fingerprint file deleted (simulates session restart wiping LOG_DIR)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Test 4: missing fingerprint file fails open (both calls fire)"

# Wipe both the on-disk fingerprint AND the in-process recall cache, since a
# real restart loses both.
rm -f "$LOG_DIR/.last-stuckness-fingerprint"
_STUCKNESS_RECALL_CACHE=""
_STUCKNESS_RECALL_CACHE_FP=""
export ITERATION=8
# Keep same fixture from Test 3 (fingerprint will be identical to Test 3 result),
# but missing file means we cannot detect that — fail-open path must fire.
detect_stuckness > /dev/null 2>&1 || true

_t4_store=$(_count "$STORE_CALLS")
_t4_recall=$(_count "$RECALL_CALLS")
assert_eq "Test 4: ruflo_store fired on missing fingerprint (fail-open, now 3)" "3" "$_t4_store"
assert_eq "Test 4: ruflo_recall fired on missing fingerprint (fail-open, now 3)" "3" "$_t4_recall"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5 — emit_event and warn fire every detection regardless of throttle
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Test 5: observability calls fire every iteration"

_t5_emit=$(_count "$EMIT_CALLS")
_t5_warn=$(_count "$WARN_CALLS")
# We invoked detect_stuckness 4 times across Tests 1-4; observability must be 4.
assert_eq "Test 5: emit_event fired on every detection (4 total)" "4" "$_t5_emit"
assert_eq "Test 5: warn fired on every detection (4 total)" "4" "$_t5_warn"

# Emit explicit "$PASS/$TOTAL pass" as the final visible line for DoD audit parsers.
printf '%s/%s pass\n' "$PASS" "$TOTAL"
print_test_results
