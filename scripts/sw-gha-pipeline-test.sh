#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-gha-pipeline-test — Static validation of shipwright-pipeline.yml     ║
# ║  Tests for Phase 1: log artifact upload + npm cache                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"

print_test_header "GHA Pipeline Workflow: Phase 1 — Log Artifact + npm Cache"

# ─── npm cache ─────────────────────────────────────────────────────────────

# Confirm a cache step restoring ~/.npm exists
NPM_CACHE_BLOCK=$(awk '/Restore npm cache/{found=1} found{print; if(/^\s*$/ && NR>1) exit}' "$WORKFLOW" 2>/dev/null || true)

assert_contains \
    "npm cache restore step present" \
    "$(grep -c 'Restore npm cache' "$WORKFLOW" || echo 0)" \
    "1"

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

assert_contains \
    "upload-artifact step present" \
    "$(grep -c 'upload-artifact' "$WORKFLOW" || echo 0)" \
    "1"

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

# The upload step must appear before "Propagate pipeline exit code"
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
INSTALL_CLAUDE_LINE=$(grep -n '^\s*- name: Install Claude Code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$NPM_CACHE_LINE" -gt 0 && "$INSTALL_CLAUDE_LINE" -gt 0 && "$NPM_CACHE_LINE" -lt "$INSTALL_CLAUDE_LINE" ]]; then
    assert_pass "npm cache step appears before Install Claude Code"
else
    assert_fail "npm cache step appears before Install Claude Code" \
        "(cache line=$NPM_CACHE_LINE, install line=$INSTALL_CLAUDE_LINE)"
fi

echo ""
print_test_results
