#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-gha-pipeline-test — Static validation of shipwright-pipeline.yml     ║
# ║  Tests for Phase 1-3: log artifact, npm cache, step ordering, persistence ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"

print_test_header "GHA Pipeline Workflow: Phases 1-3 — Observability, Ordering, Persistence"

# ─── npm cache ─────────────────────────────────────────────────────────────

NPM_CACHE_COUNT=$(grep -c 'Restore npm cache' "$WORKFLOW" || true)
assert_eq \
    "npm cache restore step present" \
    "1" "$NPM_CACHE_COUNT"

assert_contains_regex \
    "npm cache uses actions/cache@v4" \
    "$(grep -A5 'Restore npm cache' "$WORKFLOW" || true)" \
    "actions/cache@v4"

assert_contains_regex \
    "npm cache path is ~/.npm" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "path:.*~/.npm"

assert_contains_regex \
    "npm cache key includes hashFiles on workflow file (global tools, not package-lock.json)" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "hashFiles.*shipwright-pipeline\.yml"

assert_contains_regex \
    "npm cache key includes runner.os" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "runner\.os"

assert_contains_regex \
    "npm cache has restore-keys fallback" \
    "$(grep -A12 'Restore npm cache' "$WORKFLOW" || true)" \
    "restore-keys:"

# ─── upload-artifact ────────────────────────────────────────────────────────

UPLOAD_COUNT=$(grep -c 'upload-artifact' "$WORKFLOW" || true)
assert_eq \
    "upload-artifact step present" \
    "1" "$UPLOAD_COUNT"

assert_contains_regex \
    "upload-artifact uses v4" \
    "$(grep 'upload-artifact' "$WORKFLOW" || true)" \
    "upload-artifact@v4"

assert_contains_regex \
    "upload-artifact if-condition has always() and claim_check skip guard" \
    "$(grep -B3 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "always\(\).*claim_check.*skip"

assert_contains_regex \
    "upload-artifact skips when claim_check skips" \
    "$(grep -B3 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "claim_check\.outputs\.skip"

assert_contains_regex \
    "upload-artifact includes pipeline.log" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "/tmp/pipeline\.log"

assert_contains_regex \
    "upload-artifact includes pipeline-artifacts dir" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "\.claude/pipeline-artifacts"

assert_contains_regex \
    "upload-artifact includes events.jsonl" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "events\.jsonl"

assert_contains_regex \
    "upload-artifact warns on missing files" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "if-no-files-found:.*warn"

assert_contains_regex \
    "upload-artifact has retention-days" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "retention-days:"

assert_contains_regex \
    "upload-artifact has continue-on-error" \
    "$(grep -A18 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "continue-on-error: true"

# ─── ordering: upload before exit-code propagation ──────────────────────────

UPLOAD_LINE=$(grep -n 'upload-artifact@v4' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
EXITCODE_LINE=$(grep -n 'Propagate pipeline exit code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$UPLOAD_LINE" -gt 0 && "$EXITCODE_LINE" -gt 0 && "$UPLOAD_LINE" -lt "$EXITCODE_LINE" ]]; then
    assert_pass "upload-artifact appears before exit-code propagation step"
else
    assert_fail "upload-artifact appears before exit-code propagation step" \
        "(upload line=$UPLOAD_LINE, exitcode line=$EXITCODE_LINE)"
fi

# ─── ordering: npm cache before Install Claude Code ─────────────────────────

NPM_CACHE_LINE=$(grep -n 'Restore npm cache' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
INSTALL_CLAUDE_LINE=$(grep -nE '^[[:space:]]*- name: Install Claude Code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$NPM_CACHE_LINE" -gt 0 && "$INSTALL_CLAUDE_LINE" -gt 0 && "$NPM_CACHE_LINE" -lt "$INSTALL_CLAUDE_LINE" ]]; then
    assert_pass "npm cache step appears before Install Claude Code"
else
    assert_fail "npm cache step appears before Install Claude Code" \
        "(cache line=$NPM_CACHE_LINE, install line=$INSTALL_CLAUDE_LINE)"
fi

# ─── Phase 2: early-exit ordering — auth probe and claim lock before expensive install ─

# Install Claude Code before Pre-flight auth check (auth probe needs claude CLI)
INSTALL_CLAUDE_LINE2=$(grep -nE '^[[:space:]]*- name: Install Claude Code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
AUTH_PROBE_LINE=$(grep -nE '^[[:space:]]*- name: Pre-flight auth check' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$INSTALL_CLAUDE_LINE2" -gt 0 && "$AUTH_PROBE_LINE" -gt 0 && "$INSTALL_CLAUDE_LINE2" -lt "$AUTH_PROBE_LINE" ]]; then
    assert_pass "Install Claude Code appears before Pre-flight auth check"
else
    assert_fail "Install Claude Code appears before Pre-flight auth check" \
        "(claude line=$INSTALL_CLAUDE_LINE2, auth line=$AUTH_PROBE_LINE)"
fi

# Pre-flight auth check before Install system dependencies
INSTALL_DEPS_LINE=$(grep -nE '^[[:space:]]*- name: Install system dependencies' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$AUTH_PROBE_LINE" -gt 0 && "$INSTALL_DEPS_LINE" -gt 0 && "$AUTH_PROBE_LINE" -lt "$INSTALL_DEPS_LINE" ]]; then
    assert_pass "Pre-flight auth check appears before Install system dependencies"
else
    assert_fail "Pre-flight auth check appears before Install system dependencies" \
        "(auth line=$AUTH_PROBE_LINE, deps line=$INSTALL_DEPS_LINE)"
fi

# Check claim lock before Install system dependencies
CLAIM_LOCK_LINE=$(grep -nE '^[[:space:]]*- name: Check claim lock' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$CLAIM_LOCK_LINE" -gt 0 && "$INSTALL_DEPS_LINE" -gt 0 && "$CLAIM_LOCK_LINE" -lt "$INSTALL_DEPS_LINE" ]]; then
    assert_pass "Check claim lock appears before Install system dependencies"
else
    assert_fail "Check claim lock appears before Install system dependencies" \
        "(claim line=$CLAIM_LOCK_LINE, deps line=$INSTALL_DEPS_LINE)"
fi

# Install system dependencies has skip guard condition
assert_contains_regex \
    "Install system dependencies has claim_check skip guard" \
    "$(grep -A2 'Install system dependencies' "$WORKFLOW" || true)" \
    "claim_check.*skip"

echo ""

# ─── Phase 3: Consolidate ruflo persistence ─────────────────────────────────

RUFLO_CACHE_KEY_COUNT=$(grep -c 'ruflo-memory-' "$WORKFLOW" || true)
assert_eq \
    "ruflo-memory- cache key removed (no actions/cache steps for ruflo)" \
    "0" "$RUFLO_CACHE_KEY_COUNT"

RUFLO_CACHE_PATH_COUNT=$(grep -c '\.claude-flow/data/' "$WORKFLOW" || true)
assert_eq \
    ".claude-flow/data/ cache path removed from workflow (ruflo manages dir itself)" \
    "0" "$RUFLO_CACHE_PATH_COUNT"

ENSURE_DIR_COUNT=$(grep -c 'Ensure ruflo memory cache dir exists' "$WORKFLOW" || true)
assert_eq \
    "Ensure ruflo memory cache dir exists step removed" \
    "0" "$ENSURE_DIR_COUNT"

assert_contains_regex \
    "ruflo orphan-branch restore (ruflo_ci_memory_pull) still present" \
    "$(grep 'ruflo_ci_memory_pull' "$WORKFLOW" || true)" \
    "ruflo_ci_memory_pull"

assert_contains_regex \
    "ruflo orphan-branch save (ruflo_ci_memory_push) still present" \
    "$(grep 'ruflo_ci_memory_push' "$WORKFLOW" || true)" \
    "ruflo_ci_memory_push"

echo ""
print_test_results
