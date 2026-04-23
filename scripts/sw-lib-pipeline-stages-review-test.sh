#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright detect_plan_drift — Unit tests for cross-stage drift detector ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: detect_plan_drift Tests"

setup_test_env "sw-lib-pipeline-stages-review-test"
_test_cleanup_hook() { cleanup_test_env; }

# Ensure jq works
[[ -x /usr/bin/jq ]] && cp -f /usr/bin/jq "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true

# ─── Setup a real git repo with main + feature branch ─────────────────────
PROJ="$TEST_TEMP_DIR/project"
mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/.claude/pipeline-artifacts"
ARTIFACTS_DIR="$PROJ/.claude/pipeline-artifacts"
BASE_BRANCH="main"
export BASE_BRANCH

# Initialize main with a baseline commit (nothing changed yet)
(
    cd "$PROJ"
    git init -q -b main 2>/dev/null || (git init -q && git checkout -q -b main 2>/dev/null) || git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add -A
    git commit -q -m "init"
)

# Create feature branch to simulate pipeline work
(
    cd "$PROJ"
    git checkout -q -b feat/test-drift 2>/dev/null || true
)

# ─── Source dependencies ───────────────────────────────────────────────────
emit_event() { :; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }

source "$SCRIPT_DIR/lib/helpers.sh"
_PIPELINE_STAGES_REVIEW_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stages-review.sh"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: happy path — one planned file not modified"
# ═══════════════════════════════════════════════════════════════════════════════

# Plan lists 2 files; only one will be committed on the feature branch
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Implementation Plan

## Files to Modify

- `src/auth.js` — Add JWT validation logic
- `src/config.js` — Update configuration defaults

## Task Checklist
- [ ] Implement auth
PLAN

# Commit only auth.js on the feature branch (config.js is unmodified)
(
    cd "$PROJ"
    echo "// auth" > src/auth.js
    git add src/auth.js
    git commit -q -m "feat: add auth"
)

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for untouched planned file" "$result" "[DRIFT-WARNING] Planned file not modified: src/config.js"
if echo "$result" | grep -q "src/auth.js"; then
    assert_fail "No false positive for modified file" "src/auth.js appeared in drift warnings"
else
    assert_pass "No false positive for modified planned file"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: no drift — all planned files modified"
# ═══════════════════════════════════════════════════════════════════════════════

# Commit the second planned file too
(
    cd "$PROJ"
    echo "// config" > src/config.js
    git add src/config.js
    git commit -q -m "feat: add config"
)

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No drift warnings when all planned files modified"
else
    assert_fail "Should have no drift warnings" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — plan.md missing"
# ═══════════════════════════════════════════════════════════════════════════════

rm -f "$ARTIFACTS_DIR/plan.md"
result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when plan.md missing (fail-open)"
else
    assert_fail "Should return empty when plan.md missing" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — no Files to Modify section"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Implementation Plan

## Problem Analysis
Just a description, no files section here.

## Task Checklist
- [ ] Do something
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when no Files to Modify section (fail-open)"
else
    assert_fail "Should return empty when section missing" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — invalid project_root (git fails)"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — something

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "/nonexistent/path/xyz/no/git" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when git fails (fail-open)"
else
    assert_fail "Should return empty when git fails" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: multiple planned files, partial drift"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — already modified (committed earlier)
- `src/config.js` — already modified (committed earlier)
- `src/missing-feature.js` — not implemented yet
- `tests/missing-feature.test.js` — test not written

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for first missing file" "$result" "src/missing-feature.js"
assert_contains "Drift warning for second missing file" "$result" "tests/missing-feature.test.js"

missing_count=$(echo "$result" | grep -c '\[DRIFT-WARNING\]' || true)
if [[ "${missing_count:-0}" -eq 2 ]]; then
    assert_pass "Exactly 2 drift warnings for 2 unmodified planned files"
else
    assert_fail "Expected 2 drift warnings" "got ${missing_count:-0}"
fi

print_test_results
