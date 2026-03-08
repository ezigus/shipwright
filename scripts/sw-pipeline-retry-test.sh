#!/bin/bash
# sw-pipeline-retry-test.sh — Test suite for pipeline-level intelligent retry with failure classification
# Tests 6-class taxonomy, retry strategies, backoff calculations, and integration with run_stage_with_retry

set -euo pipefail

VERSION="0.1.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'
BOLD='\033[1m'

# Test counters
PASS=0
FAIL=0
SKIP=0

# Helpers for test output
test_header() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━ $1 ━━━${RESET}"
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} $msg"
        return 0
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} $msg"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        return 1
    fi
}

assert_true() {
    local condition="$1"
    local msg="${2:-}"
    if eval "$condition"; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} $msg"
        return 0
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} $msg (expected true, got false)"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} $msg"
        return 0
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} $msg (expected to contain: $needle)"
        return 1
    fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load failure-classifier library
source "$SCRIPT_DIR/lib/failure-classifier.sh"

echo ""
echo -e "${BOLD}Pipeline Retry Test Suite (v${VERSION})${RESET}"
echo "Testing 6-class failure taxonomy with per-class retry strategies"

# ─── Unit Tests: Classification Accuracy ──────────────────────────────────────

test_header "Unit Tests: Classification Accuracy (6 classes)"

test_classify_environment_error() {
    local log="ENOENT: no such file or directory"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "environment" "ENOENT error classified as environment"
}
test_classify_environment_error

test_classify_environment_missing_module() {
    local log="MODULE_NOT_FOUND: Cannot find module '@babel/core'"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "environment" "Missing module classified as environment"
}
test_classify_environment_missing_module

test_classify_transient_network_rate_limit() {
    local log="Error: 429 Too Many Requests"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "transient_network" "429 error classified as transient_network"
}
test_classify_transient_network_rate_limit

test_classify_transient_network_timeout() {
    local log="Error: ETIMEDOUT - connection timeout"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "transient_network" "Timeout classified as transient_network"
}
test_classify_transient_network_timeout

test_classify_context_exhaustion() {
    local log="Error: context window exceeded, max iterations reached"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "context_exhaustion" "Context exhaustion error classified correctly"
}
test_classify_context_exhaustion

test_classify_flaky_test() {
    local log="Test failed: race condition detected, intermittent failure"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "flaky_test" "Flaky test classified correctly"
}
test_classify_flaky_test

test_classify_code_bug() {
    local log="TypeError: Cannot read property 'name' of undefined"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "code_bug" "TypeError classified as code_bug"
}
test_classify_code_bug

test_classify_code_bug_syntax() {
    local log="SyntaxError: Unexpected token } on line 42"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "code_bug" "SyntaxError classified as code_bug"
}
test_classify_code_bug_syntax

test_classify_unknown() {
    local log="Something went wrong but we don't know what"
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "unknown" "Unknown error classified as unknown"
}
test_classify_unknown

test_classify_empty_log() {
    local log=""
    local result
    result=$(classify_failure_from_log "$log")
    assert_equals "$result" "unknown" "Empty log classified as unknown"
}
test_classify_empty_log

# ─── Strategy Tests: get_retry_strategy() ────────────────────────────────────

test_header "Strategy Tests: Retry Strategy JSON Structure"

test_strategy_environment() {
    local strategy
    strategy=$(get_retry_strategy "environment")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "skip" "environment strategy has action=skip"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "0" "environment strategy has max_retries=0"
}
test_strategy_environment

test_strategy_transient_network() {
    local strategy
    strategy=$(get_retry_strategy "transient_network")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "delayed" "transient_network strategy has action=delayed"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "3" "transient_network strategy has max_retries=3"
}
test_strategy_transient_network

test_strategy_context_exhaustion() {
    local strategy
    strategy=$(get_retry_strategy "context_exhaustion")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "delayed" "context_exhaustion strategy has action=delayed"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "2" "context_exhaustion strategy has max_retries=2"
}
test_strategy_context_exhaustion

test_strategy_flaky_test() {
    local strategy
    strategy=$(get_retry_strategy "flaky_test")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "immediate" "flaky_test strategy has action=immediate"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "2" "flaky_test strategy has max_retries=2"
}
test_strategy_flaky_test

test_strategy_code_bug() {
    local strategy
    strategy=$(get_retry_strategy "code_bug")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "analysis" "code_bug strategy has action=analysis"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "1" "code_bug strategy has max_retries=1"
}
test_strategy_code_bug

test_strategy_unknown() {
    local strategy
    strategy=$(get_retry_strategy "unknown")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "delayed" "unknown strategy has action=delayed"

    local max_retries
    max_retries=$(echo "$strategy" | jq -r '.max_retries')
    assert_equals "$max_retries" "1" "unknown strategy has max_retries=1"
}
test_strategy_unknown

test_strategy_invalid_class() {
    local strategy
    strategy=$(get_retry_strategy "invalid_class")
    local action
    action=$(echo "$strategy" | jq -r '.action')
    assert_equals "$action" "delayed" "invalid class falls back to delayed"
}
test_strategy_invalid_class

# ─── Backoff Tests: get_backoff_seconds() ─────────────────────────────────────

test_header "Backoff Tests: Exponential Backoff with Jitter"

test_backoff_environment_zero() {
    local backoff
    backoff=$(get_backoff_seconds "environment" 1)
    assert_equals "$backoff" "0" "environment backoff is always 0"

    backoff=$(get_backoff_seconds "environment" 3)
    assert_equals "$backoff" "0" "environment backoff at attempt 3 is still 0"
}
test_backoff_environment_zero

test_backoff_flaky_test_immediate() {
    local backoff
    backoff=$(get_backoff_seconds "flaky_test" 1)
    # Flaky test has base_s=1, so attempt 1 → 1 + jitter (0-25% of 1)
    # Result should be 1-1 (no jitter when base is 1)
    assert_true "[[ '$backoff' -ge 1 && '$backoff' -le 1 ]]" "flaky_test attempt 1 backoff ≤ 1s"
}
test_backoff_flaky_test_immediate

test_backoff_transient_attempt_1() {
    local backoff
    backoff=$(get_backoff_seconds "transient_network" 1)
    # transient_network has base_s=30, attempt 1 → 30 + jitter (0-25% of 30 = 0-7.5)
    # Result should be 30-37
    assert_true "[[ '$backoff' -ge 30 && '$backoff' -le 37 ]]" "transient_network attempt 1 backoff 30-37s"
}
test_backoff_transient_attempt_1

test_backoff_transient_attempt_2() {
    local backoff
    backoff=$(get_backoff_seconds "transient_network" 2)
    # transient_network attempt 2 → 30 * 2^(2-1) + jitter = 60 + 0-15
    # Result should be 60-75
    assert_true "[[ '$backoff' -ge 60 && '$backoff' -le 75 ]]" "transient_network attempt 2 backoff 60-75s"
}
test_backoff_transient_attempt_2

test_backoff_code_bug_attempt_1() {
    local backoff
    backoff=$(get_backoff_seconds "code_bug" 1)
    # code_bug has base_s=5, attempt 1 → 5 + jitter (0-25% of 5 = 0-1)
    # Result should be 5-6
    assert_true "[[ '$backoff' -ge 5 && '$backoff' -le 6 ]]" "code_bug attempt 1 backoff 5-6s"
}
test_backoff_code_bug_attempt_1

test_backoff_invalid_attempt() {
    local backoff
    backoff=$(get_backoff_seconds "transient_network" 0)
    # Invalid attempt should be treated as 1
    assert_true "[[ '$backoff' -ge 30 && '$backoff' -le 37 ]]" "invalid attempt 0 treated as 1"
}
test_backoff_invalid_attempt

test_backoff_negative_attempt() {
    local backoff
    backoff=$(get_backoff_seconds "transient_network" -1)
    # Negative attempt should be treated as 1
    assert_true "[[ '$backoff' -ge 30 && '$backoff' -le 37 ]]" "negative attempt treated as 1"
}
test_backoff_negative_attempt

# ─── Contract Tests: is_retryable() ──────────────────────────────────────────

test_header "Contract Tests: is_retryable()"

test_is_retryable_environment() {
    if is_retryable "environment"; then
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} environment errors are NOT retryable (should return 1)"
    else
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} environment errors are NOT retryable"
    fi
}
test_is_retryable_environment

test_is_retryable_transient() {
    if is_retryable "transient_network"; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} transient_network errors ARE retryable"
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} transient_network errors should be retryable (return 0)"
    fi
}
test_is_retryable_transient

test_is_retryable_flaky() {
    if is_retryable "flaky_test"; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} flaky_test errors ARE retryable"
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} flaky_test errors should be retryable"
    fi
}
test_is_retryable_flaky

test_is_retryable_unknown() {
    if is_retryable "unknown"; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} unknown errors ARE retryable"
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} unknown errors should be retryable"
    fi
}
test_is_retryable_unknown

# ─── Classification Robustness ────────────────────────────────────────────────

test_header "Robustness Tests: Classification Never Fails"

test_classification_always_returns_class() {
    local logs=("ENOENT" "429" "context" "intermittent" "TypeError" "weird error" "")
    for log in "${logs[@]}"; do
        local result
        result=$(classify_failure_from_log "$log") || true
        if [[ -n "$result" ]]; then
            PASS=$((PASS + 1))
            echo -e "${GREEN}✓${RESET} classify_failure_from_log returned class for input: ${log:0:20}..."
        else
            FAIL=$((FAIL + 1))
            echo -e "${RED}✗${RESET} classify_failure_from_log returned empty for input: $log"
        fi
    done
}
test_classification_always_returns_class

# ─── Summary ──────────────────────────────────────────────────────────────────

test_header "Test Summary"

TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo -e "${GREEN}Passed: $PASS${RESET}"
if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Failed: $FAIL${RESET}"
else
    echo -e "${GREEN}Failed: $FAIL${RESET}"
fi
echo -e "Skipped: $SKIP"
echo "Total:   $TOTAL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

exit 0
