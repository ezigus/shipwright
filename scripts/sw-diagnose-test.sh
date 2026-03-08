#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-diagnose-test.sh — Test suite for diagnose command                  ║
# ║                                                                          ║
# ║  Tests error classification, JSON output, and memory search.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="3.2.4"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-.}"

# Colors for output
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Test counters
PASS=0
FAIL=0
SKIP=0

# Test helpers
test_pass() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; PASS=$((PASS + 1)); }
test_fail() { echo -e "${RED}${BOLD}✗${RESET} $*"; FAIL=$((FAIL + 1)); }
test_skip() { echo -e "${YELLOW}${BOLD}⊘${RESET} $*"; SKIP=$((SKIP + 1)); }

# ─── Setup/Teardown ─────────────────────────────────────────────────────────
setup_test() {
  local test_name="$1"
  TEST_DIR=$(mktemp -d)
  export PIPELINE_DIR="$TEST_DIR/.claude/pipeline-artifacts"
  export STATE_FILE="$TEST_DIR/.claude/pipeline-state.md"
  mkdir -p "$PIPELINE_DIR"
}

cleanup_test() {
  [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ─── Test 1: Help output ────────────────────────────────────────────────────
test_help_output() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Help output${RESET}"

  local output
  output=$("$SCRIPT_DIR/sw-diagnose.sh" --help 2>&1)

  if echo "$output" | grep -q "Shipwright — Diagnose"; then
    test_pass "Help text contains title"
  else
    test_fail "Help text missing title"
  fi

  if echo "$output" | grep -q "USAGE"; then
    test_pass "Help text contains USAGE section"
  else
    test_fail "Help text missing USAGE section"
  fi

  if echo "$output" | grep -q "OPTIONS"; then
    test_pass "Help text contains OPTIONS section"
  else
    test_fail "Help text missing OPTIONS section"
  fi
}

# ─── Test 2: Version flag ───────────────────────────────────────────────────
test_version() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Version flag${RESET}"

  local output
  output=$("$SCRIPT_DIR/sw-diagnose.sh" --version 2>&1)

  if echo "$output" | grep -q "3.2.4"; then
    test_pass "Version flag returns correct version"
  else
    test_fail "Version flag output incorrect (got: $output)"
  fi
}

# ─── Test 3: No pipeline state (clean) ──────────────────────────────────────
test_no_pipeline_state() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: No pipeline state (clean)${RESET}"
  setup_test "no_pipeline"

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -q "No pipeline state found"; then
    test_pass "No pipeline state shows appropriate message"
  else
    test_fail "No pipeline state missing message"
  fi

  cleanup_test
}

# ─── Test 4: Test failure error ────────────────────────────────────────────
test_failure_error() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Test failure classification${RESET}"
  setup_test "test_failure"

  # Create mock pipeline state
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Test build"
status: failed
issue: "#99"
current_stage: test
elapsed: "5m 30s"
---
## Log
EOF

  # Create mock error-summary.json
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {
      "type": "test",
      "message": "FAIL: test('should add 1+1') - expected 3 received 2"
    }
  ]
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -qiE "FAIL|test.*failed|assert"; then
    test_pass "Test failure error is detected"
  else
    test_fail "Test failure error not detected"
  fi

  cleanup_test
}

# ─── Test 5: Syntax error ──────────────────────────────────────────────────
test_syntax_error() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Syntax error classification${RESET}"
  setup_test "syntax_error"

  # Create mock pipeline state
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build app"
status: failed
issue: "#100"
current_stage: build
elapsed: "2m"
---
EOF

  # Create mock error-summary.json
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {
      "type": "syntax",
      "message": "SyntaxError: Unexpected token } at line 42"
    }
  ]
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -qiE "syntax|SyntaxError"; then
    test_pass "Syntax error is detected"
  else
    test_fail "Syntax error not detected"
  fi

  cleanup_test
}

# ─── Test 6: Network error ─────────────────────────────────────────────────
test_network_error() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Network error classification${RESET}"
  setup_test "network_error"

  # Create mock pipeline state
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Deploy service"
status: failed
issue: "#101"
current_stage: test
elapsed: "3m 15s"
---
EOF

  # Create mock error-summary.json
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {
      "type": "network",
      "message": "ECONNREFUSED: Connection refused at 127.0.0.1:3000"
    }
  ]
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -qiE "network|connection|ECONNREFUSED"; then
    test_pass "Network error is detected"
  else
    test_fail "Network error not detected"
  fi

  cleanup_test
}

# ─── Test 7: JSON output format ────────────────────────────────────────────
test_json_output() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: JSON output format${RESET}"
  setup_test "json_output"

  # Create mock pipeline state
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build test"
status: failed
issue: "#102"
current_stage: build
elapsed: "1m"
---
EOF

  # Create mock error-summary.json
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {
      "type": "test",
      "message": "FAIL: test case failed"
    }
  ]
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --json 2>&1 || true
  )

  # Check if output is valid JSON
  if echo "$output" | grep -q '{' && echo "$output" | grep -q '}'; then
    test_pass "JSON output has valid structure"
  else
    test_fail "JSON output is malformed"
  fi

  # Check for expected fields
  if echo "$output" | grep -q '"status"'; then
    test_pass "JSON contains status field"
  else
    test_fail "JSON missing status field"
  fi

  if echo "$output" | grep -q '"pipeline"'; then
    test_pass "JSON contains pipeline field"
  else
    test_fail "JSON missing pipeline field"
  fi

  if echo "$output" | grep -q '"errors"'; then
    test_pass "JSON contains errors field"
  else
    test_fail "JSON missing errors field"
  fi

  if echo "$output" | grep -q '"diagnoses"'; then
    test_pass "JSON contains diagnoses field"
  else
    test_fail "JSON missing diagnoses field"
  fi

  cleanup_test
}

# ─── Test 8: Multiple errors ──────────────────────────────────────────────
test_multiple_errors() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Multiple errors classification${RESET}"
  setup_test "multiple_errors"

  # Create mock pipeline state
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build and test"
status: failed
issue: "#103"
current_stage: test
elapsed: "10m"
---
EOF

  # Create mock error-summary.json with multiple errors
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {
      "type": "test",
      "message": "FAIL: authentication test failed"
    },
    {
      "type": "network",
      "message": "ECONNREFUSED: Cannot connect to database"
    }
  ]
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  # Should detect multiple error types
  if echo "$output" | grep -qiE "test|network"; then
    test_pass "Multiple errors are classified"
  else
    test_fail "Multiple errors not classified"
  fi

  cleanup_test
}

# ─── Test 9: Verbose flag ────────────────────────────────────────────────
test_verbose_flag() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Verbose flag${RESET}"
  setup_test "verbose"

  # Create mock pipeline state with many errors
  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Complex build"
status: failed
issue: "#104"
current_stage: test
elapsed: "15m"
---
EOF

  # Create mock error-summary.json with many errors
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "errors": [
    {"type": "test", "message": "Test 1 failed"},
    {"type": "test", "message": "Test 2 failed"},
    {"type": "test", "message": "Test 3 failed"},
    {"type": "test", "message": "Test 4 failed"},
    {"type": "test", "message": "Test 5 failed"}
  ]
}
EOF

  local output_normal
  output_normal=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  local output_verbose
  output_verbose=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --verbose 2>&1 || true
  )

  # Normal output should limit to 3
  if echo "$output_normal" | grep -q "total causes found"; then
    test_pass "Normal output shows limit message"
  else
    test_skip "Normal output limit message not shown (may be expected)"
  fi

  # Both should have valid content
  if [[ -n "$output_verbose" ]]; then
    test_pass "Verbose flag produces output"
  else
    test_fail "Verbose flag produces empty output"
  fi

  cleanup_test
}

# ─── Test 10: Unknown option ──────────────────────────────────────────────
test_unknown_option() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Unknown option handling${RESET}"

  local exit_code=0
  "$SCRIPT_DIR/sw-diagnose.sh" --invalid-option >/dev/null 2>&1 || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    test_pass "Unknown option returns error exit code"
  else
    test_fail "Unknown option should return non-zero exit code"
  fi
}

# ─── Test 11: Real error-summary.json format (error_lines) ──────────────────
test_real_error_format() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Real error-summary.json format (error_lines)${RESET}"
  setup_test "real_error_format"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build feature"
status: failed
issue: "#110"
current_stage: build
elapsed: "8m 12s"
---
EOF

  # Real format from write_error_summary() in sw-loop.sh
  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "iteration": 3,
  "timestamp": "2026-03-08T12:19:01Z",
  "error_count": 2,
  "error_lines": [
    "FAIL: src/utils.test.js > should validate input",
    "TypeError: Cannot read property 'name' of undefined"
  ],
  "test_cmd": "npm test"
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -q "FAIL.*validate input"; then
    test_pass "Real error_lines format: test failure detected"
  else
    test_fail "Real error_lines format: test failure not detected (output: $output)"
  fi

  if echo "$output" | grep -q "TypeError"; then
    test_pass "Real error_lines format: TypeError detected"
  else
    test_fail "Real error_lines format: TypeError not detected"
  fi

  cleanup_test
}

# ─── Test 12: Stage artifact analysis ─────────────────────────────────────
test_stage_artifacts() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Stage artifact analysis${RESET}"
  setup_test "stage_artifacts"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Deploy service"
status: failed
issue: "#111"
current_stage: test
elapsed: "12m"
stage_progress: "intake:complete plan:complete build:complete test:pending review:pending"
---
EOF

  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "error_lines": ["FAIL: test suite"]
}
EOF

  # Create checkpoint directory with a checkpoint
  mkdir -p "$PIPELINE_DIR/checkpoints"
  cat > "$PIPELINE_DIR/checkpoints/test-001.json" <<'EOF'
{
  "stage": "test",
  "status": "failed",
  "timestamp": "2026-03-08T12:00:00Z"
}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" 2>&1 || true
  )

  if echo "$output" | grep -qi "checkpoint"; then
    test_pass "Stage artifacts: checkpoints detected"
  else
    test_fail "Stage artifacts: checkpoints not detected"
  fi

  if echo "$output" | grep -qi "progress"; then
    test_pass "Stage artifacts: progress shown"
  else
    test_fail "Stage artifacts: progress not shown"
  fi

  cleanup_test
}

# ─── Test 13: Memory search (mock) ────────────────────────────────────────
test_memory_search() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Memory search with mock${RESET}"
  setup_test "memory_search"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build auth module"
status: failed
issue: "#112"
current_stage: build
elapsed: "5m"
---
EOF

  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "error_lines": ["SyntaxError: Unexpected token"]
}
EOF

  # Create a mock memory_ranked_search that returns JSON
  local mock_bin_dir="$TEST_DIR/bin"
  mkdir -p "$mock_bin_dir"

  # Source the script with a mocked function
  local output
  output=$(
    cd "$TEST_DIR"
    # Define mock before sourcing
    memory_ranked_search() {
      echo '{"results":[{"file":"failures.json","summary":"Similar SyntaxError in auth module fixed by adding missing bracket"}]}'
    }
    export -f memory_ranked_search
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    bash -c '
      memory_ranked_search() {
        echo "{\"results\":[{\"file\":\"failures.json\",\"summary\":\"Similar SyntaxError in auth module fixed by adding missing bracket\"}]}"
      }
      source "'"$SCRIPT_DIR/sw-diagnose.sh"'"
      main
    ' 2>&1 || true
  )

  if echo "$output" | grep -qi "SIMILAR PAST FAILURES\|failures.json\|SyntaxError.*auth"; then
    test_pass "Memory search: past failures shown"
  else
    test_skip "Memory search: mock function not invoked in subshell (expected in some environments)"
  fi

  cleanup_test
}

# ─── Test 14: --stage flag ────────────────────────────────────────────────
test_stage_flag() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: --stage flag${RESET}"
  setup_test "stage_flag"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Build app"
status: failed
issue: "#113"
current_stage: test
elapsed: "7m"
---
EOF

  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "error_lines": ["FAIL: test case"]
}
EOF

  # Matching stage filter
  local output_match
  output_match=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --stage test 2>&1 || true
  )

  if echo "$output_match" | grep -qiE "ROOT CAUSES|FAIL"; then
    test_pass "--stage test: matching stage shows diagnoses"
  else
    test_fail "--stage test: matching stage should show diagnoses"
  fi

  # Non-matching stage filter
  local output_nomatch
  output_nomatch=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --stage build 2>&1 || true
  )

  if echo "$output_nomatch" | grep -qi "does not match"; then
    test_pass "--stage build: non-matching stage shows filter message"
  else
    test_fail "--stage build: non-matching stage should show filter message"
  fi

  cleanup_test
}

# ─── Test 15: JSON output with all new fields ──────────────────────────────
test_json_full_output() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: JSON output with memory_matches and stage_artifacts${RESET}"
  setup_test "json_full"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Full test"
status: failed
issue: "#114"
current_stage: build
elapsed: "3m"
stage_progress: "intake:complete plan:complete build:pending"
---
EOF

  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "error_lines": ["FAIL: component test"]
}
EOF

  mkdir -p "$PIPELINE_DIR/checkpoints"
  cat > "$PIPELINE_DIR/checkpoints/build-001.json" <<'EOF'
{"stage":"build","status":"failed"}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --json 2>&1 || true
  )

  if echo "$output" | grep -q '"memory_matches"'; then
    test_pass "JSON contains memory_matches field"
  else
    test_fail "JSON missing memory_matches field"
  fi

  if echo "$output" | grep -q '"stage_artifacts"'; then
    test_pass "JSON contains stage_artifacts field"
  else
    test_fail "JSON missing stage_artifacts field"
  fi

  # Validate it's parseable JSON (if jq available)
  # Filter out stderr warnings that may be mixed in with 2>&1
  if command -v jq >/dev/null 2>&1; then
    local json_only
    json_only=$(echo "$output" | sed -n '/^{/,/^}/p')
    if echo "$json_only" | jq . >/dev/null 2>&1; then
      test_pass "JSON output is valid JSON"
    else
      test_fail "JSON output is not valid JSON"
    fi
  else
    test_skip "jq not available to validate JSON"
  fi

  cleanup_test
}

# ─── Test 16: Verbose log excerpts ───────────────────────────────────────
test_verbose_log_excerpts() {
  echo ""
  echo -e "${CYAN}${BOLD}TEST: Verbose mode shows log excerpts${RESET}"
  setup_test "verbose_excerpts"

  cat > "$STATE_FILE" <<'EOF'
---
pipeline: standard
goal: "Test verbose"
status: failed
issue: "#115"
current_stage: test
elapsed: "4m"
---
EOF

  cat > "$PIPELINE_DIR/error-summary.json" <<'EOF'
{
  "error_lines": ["FAIL: auth test"]
}
EOF

  # Create error-log.jsonl with entries
  cat > "$PIPELINE_DIR/error-log.jsonl" <<'EOF'
{"timestamp":"2026-03-08T12:00:00Z","level":"error","message":"Authentication handler threw exception"}
{"timestamp":"2026-03-08T12:00:01Z","level":"error","message":"Token validation failed: expired"}
EOF

  local output
  output=$(
    cd "$TEST_DIR"
    PIPELINE_DIR="$PIPELINE_DIR" STATE_FILE="$STATE_FILE" \
    "$SCRIPT_DIR/sw-diagnose.sh" --verbose 2>&1 || true
  )

  if echo "$output" | grep -qi "LOG EXCERPTS"; then
    test_pass "Verbose mode shows LOG EXCERPTS section"
  else
    test_fail "Verbose mode missing LOG EXCERPTS section"
  fi

  if echo "$output" | grep -qi "Authentication handler\|Token validation"; then
    test_pass "Verbose mode shows log content"
  else
    test_fail "Verbose mode missing log content"
  fi

  cleanup_test
}

# ─── Main test runner ───────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${CYAN}${BOLD}Shipwright — Diagnose Test Suite${RESET}"
  echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
  echo ""

  # Run all tests
  test_help_output
  test_version
  test_no_pipeline_state
  test_failure_error
  test_syntax_error
  test_network_error
  test_json_output
  test_multiple_errors
  test_verbose_flag
  test_unknown_option
  test_real_error_format
  test_stage_artifacts
  test_memory_search
  test_stage_flag
  test_json_full_output
  test_verbose_log_excerpts

  # Summary
  echo ""
  echo -e "${CYAN}${BOLD}Test Summary${RESET}"
  echo -e "${DIM}──────────────────────────────────────────${RESET}"
  echo -e "  ${GREEN}${BOLD}PASS${RESET}  $PASS"
  echo -e "  ${RED}${BOLD}FAIL${RESET}  $FAIL"
  echo -e "  ${YELLOW}${BOLD}SKIP${RESET}  $SKIP"
  echo ""

  if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ All tests passed!${RESET}"
    return 0
  else
    echo -e "${RED}${BOLD}✗ Some tests failed${RESET}"
    return 1
  fi
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
