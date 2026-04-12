#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-quality-checks test — Unit tests for quality     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-quality-checks Tests"

setup_test_env "sw-lib-pipeline-quality-checks-test"
_test_cleanup_hook() { cleanup_test_env; }

# Set up quality checks env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export SCRIPT_DIR="$SCRIPT_DIR"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export BASE_BRANCH="main"
export ISSUE_NUMBER="42"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline-config.json"
export TEST_CMD=""
export GOAL="Test goal"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT"

# Provide stubs (redirect to /dev/null so result=$(...) captures only the echoed value)
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
emit_event() { :; }
# _timeout is normally from compat.sh (sourced by sw-pipeline.sh); stub it here
_timeout() { shift; "$@"; }

# parse_coverage_from_output is used by quality_check_coverage - stub it
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    grep -oE '[0-9]{1,3}\.[0-9]*|[0-9]{1,3}' "$log_file" 2>/dev/null | head -1 || true
}

# detect_test_cmd used by run_e2e_validation
detect_test_cmd() { echo ""; }

# Minimal pipeline config
echo '{"stages":[{"id":"test","config":{"coverage_min":0}}]}' > "$PIPELINE_CONFIG"

# Source compat.sh for file_mtime() and date_to_epoch() used by pipeline_artifact_is_fresh()
source "$SCRIPT_DIR/lib/compat.sh"

# Source the lib (clear guard)
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# run_test_coverage_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_test_coverage_check"

# No TEST_CMD → skip
unset TEST_CMD
result=$(run_test_coverage_check 2>/dev/null)
assert_eq "No TEST_CMD returns skip" "skip" "$result"

# TEST_CMD that outputs coverage (function echoes the percentage at end)
export TEST_CMD="echo 'Statements : 85% coverage'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from Jest/Istanbul format" "85" "$result"

# Alternative format - coverage: XX%
export TEST_CMD="echo 'coverage: 90%'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from coverage format" "90" "$result"

# Failing test command
export TEST_CMD="false"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Failing test returns 0" "0" "$result"

# Cached coverage from test stage — skips running TEST_CMD
echo '{"coverage_pct": 75}' > "$ARTIFACTS_DIR/test-coverage.json"
export TEST_CMD="exit 1"  # would fail if actually run
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Returns cached coverage without running tests" "75" "$result"

# Invalid cache value falls back to running TEST_CMD
echo '{"coverage_pct": "bad"}' > "$ARTIFACTS_DIR/test-coverage.json"
export TEST_CMD="echo 'coverage: 60%'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Invalid cache falls back to running tests" "60" "$result"

rm -f "$ARTIFACTS_DIR/test-coverage.json"

# ═══════════════════════════════════════════════════════════════════════════════
# run_e2e_validation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_e2e_validation"

rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/e2e-validation.log"

# No test-results.log and passing TEST_CMD → runs and passes
export TEST_CMD="echo ok"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation passes when no log and TEST_CMD succeeds"
else
    assert_fail "run_e2e_validation: no log, passing cmd"
fi

# No test-results.log and failing TEST_CMD → runs and fails
rm -f "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="exit 1"
if run_e2e_validation 2>/dev/null; then
    assert_fail "run_e2e_validation: no log, failing cmd should fail"
else
    assert_pass "run_e2e_validation fails when no log and TEST_CMD fails"
fi

# Passing test-results.log → skips re-run (TEST_CMD would fail if run)
echo "10 tests passed, 0 failures" > "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="exit 1"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation skips re-run when log shows passing"
else
    assert_fail "run_e2e_validation: passing log should skip re-run"
fi

# Failing test-results.log → re-runs TEST_CMD
echo "1 failed" > "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="echo ok"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation re-runs when log shows failures"
else
    assert_fail "run_e2e_validation: failing log should re-run tests"
fi

rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/e2e-validation.log"

# ═══════════════════════════════════════════════════════════════════════════════
# run_bash_compat_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_bash_compat_check"

mock_git
# With mock_git (no changed .sh files), returns 0
cd "$PROJECT_ROOT"
result=$(run_bash_compat_check 2>/dev/null | tail -1)
cd - >/dev/null
assert_eq "No changed .sh files returns 0" "0" "${result:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
# run_new_function_test_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_new_function_test_check"

cd "$PROJECT_ROOT"
result=$(run_new_function_test_check 2>/dev/null)
assert_eq "No new functions in diff returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# run_atomic_write_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_atomic_write_check"

cd "$PROJECT_ROOT"
result=$(run_atomic_write_check 2>/dev/null)
assert_eq "No state/config changes returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_coverage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_coverage"

# No test-results.log → skip (returns 0)
rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes when no test log"
else
    assert_fail "quality_check_coverage"
fi

# Create test-results.log with coverage
echo "Statements : 82.5%
Lines : 80%
Test Results: 10 passed" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes with coverage data"
else
    assert_fail "quality_check_coverage"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_security
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_security"

cd "$PROJECT_ROOT"
rm -f package.json requirements.txt Cargo.toml pyproject.toml
if quality_check_security 2>/dev/null; then
    assert_pass "quality_check_security skips when no audit tool"
else
    assert_fail "quality_check_security"
fi
assert_file_exists "Creates security-audit.log" "$ARTIFACTS_DIR/security-audit.log"
content=$(cat "$ARTIFACTS_DIR/security-audit.log")
assert_contains "Audit log has content" "$content" "No audit tool"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_bundle_size
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_bundle_size"

cd "$PROJECT_ROOT"
rm -rf dist build out .next target
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size skips when no build dir"
else
    assert_fail "quality_check_bundle_size"
fi
cd - >/dev/null

# With build dir
mkdir -p "$PROJECT_ROOT/dist"
echo "mock bundle content" > "$PROJECT_ROOT/dist/bundle.js"
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size passes with build dir"
else
    assert_fail "quality_check_bundle_size"
fi
assert_file_exists "Creates bundle-metrics.log" "$ARTIFACTS_DIR/bundle-metrics.log"

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_perf_regression
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_perf_regression"

rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression skips without test log"
else
    assert_fail "quality_check_perf_regression"
fi

echo "passed in 12.34s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression with duration"
else
    assert_fail "quality_check_perf_regression"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_test_status / pipeline_test_passed
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_test_status / pipeline_test_passed"

# Test 1: Sidecar passing
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
result=$(pipeline_test_status 2>/dev/null)
assert_eq "pipeline_test_status returns 0 when sidecar passed" "0" "$result"
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed exits 0 when sidecar passed"
else
    assert_fail "pipeline_test_passed should exit 0 when sidecar shows pass"
fi

# Test 2: Sidecar failing
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
result=$(pipeline_test_status 2>/dev/null)
assert_eq "pipeline_test_status returns 1 when sidecar failed" "1" "$result"
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should exit non-zero when sidecar shows fail"
else
    assert_pass "pipeline_test_passed exits non-zero when sidecar failed"
fi

# Test 3: Sidecar missing
rm -f "$ARTIFACTS_DIR/test-results.status.json"
if pipeline_test_status 2>/dev/null; then
    assert_fail "pipeline_test_status should exit non-zero when sidecar missing"
else
    assert_pass "pipeline_test_status exits non-zero when sidecar missing"
fi
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should exit non-zero when sidecar missing"
else
    assert_pass "pipeline_test_passed exits non-zero when sidecar missing"
fi

# Test 4: Regression test — sidecar with noisy log (Terminated: 15, no pass markers)
# This is the exact false-positive from the issue: log has noise but sidecar says pass
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
echo "Running tests...
Test 1: PASS
Test 2: PASS
Terminated: 15
Cleanup done" > "$ARTIFACTS_DIR/test-results.log"
# DoD logic should detect pass via sidecar (not grep)
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed uses sidecar even with noisy log"
else
    assert_fail "pipeline_test_passed should trust sidecar over noisy log"
fi

# Test 5: Regression test — sidecar wins over FAIL substring (Processing FAIL_SAFE_MODE.md)
# Another false-positive: log contains "FAIL" as substring but sidecar says pass
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
echo "Processing FAIL_SAFE_MODE.md
Running tests...
All tests passed
Exit code: 0" > "$ARTIFACTS_DIR/test-results.log"
# DoD logic should detect pass via sidecar (not grep false-positive on FAIL_SAFE)
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed ignores FAIL substring in filenames"
else
    assert_fail "pipeline_test_passed should trust sidecar over FAIL substring"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_artifact_is_fresh / freshness-aware pipeline_test_status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_artifact_is_fresh / freshness-aware pipeline_test_status"

_FRESH_EPOCH="$(date +%s)"

# ── F1: Backward compat — PIPELINE_RUN_EPOCH=0 bypasses freshness check ──────
PIPELINE_RUN_EPOCH=0
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "PIPELINE_RUN_EPOCH=0: stale sidecar reads through (pass-through)" "1" "$_fresh_result"

# ── F2: Fresh sidecar via finished_at >= epoch ────────────────────────────────
PIPELINE_RUN_EPOCH="$(( _FRESH_EPOCH - 300 ))"   # epoch = 5 min ago
_NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
rm -f "$ARTIFACTS_DIR/test-results.status.json"
printf '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"%s"}\n' \
    "$_NOW_ISO" > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null)
assert_eq "Fresh sidecar (finished_at >= epoch): returns exit code" "0" "$_fresh_result"

# ── F3: Stale sidecar via finished_at < epoch — treated as missing ────────────
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now; "2026-04-11" is yesterday
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Stale sidecar (finished_at < epoch): treated as missing, no output" "" "$_fresh_result"
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should return non-zero for stale sidecar"
else
    assert_pass "pipeline_test_passed rejects stale sidecar"
fi

# ── F4: THE BUG — stale failing sidecar must not produce AUDIT:FAIL ──────────
# Prior to fix: exit_code:1 from old run leaked into DoD → false AUDIT:FAIL
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Bug: stale failing sidecar returns empty (not '1'), prevents AUDIT:FAIL" "" "$_fresh_result"

# ── F5: No finished_at field — falls back to mtime; new file = fresh ──────────
PIPELINE_RUN_EPOCH="$(( _FRESH_EPOCH - 300 ))"   # epoch = 5 min ago
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
# file was just created → mtime >= epoch → fresh
_fresh_result=$(pipeline_test_status 2>/dev/null)
assert_eq "No finished_at: newly-created file is fresh via mtime fallback" "0" "$_fresh_result"

# ── F6: No finished_at field, old mtime — stale via mtime fallback ────────────
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
# Set mtime to a date far in the past (Jan 1, 2026 00:00)
touch -t "202601010000.00" "$ARTIFACTS_DIR/test-results.status.json" 2>/dev/null || true
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "No finished_at: old mtime file is stale" "" "$_fresh_result"

# ── F7: Upgrade compat — resume with old state (PIPELINE_RUN_EPOCH unset) ─────
# Simulates a resumed pipeline from a state file written before this fix.
# PIPELINE_RUN_EPOCH will be empty → treated as 0 → pass-through (no false rejection).
unset PIPELINE_RUN_EPOCH
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Upgrade compat: unset PIPELINE_RUN_EPOCH reads sidecar (pass-through)" "0" "$_fresh_result"

# Restore to safe default
export PIPELINE_RUN_EPOCH=0

print_test_results
