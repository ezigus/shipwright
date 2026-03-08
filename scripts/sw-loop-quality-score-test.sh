#!/usr/bin/env bash
# Test suite for loop-quality-score.sh module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
PASS=0
FAIL=0

test_case() {
    local name="$1"
    echo -ne "  ${YELLOW}▸${NC} $name ... "
}

pass() {
    echo -e "${GREEN}✓${NC}"
    ((PASS++))
}

fail() {
    local reason="${1:-}"
    echo -e "${RED}✗${NC}"
    if [[ -n "$reason" ]]; then
        echo "    Error: $reason"
    fi
    ((FAIL++))
}

# Setup test environment
TEST_LOG_DIR="/tmp/sw-quality-score-test-$$"
mkdir -p "$TEST_LOG_DIR"
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

LOG_DIR="$TEST_LOG_DIR"
export LOG_DIR

# Source the module
source "$SCRIPT_DIR/lib/loop-quality-score.sh" || {
    echo -e "${RED}✗${NC} Failed to source loop-quality-score.sh"
    exit 1
}

# Stub helper functions
emit_event() { return 0; }
export -f emit_event

echo ""
echo -e "${YELLOW}Loop Quality Score Tests${NC}"
echo "═══════════════════════════════════════════"
echo ""

# ─── Test compute_test_delta_score ────────────────────────────────────────
echo "Test: compute_test_delta_score"

test_case "positive change scores > 50"
result=$(compute_test_delta_score 10 20)
[[ "$result" -gt 50 ]] && pass || fail "Got $result"

test_case "negative change scores < 50"
result=$(compute_test_delta_score 20 10)
[[ "$result" -lt 50 ]] && pass || fail "Got $result"

test_case "no change scores 50"
result=$(compute_test_delta_score 10 10)
[[ "$result" -eq 50 ]] && pass || fail "Got $result"

# ─── Test compute_compile_success_score ────────────────────────────────────
echo ""
echo "Test: compute_compile_success_score"

test_case "returns 100 for clean log"
echo "Build successful" > "$TEST_LOG_DIR/good.log"
result=$(compute_compile_success_score "$TEST_LOG_DIR/good.log")
[[ "$result" -eq 100 ]] && pass || fail "Got $result"

test_case "returns 0 for log with error"
echo "Compilation error: syntax error" > "$TEST_LOG_DIR/bad.log"
result=$(compute_compile_success_score "$TEST_LOG_DIR/bad.log")
[[ "$result" -eq 0 ]] && pass || fail "Got $result"

# ─── Test compute_error_reduction_score ────────────────────────────────────
echo ""
echo "Test: compute_error_reduction_score"

test_case "returns 100 when errors reduced"
result=$(compute_error_reduction_score 10 0)
[[ "$result" -eq 100 ]] && pass || fail "Got $result"

test_case "returns 0 when errors introduced"
result=$(compute_error_reduction_score 0 5)
[[ "$result" -eq 0 ]] && pass || fail "Got $result"

# ─── Test compute_code_churn_score ────────────────────────────────────────
echo ""
echo "Test: compute_code_churn_score"

test_case "returns high score for zero churn"
result=$(compute_code_churn_score 0 0 1000)
[[ "$result" -ge 90 ]] && pass || fail "Got $result"

# ─── Test compute_iteration_quality_score ──────────────────────────────────
echo ""
echo "Test: compute_iteration_quality_score"

test_case "returns valid score 0-100"
echo "Test results: 10 passed, 0 failed" > "$TEST_LOG_DIR/tests.log"
result=$(compute_iteration_quality_score 1 "$TEST_LOG_DIR/tests.log" true)
[[ "$result" =~ ^[0-9]+$ && "$result" -ge 0 && "$result" -le 100 ]] && pass || fail "Got $result"

test_case "logs to quality-scores.jsonl"
echo "Test passed" > "$TEST_LOG_DIR/tests2.log"
compute_iteration_quality_score 2 "$TEST_LOG_DIR/tests2.log" true > /dev/null
[[ -f "$TEST_LOG_DIR/quality-scores.jsonl" ]] && pass || fail "File not created"

# ─── Test should_adapt_prompt ─────────────────────────────────────────────
echo ""
echo "Test: should_adapt_prompt"

test_case "triggers for score < 30"
should_adapt_prompt 25 1 && pass || fail "Should adapt"

test_case "skips for score >= 30"
should_adapt_prompt 50 1 && fail "Should not adapt" || pass

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    exit 1
fi
