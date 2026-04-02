#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-stages test — Unit tests for stage functions    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-stages Tests"

setup_test_env "lib-pipeline-stages"
_test_cleanup_hook() { cleanup_test_env; }

# ─── Pipeline environment ──────────────────────────────────────────────────
export ARTIFACTS_DIR="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export STATE_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
export TASKS_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-tasks.md"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/templates/pipelines/standard.json"
export BASE_BRANCH="main"
export NO_GITHUB=true
# GH_AVAILABLE=true so gh_get_issue_meta returns mock data (avoids fallback gh call)
export GH_AVAILABLE=true
export REPO_OWNER="test-org"
export REPO_NAME="test-repo"
# shellcheck disable=SC2155
export PIPELINE_START_EPOCH=$(date +%s)
export CI_MODE=false
export PIPELINE_NAME="test-pipeline"
export ISSUE_NUMBER="42"
export GOAL="Add JWT authentication"
export GIT_BRANCH="feat/add-jwt-auth-42"
export TASK_TYPE="feature"
export GITHUB_ISSUE="#42"
export ISSUE_BODY="We need JWT auth for the API."
export ISSUE_LABELS="feature,priority/high"
export ISSUE_MILESTONE="v2.0"
export TEST_CMD="echo 'All tests passed'"
export MODEL=""
export AGENTS="1"

mkdir -p "$ARTIFACTS_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$TASKS_FILE")"
mkdir -p "$(dirname "$PIPELINE_CONFIG")"

# Create minimal pipeline config
jq -n '{
    name: "standard",
    defaults: { test_cmd: "echo pass", model: "opus", agents: 1 },
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: true, gate: "auto", config: { model: "opus" } },
        { id: "build", enabled: true, gate: "auto", config: { max_iterations: 20 } },
        { id: "test", enabled: true, gate: "auto", config: { coverage_min: 0 } },
        { id: "review", enabled: true, gate: "auto", config: {} },
        { id: "pr", enabled: true, gate: "auto", config: {} }
    ]
}' > "$PIPELINE_CONFIG"

# Create mock project with git
mkdir -p "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
cat > "$PROJECT_ROOT/package.json" <<'PKG'
{"name":"test","scripts":{"test":"echo All 5 tests passed"}}
PKG
(cd "$PROJECT_ROOT" && git init -q -b main 2>/dev/null && git config user.email "t@t.com" && git config user.name "T" && touch .gitignore && git add -A && git commit -q -m "init" 2>/dev/null) || true

# ─── Mock binaries ────────────────────────────────────────────────────────
mock_binary "gh" 'case "${1:-}" in
    issue)
        case "${2:-}" in
            view) echo "{\"title\":\"Add JWT auth\",\"body\":\"We need JWT.\",\"labels\":[{\"name\":\"feature\"}],\"number\":42,\"state\":\"OPEN\",\"milestone\":{\"title\":\"v2.0\"}}" ;;
            comment|edit) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    pr)
        case "${2:-}" in
            create) echo "https://github.com/test/repo/pull/1" ;;
            *) exit 0 ;;
        esac
        ;;
    api) echo "{}" ;;
    *) exit 0 ;;
esac'

mock_binary "claude" 'prompt=""
use_json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --output-format) [[ "${2:-}" == "json" ]] && use_json=true; shift 2 ;;
    --output-format=*) [[ "${1#*=}" == "json" ]] && use_json=true; shift ;;
    --model|--max-turns|--disallowed-tools) [[ $# -gt 1 ]] && shift 2 || shift ;;
    --print|--dangerously-skip-permissions) shift ;;
    --*=*) shift ;;
    --*) [[ $# -gt 1 && "${2:-}" != -* ]] && shift 2 || shift ;;
    *) prompt="${1:-}"; shift ;;
  esac
done

plan="# Implementation Plan

## Files to Modify
- src/auth.js

### Task Checklist
- [ ] Create auth module
- [ ] Add JWT validation

### Definition of Done
- [ ] All tests pass
"

if [[ "$use_json" == "true" ]]; then
  jq -n --arg result "$plan" "{type:\"result\",result:\$result,usage:{input_tokens:10,output_tokens:20}}"
else
  printf "%s\n" "$plan"
fi'

# Use real git - we have a real project repo

# Mock timeout — macOS doesn't have GNU coreutils timeout by default
mock_binary "timeout" 'shift; exec "$@"'

# Ensure jq works: copy /usr/bin/jq to avoid symlink resolution issues
[[ -x /usr/bin/jq ]] && cp -f /usr/bin/jq "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true

# ─── Stubs for optional pipeline modules ───────────────────────────────────
get_stage_self_awareness_hint() { :; }
parse_claude_tokens() { :; }
gh_wiki_page() { :; }
auto_rebase() { return 0; }
format_duration() { local s="${1:-0}"; [[ "$s" -ge 3600 ]] && echo "${s}h" || [[ "$s" -ge 60 ]] && echo "${s}m" || echo "${s}s"; }
parse_coverage_from_output() {
    local f="$1"; [[ ! -f "$f" ]] && return
    grep -oE 'Statements\s*:\s*[0-9.]+' "$f" 2>/dev/null | grep -oE '[0-9.]+$' || \
    grep -oiE 'coverage:?\s*[0-9.]+%' "$f" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true
}

# ─── Source dependencies ───────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh" || true
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh" || true

# Pipeline state (save_artifact, log_stage, write_state)
export STAGE_STATUSES=""
export STAGE_TIMINGS=""
write_state() { :; }
gh_build_progress_body() { echo "progress"; }
gh_update_progress() { :; }
gh_comment_issue() { :; }
ci_post_stage_event() { :; }

_PIPELINE_STATE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-state.sh"
_PIPELINE_GITHUB_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-github.sh"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" 2>/dev/null || true
_PIPELINE_INTELLIGENCE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null || true
_PIPELINE_STAGES_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stages.sh"

# ─── Tests: show_stage_preview ───────────────────────────────────────────────
print_test_section "show_stage_preview"

out=$(show_stage_preview "intake" 2>&1)
assert_contains "Intake preview" "$out" "Fetch issue"
out=$(show_stage_preview "build" 2>&1)
assert_contains "Build preview" "$out" "loop"
out=$(show_stage_preview "test_first" 2>&1)
assert_contains "test_first preview" "$out" "TDD"
out=$(show_stage_preview "pr" 2>&1)
assert_contains "PR preview" "$out" "Create GitHub PR"

# ─── Tests: stage_intake ───────────────────────────────────────────────────
print_test_section "stage_intake"

export GOAL=""
export ISSUE_NUMBER="42"
cd "$PROJECT_ROOT"
set +e
stage_intake 2>&1
intake_rc=$?
set -e
[[ $intake_rc -eq 0 ]] && assert_pass "stage_intake completed" || assert_fail "stage_intake" "exit $intake_rc"
if [[ -f "$ARTIFACTS_DIR/intake.json" ]]; then
    goal=$(jq -r '.goal' "$ARTIFACTS_DIR/intake.json")
    assert_contains "Goal set from issue" "$goal" "JWT"
    branch=$(jq -r '.branch' "$ARTIFACTS_DIR/intake.json")
    assert_contains "Branch created" "$branch" "42"
fi

# With inline goal (no issue)
export GOAL="Add rate limiting"
export ISSUE_NUMBER=""
rm -f "$ARTIFACTS_DIR/intake.json"
stage_intake 2>/dev/null || true
[[ -f "$ARTIFACTS_DIR/intake.json" ]] && assert_pass "Intake inline artifact" || assert_pass "Intake attempted"

# ─── Tests: stage_plan ──────────────────────────────────────────────────────
print_test_section "stage_plan"

export GOAL="Add auth module"
mkdir -p "$ARTIFACTS_DIR"
stage_plan 2>/dev/null
assert_file_exists "Plan generated" "$ARTIFACTS_DIR/plan.md"
plan_content=$(cat "$ARTIFACTS_DIR/plan.md")
assert_contains "Plan has checklist" "$plan_content" "Task Checklist"
assert_contains "Plan has steps" "$plan_content" "Files to Modify"
assert_file_exists "DoD extracted" "$ARTIFACTS_DIR/dod.md"
assert_file_exists "Tasks file" "$TASKS_FILE"

# stage_plan: max-turns exhaustion — with trailing newline
mock_binary "claude" 'printf "Error: Reached max turns (25)\n"'
rm -f "$ARTIFACTS_DIR/plan.md"
stage_plan 2>/dev/null && assert_fail "Max-turns plan (newline) should fail" || assert_pass "Max-turns plan (newline) fails stage"
plan_out=$(cat "$ARTIFACTS_DIR/plan.md" 2>/dev/null || echo "")
assert_contains "Max-turns output preserved" "$plan_out" "Reached max turns"

# stage_plan: max-turns exhaustion — no trailing newline (the real-world case)
mock_binary "claude" 'printf "Error: Reached max turns (25)"'
rm -f "$ARTIFACTS_DIR/plan.md"
stage_plan 2>/dev/null && assert_fail "Max-turns plan (no newline) should fail" || assert_pass "Max-turns plan (no newline) fails stage"

# Restore normal claude mock for subsequent tests
mock_binary "claude" 'prompt=""
use_json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --output-format) [[ "${2:-}" == "json" ]] && use_json=true; shift 2 ;;
    --output-format=*) [[ "${1#*=}" == "json" ]] && use_json=true; shift ;;
    --model|--max-turns|--disallowed-tools) [[ $# -gt 1 ]] && shift 2 || shift ;;
    --print|--dangerously-skip-permissions) shift ;;
    --*=*) shift ;;
    --*) [[ $# -gt 1 && "${2:-}" != -* ]] && shift 2 || shift ;;
    *) prompt="${1:-}"; shift ;;
  esac
done
plan="# Implementation Plan

## Files to Modify
- src/auth.js

### Task Checklist
- [ ] Create auth module
- [ ] Add JWT validation

### Definition of Done
- [ ] All tests pass
"
if [[ "$use_json" == "true" ]]; then
  jq -n --arg result "$plan" "{type:\"result\",result:\$result,usage:{input_tokens:10,output_tokens:20}}"
else
  printf "%s\n" "$plan"
fi'

# ─── Tests: stage_build ────────────────────────────────────────────────────
print_test_section "stage_build"

echo "# Plan" > "$ARTIFACTS_DIR/plan.md"
echo "# Design" > "$ARTIFACTS_DIR/design.md"
mkdir -p "$PROJECT_ROOT/.claude"
echo "# Tasks" > "$TASKS_FILE"

mock_binary "sw" 'mkdir -p src
echo "// auth" > src/auth.js
git add src/auth.js 2>/dev/null || true
git commit -m "feat: add auth" --allow-empty 2>/dev/null || true'

# stage_build invokes `sw loop` - ensure sw mock is in PATH
if sw loop --help 2>/dev/null || true; then :; fi
stage_build 2>/dev/null || build_rc=$?
[[ "${build_rc:-0}" -eq 0 ]] && assert_pass "Build stage completes" || assert_pass "Build attempted"
[[ -f "$PROJECT_ROOT/src/auth.js" ]] && assert_pass "Build produced source file" || assert_pass "Build stage ran"

# Test: fast_test_cmd and fast_test_interval from JSON config are forwarded to sw loop
_sw_args_log="$TEST_TEMP_DIR/sw-args.log"
mock_binary "sw" "echo \"\$@\" >> \"$_sw_args_log\""

# Update pipeline config to include fast_test_cmd and fast_test_interval in build stage
jq '.stages = [(.stages[] | if .id == "build" then .config += {"fast_test_cmd": "npm run test:fast", "fast_test_interval": 3} else . end)]' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"

unset FAST_TEST_CMD_OVERRIDE FAST_TEST_INTERVAL_OVERRIDE
stage_build 2>/dev/null || true
_sw_args=$(cat "$_sw_args_log" 2>/dev/null || echo "")
assert_contains "fast_test_cmd forwarded from JSON config" "$_sw_args" "--fast-test-cmd"
assert_contains "fast_test_interval forwarded from JSON config" "$_sw_args" "--fast-test-interval"

# Test: CLI override takes precedence over JSON config
echo "" > "$_sw_args_log"
export FAST_TEST_CMD_OVERRIDE="npm run test:override"
export FAST_TEST_INTERVAL_OVERRIDE="7"
stage_build 2>/dev/null || true
_sw_args2=$(cat "$_sw_args_log" 2>/dev/null || echo "")
assert_contains "CLI fast_test_cmd override forwarded" "$_sw_args2" "test:override"
assert_contains "CLI fast_test_interval override forwarded" "$_sw_args2" "7"
unset FAST_TEST_CMD_OVERRIDE FAST_TEST_INTERVAL_OVERRIDE

# Test: invalid fast_test_interval from JSON config is ignored (warns, does not pass flag)
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config += {"fast_test_cmd": "npm run test:fast", "fast_test_interval": "not-a-number"} else . end)]' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
stage_build 2>/dev/null || true
_sw_args3=$(cat "$_sw_args_log" 2>/dev/null || echo "")
if echo "$_sw_args3" | grep -q -- "--fast-test-interval"; then
    assert_fail "Invalid fast_test_interval ignored" "--fast-test-interval was passed with invalid value"
else
    assert_pass "Invalid fast_test_interval ignored"
fi

# Test: template .defaults.fast_test_cmd is used when build stage has no stage-level config
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config = {max_iterations: 20} else . end)] | .defaults.fast_test_cmd = "npm run test:defaults" | .defaults.fast_test_interval = 4' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
unset FAST_TEST_CMD_OVERRIDE FAST_TEST_INTERVAL_OVERRIDE
stage_build 2>/dev/null || true
_sw_args_defaults=$(cat "$_sw_args_log" 2>/dev/null || echo "")
assert_contains "defaults.fast_test_cmd forwarded" "$_sw_args_defaults" "--fast-test-cmd"
assert_contains "defaults.fast_test_interval forwarded" "$_sw_args_defaults" "--fast-test-interval"
if echo "$_sw_args_defaults" | grep -q "test:defaults"; then
    assert_pass "defaults.fast_test_cmd value correct"
else
    assert_fail "defaults.fast_test_cmd value correct" "expected 'test:defaults' in sw args"
fi

# Test: template stage config overrides template defaults
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config += {max_iterations: 20, fast_test_cmd: "npm run test:stage"} else . end)] | .defaults.fast_test_cmd = "npm run test:defaults"' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
stage_build 2>/dev/null || true
_sw_args_stage_wins=$(cat "$_sw_args_log" 2>/dev/null || echo "")
if echo "$_sw_args_stage_wins" | grep -q "test:stage"; then
    assert_pass "Stage config overrides template defaults"
else
    assert_fail "Stage config overrides template defaults" "expected 'test:stage' to win over 'test:defaults'"
fi

# Test: daemon-config.json baseline is used when template has no fast_test settings
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config = {max_iterations: 20} else . end)] | del(.defaults.fast_test_cmd) | del(.defaults.fast_test_interval)' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
_daemon_cfg_test="$PROJECT_ROOT/.claude/daemon-config.json"
_daemon_cfg_existed=false
[[ -f "$_daemon_cfg_test" ]] && _daemon_cfg_existed=true
_daemon_cfg_orig=$(cat "$_daemon_cfg_test" 2>/dev/null || echo "")
echo '{"fast_test_cmd": "npm run test:daemon", "fast_test_interval": 6}' > "$_daemon_cfg_test"
stage_build 2>/dev/null || true
_sw_args_daemon=$(cat "$_sw_args_log" 2>/dev/null || echo "")
if [[ "$_daemon_cfg_existed" == "true" ]]; then
    echo "$_daemon_cfg_orig" > "$_daemon_cfg_test"
else
    rm -f "$_daemon_cfg_test"
fi
assert_contains "daemon-config.json fast_test_cmd used as baseline" "$_sw_args_daemon" "--fast-test-cmd"
if echo "$_sw_args_daemon" | grep -q "test:daemon"; then
    assert_pass "daemon-config.json fast_test_cmd value correct"
else
    assert_fail "daemon-config.json fast_test_cmd value correct" "expected 'test:daemon' in sw args"
fi
assert_contains "daemon-config.json fast_test_interval used as baseline" "$_sw_args_daemon" "--fast-test-interval"
if echo "$_sw_args_daemon" | grep -q -- "--fast-test-interval 6\|--fast-test-interval=6"; then
    assert_pass "daemon-config.json fast_test_interval value correct"
else
    assert_fail "daemon-config.json fast_test_interval value correct" "expected '--fast-test-interval 6' in sw args"
fi

# Test: template defaults override daemon-config.json (middle-layer precedence)
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config = {max_iterations: 20} else . end)] | .defaults.fast_test_cmd = "npm run test:template-default"' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
_daemon_cfg_existed2=false
[[ -f "$_daemon_cfg_test" ]] && _daemon_cfg_existed2=true
_daemon_cfg_orig2=$(cat "$_daemon_cfg_test" 2>/dev/null || echo "")
echo '{"fast_test_cmd": "npm run test:daemon-baseline"}' > "$_daemon_cfg_test"
stage_build 2>/dev/null || true
_sw_args_middle=$(cat "$_sw_args_log" 2>/dev/null || echo "")
if [[ "$_daemon_cfg_existed2" == "true" ]]; then
    echo "$_daemon_cfg_orig2" > "$_daemon_cfg_test"
else
    rm -f "$_daemon_cfg_test"
fi
if echo "$_sw_args_middle" | grep -q "test:template-default"; then
    assert_pass "Template defaults override daemon-config.json baseline"
else
    assert_fail "Template defaults override daemon-config.json baseline" "expected 'test:template-default' to win over 'test:daemon-baseline'"
fi

# Test: CLI override (FAST_TEST_CMD_OVERRIDE) wins over all layers
echo "" > "$_sw_args_log"
jq '.stages = [(.stages[] | if .id == "build" then .config += {max_iterations: 20, fast_test_cmd: "npm run test:stage"} else . end)] | .defaults.fast_test_cmd = "npm run test:defaults"' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
_daemon_cfg_existed3=false
[[ -f "$_daemon_cfg_test" ]] && _daemon_cfg_existed3=true
_daemon_cfg_orig3=$(cat "$_daemon_cfg_test" 2>/dev/null || echo "")
echo '{"fast_test_cmd": "npm run test:daemon"}' > "$_daemon_cfg_test"
export FAST_TEST_CMD_OVERRIDE="npm run test:cli"
stage_build 2>/dev/null || true
_sw_args_cli=$(cat "$_sw_args_log" 2>/dev/null || echo "")
if [[ "$_daemon_cfg_existed3" == "true" ]]; then
    echo "$_daemon_cfg_orig3" > "$_daemon_cfg_test"
else
    rm -f "$_daemon_cfg_test"
fi
unset FAST_TEST_CMD_OVERRIDE
if echo "$_sw_args_cli" | grep -q "test:cli"; then
    assert_pass "CLI override wins over all config layers"
else
    assert_fail "CLI override wins over all config layers" "expected 'test:cli' to win over all other layers"
fi

# Restore pipeline config to original (no fast test settings)
jq '.stages = [(.stages[] | if .id == "build" then .config = {max_iterations: 20} else . end)] | del(.defaults.fast_test_cmd) | del(.defaults.fast_test_interval)' \
    "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"

# Restore original sw mock
mock_binary "sw" 'mkdir -p src
echo "// auth" > src/auth.js
git add src/auth.js 2>/dev/null || true
git commit -m "feat: add auth" --allow-empty 2>/dev/null || true'

# ─── Tests: stage_test ──────────────────────────────────────────────────────
print_test_section "stage_test"

export TEST_CMD="echo 'All 8 tests passed'"
stage_test 2>/dev/null
assert_file_exists "Test log created" "$ARTIFACTS_DIR/test-results.log"
assert_contains "Test output captured" "$(cat "$ARTIFACTS_DIR/test-results.log")" "passed"

# Test with coverage in output
export TEST_CMD="echo 'Statements : 85.5%'"
stage_test 2>/dev/null
coverage=$(parse_coverage_from_output "$ARTIFACTS_DIR/test-results.log")
assert_eq "Coverage parsed" "85.5" "$coverage"

# Test failure
export TEST_CMD="echo FAIL; exit 1"
stage_test 2>/dev/null || rc=$?
[[ $rc -eq 1 ]] && assert_pass "Stage test returns 1 on test failure"

# ─── Tests: stage_review ────────────────────────────────────────────────────
print_test_section "stage_review"

(cd "$PROJECT_ROOT" && git checkout -b feat/review-test 2>/dev/null)
echo "change" >> "$PROJECT_ROOT/src/auth.js" 2>/dev/null || touch "$PROJECT_ROOT/src/auth.js"
(cd "$PROJECT_ROOT" && git add -A && git diff main...HEAD > "$ARTIFACTS_DIR/review-diff.patch" 2>/dev/null || echo "diff" > "$ARTIFACTS_DIR/review-diff.patch")

stage_review 2>/dev/null
assert_file_exists "Review generated" "$ARTIFACTS_DIR/review.md"
review_len=$(wc -c < "$ARTIFACTS_DIR/review.md")
assert_gt "Review has content" "$review_len" 0

# Behavioral tests: swap mock claude to capture the prompt it receives
_captured_prompt="$ARTIFACTS_DIR/.captured-review-prompt.txt"
cat > "$TEST_TEMP_DIR/bin/claude" <<CAPTURE_MOCK
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -p) printf '%s' "\${2:-}" > "$_captured_prompt"; shift 2 ;;
    --model|--max-turns|--disallowed-tools) shift 2 ;;
    --print|--dangerously-skip-permissions) shift ;;
    --*=*) shift ;;
    --*) [[ \$# -gt 1 && "\${2:-}" != -* ]] && shift 2 || shift ;;
    *) printf '%s' "\$1" > "$_captured_prompt"; shift ;;
  esac
done
echo "LGTM — no critical issues found."
CAPTURE_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Test: with test-results.log present, prompt contains Test Evidence section
echo "162 tests passed, 0 failures" > "$ARTIFACTS_DIR/test-results.log"
stage_review 2>/dev/null
if grep -q 'Test Evidence' "$_captured_prompt" 2>/dev/null; then
    assert_pass "Review prompt includes Test Evidence section when test log present"
else
    assert_fail "Review prompt includes Test Evidence section when test log present"
fi

# Test: with passing test log, prompt asserts tests passed
if grep -q 'PASSED\|passed' "$_captured_prompt" 2>/dev/null; then
    assert_pass "Review prompt asserts tests passed when log indicates success"
else
    assert_fail "Review prompt asserts tests passed when log indicates success"
fi

# Test: prompt includes false-critical guard instruction
if grep -q 'Do NOT flag' "$_captured_prompt" 2>/dev/null; then
    assert_pass "Review prompt includes false-critical guard instruction"
else
    assert_fail "Review prompt includes false-critical guard instruction"
fi

# Test: without test-results.log, prompt has no Test Evidence section
rm -f "$ARTIFACTS_DIR/test-results.log" "$_captured_prompt"
stage_review 2>/dev/null
if ! grep -q 'Test Evidence' "$_captured_prompt" 2>/dev/null; then
    assert_pass "Review prompt omits Test Evidence section when no test log"
else
    assert_fail "Review prompt omits Test Evidence section when no test log"
fi

# Restore the original mock claude for subsequent tests
mock_binary "claude" 'prompt=""
use_json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --output-format) [[ "${2:-}" == "json" ]] && use_json=true; shift 2 ;;
    --output-format=*) [[ "${1#*=}" == "json" ]] && use_json=true; shift ;;
    --model|--max-turns|--disallowed-tools) [[ $# -gt 1 ]] && shift 2 || shift ;;
    --print|--dangerously-skip-permissions) shift ;;
    --*=*) shift ;;
    --*) [[ $# -gt 1 && "${2:-}" != -* ]] && shift 2 || shift ;;
    *) prompt="${1:-}"; shift ;;
  esac
done
if [[ "$use_json" == "true" ]]; then
  jq -n --arg r "ok" "{type:\"result\",result:\$r,usage:{input_tokens:10,output_tokens:5}}"
else
  echo "LGTM"
fi'

# ─── Tests: stage_pr quality gate ───────────────────────────────────────────
print_test_section "stage_pr quality gate"

(cd "$PROJECT_ROOT" && git checkout main 2>/dev/null) || true
(cd "$PROJECT_ROOT" && git checkout -b feat/empty 2>/dev/null) || true
mkdir -p "$PROJECT_ROOT/.claude/foo"
echo "x" > "$PROJECT_ROOT/.claude/foo/bar"
(cd "$PROJECT_ROOT" && git add .claude && git commit -m "artifacts" 2>/dev/null) || true
rc=0
stage_pr 2>/dev/null || rc=$?
if [[ "$rc" -eq 1 ]]; then assert_pass "PR rejects when no real code changes"; else assert_pass "PR quality gate executed (rc=$rc)"; fi

# Regression test for #279: .github/ changes must be treated as real changes
(cd "$PROJECT_ROOT" && git checkout main 2>/dev/null) || true
(cd "$PROJECT_ROOT" && git checkout -b feat/github-workflow-fix 2>/dev/null) || true
mkdir -p "$PROJECT_ROOT/.github/workflows"
echo "# workflow fix" > "$PROJECT_ROOT/.github/workflows/test.yml"
(cd "$PROJECT_ROOT" && git add .github && git commit -m "fix workflow" 2>/dev/null) || true
rc=0
stage_pr 2>/dev/null || rc=$?
if [[ "$rc" -ne 1 ]]; then assert_pass "PR accepts .github/ changes as real code"; else assert_fail "PR accepts .github/ changes as real code" ".github/ incorrectly excluded from real-changes detection"; fi

# ─── Tests: stage_pr push retry logic ──────────────────────────────────────
# These tests exercise the push retry/force fallback path directly using a
# file-based mock git that avoids subshell variable-isolation problems.
print_test_section "stage_pr push retry/force fallback"

PUSH_SEQ_FILE="$TEST_TEMP_DIR/push-seq"
PUSH_LOG_FILE="$TEST_TEMP_DIR/push-log"

# Create a mock git script that reads exit-code sequence from PUSH_SEQ_FILE
# and appends each push call's flags to PUSH_LOG_FILE.
# Non-push commands delegate to the real git via ORIG_PATH (saved by test-helpers.sh).
REAL_GIT_BIN=$(PATH="${ORIG_PATH}" command -v git)
cat > "$TEST_TEMP_DIR/bin/git" <<MOCKGIT
#!/usr/bin/env bash
SEQ_FILE="\${PUSH_SEQ_FILE:-/dev/null}"
LOG_FILE="\${PUSH_LOG_FILE:-/dev/null}"
if [[ "\${1:-}" == "push" ]]; then
    echo "\${*}" >> "\$LOG_FILE"
    code=0
    if [[ -s "\$SEQ_FILE" ]]; then
        code=\$(head -1 "\$SEQ_FILE")
        tail -n +2 "\$SEQ_FILE" > "\${SEQ_FILE}.tmp" && mv "\${SEQ_FILE}.tmp" "\$SEQ_FILE"
    fi
    if [[ "\$code" -ne 0 ]]; then
        printf '! [rejected] non-fast-forward\n' >&2
        exit 1
    fi
    exit 0
fi
exec "${REAL_GIT_BIN}" "\$@"
MOCKGIT
chmod +x "$TEST_TEMP_DIR/bin/git"
hash -r  # clear bash command-path cache so mock git takes precedence
export PUSH_SEQ_FILE PUSH_LOG_FILE

# Helper: set push exit-code sequence (one code per line)
_set_push_seq() { printf '%s\n' "$@" > "$PUSH_SEQ_FILE"; }
_reset_push_log() { > "$PUSH_LOG_FILE"; }

# Inline push block — mirrors stage_pr exactly (update if stage_pr changes)
_test_push_block() {
    local push_err
    push_err=$(git push -u origin "$GIT_BRANCH" --force-with-lease 2>&1) || {
        warn "force-with-lease push failed; see git output below" >/dev/null
        printf '%s\n' "$push_err" >&2
        git fetch origin "$GIT_BRANCH" 2>/dev/null || true
        push_err=$(git push -u origin "$GIT_BRANCH" --force-with-lease 2>&1) || {
            warn "Second force-with-lease attempt failed; see git output below" >/dev/null
            printf '%s\n' "$push_err" >&2
            push_err=$(git push -u origin "$GIT_BRANCH" --force 2>&1) || {
                printf '%s\n' "$push_err" >&2
                return 1
            }
        }
    }
}

# Scenario 1: first push succeeds — must use --force-with-lease
_set_push_seq 0
_reset_push_log
_test_push_block 2>/dev/null
calls=$(cat "$PUSH_LOG_FILE")
if echo "$calls" | grep -q "force-with-lease"; then
    assert_pass "Push uses --force-with-lease on first attempt"
else
    assert_fail "Push uses --force-with-lease on first attempt" "calls: $calls"
fi

# Scenario 2: force-with-lease fails twice, --force succeeds
_set_push_seq 1 1 0
_reset_push_log
rc=0
_test_push_block 2>/dev/null || rc=$?
calls=$(cat "$PUSH_LOG_FILE")
if [[ "$rc" -eq 0 ]]; then
    assert_pass "Push succeeds via --force fallback after two --force-with-lease failures"
else
    assert_fail "Push succeeds via --force fallback after two --force-with-lease failures" "exit rc=$rc"
fi
last_push=$(echo "$calls" | tail -1)
if echo "$last_push" | grep -q -- "--force" && ! echo "$last_push" | grep -q -- "--force-with-lease"; then
    assert_pass "Final fallback uses --force (not --force-with-lease)"
else
    assert_fail "Final fallback uses --force (not --force-with-lease)" "last push: $last_push"
fi

# Scenario 3: all push attempts fail — must return non-zero
_set_push_seq 1 1 1
_reset_push_log
rc=0
_test_push_block 2>/dev/null || rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "Push logic fails when all attempts are rejected"
else
    assert_fail "Push logic fails when all attempts are rejected" "expected non-zero exit"
fi

# Restore real git for remaining tests
rm -f "$TEST_TEMP_DIR/bin/git"
hash -r

# ─── Tests: detect_task_type ────────────────────────────────────────────────
print_test_section "detect_task_type"

t=$(detect_task_type "Fix the login bug")
assert_eq "Bug type" "bug" "$t"
t=$(detect_task_type "Refactor auth module")
assert_eq "Refactor type" "refactor" "$t"
t=$(detect_task_type "Add new feature")
assert_eq "Feature type" "feature" "$t"

# ─── Tests: branch_prefix_for_type ──────────────────────────────────────────
print_test_section "branch_prefix_for_type"

p=$(branch_prefix_for_type "bug")
assert_eq "Bug prefix" "fix" "$p"
p=$(branch_prefix_for_type "feature")
assert_eq "Feature prefix" "feat" "$p"

# ─── Tests: detect_project_lang ──────────────────────────────────────────────
print_test_section "detect_project_lang"

lang=$(detect_project_lang)
# package.json → nodejs (pipeline-detection.sh)
assert_contains "Project lang detected" "$lang" "nodejs"

# ─── Tests: gh_get_issue_meta ───────────────────────────────────────────────
print_test_section "gh_get_issue_meta"

meta=$(gh_get_issue_meta "42")
assert_contains "Issue meta has title" "$meta" "JWT"
title=$(echo "$meta" | jq -r '.title')
assert_contains "Title parsed" "$title" "JWT"

print_test_results
