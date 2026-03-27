#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-state test — Unit tests for pipeline state      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-state Tests"

setup_test_env "sw-lib-pipeline-state-test"
_test_cleanup_hook() { cleanup_test_env; }

# Set up pipeline env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export STATE_FILE="$TEST_TEMP_DIR/state.md"
export TASKS_FILE="$TEST_TEMP_DIR/pipeline-tasks.md"
export ISSUE_NUMBER=""
export NO_GITHUB=true
export PIPELINE_CONFIG=""
export CI_MODE=false
export PIPELINE_NAME="test-pipeline"
export GOAL="Test goal"
export GITHUB_ISSUE=""
export GIT_BRANCH=""
export TASK_TYPE=""
export PR_NUMBER=""
export PROGRESS_COMMENT_ID=""
export PIPELINE_START_EPOCH=""
export CURRENT_STAGE=""
export PIPELINE_STATUS=""
export STAGE_STATUSES=""
export STAGE_TIMINGS=""
export LOG_ENTRIES=""

mkdir -p "$ARTIFACTS_DIR"
mock_git

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
format_duration() {
    local secs="${1:-0}"
    if [[ "$secs" -ge 3600 ]]; then echo "$((secs/3600))h$((secs%3600/60))m"
    elif [[ "$secs" -ge 60 ]]; then echo "$((secs/60))m$((secs%60))s"
    else echo "${secs}s"; fi
}
write_state() { :; }
gh_build_progress_body() { echo "progress"; }
gh_update_progress() { :; }
gh_comment_issue() { :; }
ci_post_stage_event() { :; }
template_for_type() { echo "standard"; }

# Source the lib
_PIPELINE_STATE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-state.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# save_artifact
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "save_artifact"

save_artifact "test.txt" "hello world"
assert_file_exists "Artifact created" "$ARTIFACTS_DIR/test.txt"
content=$(cat "$ARTIFACTS_DIR/test.txt")
assert_eq "Artifact content correct" "hello world" "$content"

save_artifact "data.json" '{"key":"value"}'
if jq empty "$ARTIFACTS_DIR/data.json" 2>/dev/null; then
    assert_pass "JSON artifact is valid"
else
    assert_fail "JSON artifact is valid"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# get_stage_status / set_stage_status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Stage status management"

STAGE_STATUSES=""

# Initially empty
result=$(get_stage_status "build")
assert_eq "No status initially" "" "$result"

# Set and get
set_stage_status "build" "running"
result=$(get_stage_status "build")
assert_eq "Build status is running" "running" "$result"

# Set another stage
set_stage_status "test" "pending"
result=$(get_stage_status "test")
assert_eq "Test status is pending" "pending" "$result"

# Build status unchanged
result=$(get_stage_status "build")
assert_eq "Build still running" "running" "$result"

# Update existing
set_stage_status "build" "complete"
result=$(get_stage_status "build")
assert_eq "Build updated to complete" "complete" "$result"

# Test stage unchanged
result=$(get_stage_status "test")
assert_eq "Test still pending" "pending" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Stage timing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Stage timing"

STAGE_TIMINGS=""

# No timing → empty
result=$(get_stage_timing "build")
assert_eq "No timing initially" "" "$result"

# Record start and end
STAGE_TIMINGS=""
epoch_now=$(now_epoch)
STAGE_TIMINGS="build_start:$((epoch_now - 65))"
STAGE_TIMINGS="${STAGE_TIMINGS}
build_end:$epoch_now"
result=$(get_stage_timing "build")
assert_contains "Timing shows duration" "$result" "m"

# get_stage_timing_seconds
result=$(get_stage_timing_seconds "build")
assert_eq "Build took ~65 seconds" "65" "$result"

# Stage with only start (in-progress)
STAGE_TIMINGS="test_start:$((epoch_now - 10))"
result=$(get_stage_timing_seconds "test")
if [[ "$result" -ge 9 && "$result" -le 15 ]]; then
    assert_pass "In-progress stage timing (~${result}s)"
else
    assert_fail "In-progress stage timing" "got: $result"
fi

# Unknown stage → 0
result=$(get_stage_timing_seconds "unknown")
assert_eq "Unknown stage → 0 seconds" "0" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# get_stage_description (static fallbacks)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "get_stage_description"

assert_contains "intake description" "$(get_stage_description intake)" "requirements"
assert_contains "plan description" "$(get_stage_description plan)" "plan"
assert_contains "build description" "$(get_stage_description build)" "code"
assert_contains "test description" "$(get_stage_description test)" "test"
assert_contains "review description" "$(get_stage_description review)" "review"
assert_contains "pr description" "$(get_stage_description pr)" "pull request"
assert_contains "merge description" "$(get_stage_description merge)" "Merg"
assert_contains "deploy description" "$(get_stage_description deploy)" "Deploy"
assert_contains "monitor description" "$(get_stage_description monitor)" "monitor"
assert_eq "Unknown stage → empty" "" "$(get_stage_description unknown_stage)"

# ═══════════════════════════════════════════════════════════════════════════════
# verify_stage_artifacts
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "verify_stage_artifacts"

# Plan stage requires plan.md
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_fail "Plan stage fails without plan.md"
else
    assert_pass "Plan stage fails without plan.md"
fi

echo "Plan content" > "$ARTIFACTS_DIR/plan.md"
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_pass "Plan stage passes with plan.md"
else
    assert_fail "Plan stage passes with plan.md"
fi

# Design stage requires design.md AND plan.md
if verify_stage_artifacts "design" 2>/dev/null; then
    assert_fail "Design stage fails without design.md"
else
    assert_pass "Design stage fails without design.md"
fi

echo "Design content" > "$ARTIFACTS_DIR/design.md"
if verify_stage_artifacts "design" 2>/dev/null; then
    assert_pass "Design stage passes with both artifacts"
else
    assert_fail "Design stage passes with both artifacts"
fi

# Build stage — no artifacts required
if verify_stage_artifacts "build" 2>/dev/null; then
    assert_pass "Build stage always passes (no artifacts)"
else
    assert_fail "Build stage always passes (no artifacts)"
fi

# Empty file should fail
echo -n "" > "$ARTIFACTS_DIR/plan.md"
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_fail "Empty plan.md should fail"
else
    assert_pass "Empty plan.md fails verification"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# record_stage_effectiveness / get_stage_self_awareness_hint
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Stage effectiveness tracking"

export STAGE_EFFECTIVENESS_FILE="$TEST_TEMP_DIR/effectiveness.jsonl"
rm -f "$STAGE_EFFECTIVENESS_FILE"

record_stage_effectiveness "build" "complete"
assert_file_exists "Effectiveness file created" "$STAGE_EFFECTIVENESS_FILE"

content=$(cat "$STAGE_EFFECTIVENESS_FILE")
assert_contains "Has stage" "$content" '"stage":"build"'
assert_contains "Has outcome" "$content" '"outcome":"complete"'
assert_contains "Has timestamp" "$content" '"ts":'

# Hint when many failures
rm -f "$STAGE_EFFECTIVENESS_FILE"
for i in $(seq 1 5); do
    record_stage_effectiveness "build" "failed"
done
hint=$(get_stage_self_awareness_hint "build" 2>/dev/null)
assert_contains "Hint for failed builds" "$hint" "build"

# Hint for plan failures
rm -f "$STAGE_EFFECTIVENESS_FILE"
for i in $(seq 1 5); do
    record_stage_effectiveness "plan" "failed"
done
hint=$(get_stage_self_awareness_hint "plan" 2>/dev/null)
assert_contains "Hint for failed plans" "$hint" "plan"

# No hint when mostly successful
rm -f "$STAGE_EFFECTIVENESS_FILE"
# shellcheck disable=SC2034
for i in $(seq 1 8); do
    record_stage_effectiveness "test" "complete"
done
record_stage_effectiveness "test" "failed"
hint=$(get_stage_self_awareness_hint "test" 2>/dev/null)
assert_eq "No hint when mostly successful" "" "$hint"

# ═══════════════════════════════════════════════════════════════════════════════
# log_stage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "log_stage"

LOG_ENTRIES=""
log_stage "build" "started implementation"
assert_contains "Log entry has stage" "$LOG_ENTRIES" "build"
assert_contains "Log entry has message" "$LOG_ENTRIES" "started implementation"

log_stage "test" "all tests passed"
assert_contains "Second log entry" "$LOG_ENTRIES" "all tests passed"

# ═══════════════════════════════════════════════════════════════════════════════
# initialize_state
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "initialize_state"

# Override write_state to capture state
_write_state_called=false
write_state() { _write_state_called=true; }

initialize_state
assert_eq "Pipeline status set to running" "running" "$PIPELINE_STATUS"
if [[ -n "$STARTED_AT" ]]; then
    assert_pass "Started timestamp set"
else
    assert_fail "Started timestamp set"
fi
assert_eq "Stage statuses cleared" "" "$STAGE_STATUSES"
assert_eq "Log entries cleared" "" "$LOG_ENTRIES"
if [[ "$_write_state_called" == "true" ]]; then
    assert_pass "write_state called during init"
else
    assert_fail "write_state called during init"
fi

# initialize_state clears TASKS_FILE (prevent stale context injection on new run)
echo "# Stale tasks from issue #99" > "$TASKS_FILE"
initialize_state
if [[ ! -f "$TASKS_FILE" ]]; then
    assert_pass "initialize_state clears pipeline-tasks.md"
else
    assert_fail "initialize_state clears pipeline-tasks.md" "file still exists after init"
fi

# initialize_state is safe when TASKS_FILE is unset
_saved_tasks_file="$TASKS_FILE"
unset TASKS_FILE
initialize_state
assert_pass "initialize_state safe when TASKS_FILE unset"
export TASKS_FILE="$_saved_tasks_file"

# ═══════════════════════════════════════════════════════════════════════════════
# resume_state — stale pipeline-tasks.md cleared when issue doesn't match
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "resume_state stale tasks cleanup"

# Provide stubs needed by resume_state
gh_init() { :; }
load_pipeline_config() { :; }

_write_state_resume() { :; }
write_state() { _write_state_resume; }

# Build a minimal state file for issue #42
cat > "$STATE_FILE" <<'_RESUME_STATE_'
---
pipeline: test-pipeline
goal: "Resume test goal"
status: interrupted
issue: "#42"
branch: "feat/test-42"
current_stage: build
started_at: 2024-01-01T00:00:00Z
test_cmd: "echo pass"
pr_number:
progress_comment_id:
stages:
  intake: complete
  plan: complete
---

## Log
### intake
Goal: Resume test goal
_RESUME_STATE_

# Case 1: tasks file has a DIFFERENT issue → should be removed on resume
cat > "$TASKS_FILE" <<'_STALE_TASKS_'
# Pipeline Tasks — old run

## Context

- Pipeline: autonomous
- Branch: feat/build-loop-context-exhaustion-prevention-154
- Issue: #154
_STALE_TASKS_

GITHUB_ISSUE="" GIT_BRANCH=""
resume_state 2>/dev/null || true
if [[ ! -f "$TASKS_FILE" ]]; then
    assert_pass "resume_state removes stale pipeline-tasks.md (different issue)"
else
    assert_fail "resume_state removes stale pipeline-tasks.md (different issue)" "file still exists"
fi

# Case 2: tasks file matches current pipeline issue → should be preserved
cat > "$STATE_FILE" <<'_RESUME_STATE2_'
---
pipeline: test-pipeline
goal: "Resume test goal"
status: interrupted
issue: "#42"
branch: "feat/test-42"
current_stage: build
started_at: 2024-01-01T00:00:00Z
test_cmd: "echo pass"
pr_number:
progress_comment_id:
stages:
  intake: complete
  plan: complete
---

## Log
### intake
Goal: Resume test goal
_RESUME_STATE2_

cat > "$TASKS_FILE" <<'_MATCH_TASKS_'
# Pipeline Tasks — current run

## Context

- Pipeline: autonomous
- Branch: feat/test-42
- Issue: #42
_MATCH_TASKS_

GITHUB_ISSUE="" GIT_BRANCH=""
resume_state 2>/dev/null || true
if [[ -f "$TASKS_FILE" ]]; then
    assert_pass "resume_state preserves pipeline-tasks.md when issue matches"
else
    assert_fail "resume_state preserves pipeline-tasks.md when issue matches" "file was incorrectly removed"
fi

# Case 3: tasks file has no Context/Issue section → preserve (backward-compat)
cat > "$TASKS_FILE" <<'_OLD_TASKS_'
# Pipeline Tasks

- [ ] Task 1
- [ ] Task 2
_OLD_TASKS_

cat > "$STATE_FILE" <<'_RESUME_STATE3_'
---
pipeline: test-pipeline
goal: "Resume test goal"
status: interrupted
issue: "#42"
branch: "feat/test-42"
current_stage: build
started_at: 2024-01-01T00:00:00Z
test_cmd: "echo pass"
pr_number:
progress_comment_id:
stages:
  intake: complete
  plan: complete
---

## Log
_RESUME_STATE3_

GITHUB_ISSUE="" GIT_BRANCH=""
resume_state 2>/dev/null || true
if [[ -f "$TASKS_FILE" ]]; then
    assert_pass "resume_state preserves pipeline-tasks.md with no Issue metadata (backward-compat)"
else
    assert_fail "resume_state preserves pipeline-tasks.md with no Issue metadata (backward-compat)" "file was incorrectly removed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# persist_artifacts — CI_MODE guard
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "persist_artifacts"

CI_MODE=false
ISSUE_NUMBER="42"
echo "content" > "$ARTIFACTS_DIR/plan.md"

# Should be no-op when CI_MODE=false
persist_artifacts "plan" "plan.md" 2>/dev/null
assert_pass "persist_artifacts is no-op outside CI"

print_test_results
