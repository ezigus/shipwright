#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  error-actionability test suite                                          ║
# ║  Tests scoring logic, enhancement, and edge cases                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/error-actionability.sh"

PASS=0
FAIL=0

# Simple test helpers
assert_score() {
  local desc="$1"
  local error_msg="$2"
  local expected="$3"

  local actual
  actual=$(get_error_score "$error_msg" 2>/dev/null || echo "0")

  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $desc"
    ((PASS++))
  else
    echo "✗ $desc (got $actual, expected $expected)"
    ((FAIL++))
  fi
}

assert_has_component() {
  local desc="$1"
  local error_msg="$2"
  local component="$3"  # filepath, line_number, error_type, actionable_detail, fix_suggestion

  local json
  json=$(score_error_actionability "$error_msg" 2>/dev/null || echo "{}")

  local has_component
  has_component=$(echo "$json" | grep -o "\"$component\"[[:space:]]*:[[:space:]]*[01]" | grep -o "[01]$" || echo "0")

  if [[ "$has_component" == "1" ]]; then
    echo "✓ $desc"
    ((PASS++))
  else
    echo "✗ $desc (component not detected)"
    ((FAIL++))
  fi
}

assert_needs_enhancement() {
  local desc="$1"
  local error_msg="$2"
  local should_need="${3:-true}"

  local score
  score=$(get_error_score "$error_msg" 2>/dev/null || echo "0")

  local needs_it=false
  [[ $score -lt 70 ]] && needs_it=true

  if [[ "$needs_it" == "$should_need" ]]; then
    echo "✓ $desc"
    ((PASS++))
  else
    echo "✗ $desc (needs_enhancement=$needs_it, expected=$should_need)"
    ((FAIL++))
  fi
}

assert_contains_category() {
  local desc="$1"
  local error_msg="$2"
  local category="$3"  # e.g., FILE_ACCESS, FUNCTION_ERROR, etc.

  local enhanced
  enhanced=$(enhance_error_message "$error_msg" 2>/dev/null || echo "")

  if echo "$enhanced" | grep -q "\[$category\]"; then
    echo "✓ $desc"
    ((PASS++))
  else
    echo "✗ $desc (category $category not found)"
    ((FAIL++))
  fi
}

# Run tests
echo "╔════════════════════════════════════════════╗"
echo "║  Error Actionability Scoring Tests        ║"
echo "╚════════════════════════════════════════════╝"
echo ""

echo "File Path Detection:"
assert_has_component "  absolute path" "/path/to/file.sh: error" "filepath"
assert_has_component "  relative path" "./scripts/file.sh: error" "filepath"
assert_score "  no path scores 0" "error with no path" "0"

echo ""
echo "Line Number Detection:"
assert_has_component "  colon format" "file.sh:42: error" "line_number"
assert_has_component "  'at line' format" "error at line 123" "line_number"
assert_score "  no line number scores 0" "error message" "0"

echo ""
echo "Error Type Detection:"
assert_has_component "  TypeError" "TypeError: bad property" "error_type"
assert_has_component "  SyntaxError" "SyntaxError: unexpected" "error_type"
assert_has_component "  ENOENT" "ENOENT: file not found" "error_type"
assert_has_component "  Generic Error" "Error: something bad" "error_type"

echo ""
echo "Actionable Detail Detection:"
assert_has_component "  'cannot' keyword" "cannot read file" "actionable_detail"
assert_has_component "  'does not exist'" "file does not exist" "actionable_detail"
assert_has_component "  'permission denied'" "permission denied" "actionable_detail"
assert_has_component "  'is not a function'" "is not a function" "actionable_detail"
assert_has_component "  'failed to'" "failed to initialize" "actionable_detail"

echo ""
echo "Fix Suggestion Detection:"
assert_has_component "  'try' keyword" "try installing package" "fix_suggestion"
assert_has_component "  'check' keyword" "check your config" "fix_suggestion"
assert_has_component "  'ensure' keyword" "ensure NODE_ENV is set" "fix_suggestion"
assert_has_component "  'run' keyword" "run npm install first" "fix_suggestion"
assert_has_component "  'remove' keyword" "remove the cache" "fix_suggestion"

echo ""
echo "Score Calculations:"
assert_score "  all 5 components" "/path/file.sh:42: TypeError: cannot read property, try fixing" "100"
assert_score "  3 components" "file.sh:10: error with detail" "85"
assert_score "  1 component only" "something failed" "20"
assert_score "  no components" "oops" "0"

echo ""
echo "Enhancement Thresholds:"
assert_needs_enhancement "  high score (>=70)" "/path/file.sh:42: TypeError: cannot read, try fixing" "false"
assert_needs_enhancement "  low score (<70)" "bad error" "true"
assert_needs_enhancement "  borderline (70)" "file.sh:42: something" "false"

echo ""
echo "Error Categorization:"
assert_contains_category "  FILE_ACCESS" "cannot read file" "FILE_ACCESS"
assert_contains_category "  FUNCTION_ERROR" "is not a function" "FUNCTION_ERROR"
assert_contains_category "  SYNTAX_ERROR" "unexpected token" "SYNTAX_ERROR"
assert_contains_category "  TYPE_ERROR" "is not a valid type" "TYPE_ERROR"
assert_contains_category "  ASSERTION_FAILURE" "assertion failed" "ASSERTION_FAILURE"
assert_contains_category "  TIMEOUT" "operation timed out" "TIMEOUT"
assert_contains_category "  MEMORY_ERROR" "out of memory" "MEMORY_ERROR"
assert_contains_category "  NETWORK_ERROR" "ECONNREFUSED network" "NETWORK_ERROR"

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║  Test Summary                             ║"
echo "╚════════════════════════════════════════════╝"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
  success "All tests passed!"
  exit 0
else
  echo "✗ $FAIL test(s) failed"
  exit 1
fi
