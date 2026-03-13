#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/github-rate-limit test — Unit tests for gh_safe()       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: github-rate-limit Tests"

setup_test_env "sw-lib-github-rate-limit-test"
trap cleanup_test_env EXIT

# Provide minimal helpers that github-rate-limit.sh needs
info()    { echo "$*"; }
success() { echo "$*"; }
warn()    { echo "$*" >&2; }
error()   { echo "$*" >&2; }
emit_event() { :; }

# Source the module (clear guard to re-source)
_GITHUB_RATE_LIMIT_LOADED=""
source "$SCRIPT_DIR/lib/github-rate-limit.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# _gh_is_retryable
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_gh_is_retryable — error classification"

# Timeout (exit 124)
if _gh_is_retryable 124 ""; then
    assert_pass "exit 124 (timeout) is retryable"
else
    assert_fail "exit 124 (timeout) is retryable"
fi

# HTTP 429 rate limit
if _gh_is_retryable 1 "HTTP 429 Too Many Requests"; then
    assert_pass "HTTP 429 is retryable"
else
    assert_fail "HTTP 429 is retryable"
fi

# HTTP 403 with rate limit text
if _gh_is_retryable 1 "HTTP 403 API rate limit exceeded"; then
    assert_pass "HTTP 403 rate limit is retryable"
else
    assert_fail "HTTP 403 rate limit is retryable"
fi

# Secondary rate limit
if _gh_is_retryable 1 "secondary rate limit"; then
    assert_pass "secondary rate limit is retryable"
else
    assert_fail "secondary rate limit is retryable"
fi

# HTTP 502 server error
if _gh_is_retryable 1 "HTTP 502 Bad Gateway"; then
    assert_pass "HTTP 502 is retryable"
else
    assert_fail "HTTP 502 is retryable"
fi

# HTTP 503 server error
if _gh_is_retryable 1 "HTTP 503 Service Unavailable"; then
    assert_pass "HTTP 503 is retryable"
else
    assert_fail "HTTP 503 is retryable"
fi

# HTTP 401 should fail fast
if _gh_is_retryable 1 "HTTP 401 Unauthorized"; then
    assert_fail "HTTP 401 should NOT be retryable"
else
    assert_pass "HTTP 401 is not retryable (fail fast)"
fi

# HTTP 404 should fail fast
if _gh_is_retryable 1 "HTTP 404 Not Found"; then
    assert_fail "HTTP 404 should NOT be retryable"
else
    assert_pass "HTTP 404 is not retryable (fail fast)"
fi

# HTTP 422 should fail fast
if _gh_is_retryable 1 "HTTP 422 Unprocessable Entity"; then
    assert_fail "HTTP 422 should NOT be retryable"
else
    assert_pass "HTTP 422 is not retryable (fail fast)"
fi

# Generic non-zero exit (network error) should be retryable
if _gh_is_retryable 1 "connection refused"; then
    assert_pass "generic failure is retryable"
else
    assert_fail "generic failure is retryable"
fi

# Exit 0 is not retryable
if _gh_is_retryable 0 ""; then
    assert_fail "exit 0 should NOT be retryable"
else
    assert_pass "exit 0 is not retryable"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# _gh_parse_retry_after
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_gh_parse_retry_after — header parsing"

result=$(_gh_parse_retry_after "retry-after: 60")
assert_eq "parses retry-after: 60" "60" "$result"

result=$(_gh_parse_retry_after "Retry-After: 120")
assert_eq "parses Retry-After: 120 (case insensitive)" "120" "$result"

result=$(_gh_parse_retry_after "some random output without header")
assert_eq "returns empty when no retry-after header" "" "$result"

result=$(_gh_parse_retry_after "")
assert_eq "returns empty for empty input" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# gh_safe — success case
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "gh_safe — success path"

# Reset config cache
_GH_RL_MAX_RETRIES=""
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

# Mock gh that succeeds
mock_binary "gh" 'echo "success output"; exit 0'

result=$(gh_safe gh api test 2>/dev/null)
assert_eq "gh_safe returns output on success" "success output" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# gh_safe — retryable failure then success
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "gh_safe — retry behavior"

# Reset state
_GH_RL_MAX_RETRIES=""
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

# Mock gh that fails with 502 once then succeeds
ATTEMPT_FILE="$TEST_TEMP_DIR/attempt_count"
echo "0" > "$ATTEMPT_FILE"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
count=\$(cat "$ATTEMPT_FILE")
count=\$((count + 1))
echo "\$count" > "$ATTEMPT_FILE"
if [[ "\$count" -eq 1 ]]; then
    echo "HTTP 502 Bad Gateway" >&2
    exit 1
fi
echo "retry success"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Override backoff to 0 for fast tests
_GH_RL_MAX_RETRIES=3
_GH_RL_BASE_BACKOFF=0
_GH_RL_MAX_BACKOFF=0
_GH_RL_BACKOFF_MULTIPLIER=1
_GH_RL_CB_FAILURES=10

result=$(gh_safe gh api test 2>/dev/null)
attempts=$(cat "$ATTEMPT_FILE")
assert_eq "retries on 502 then succeeds" "retry success" "$result"
assert_eq "made 2 attempts (1 fail + 1 success)" "2" "$attempts"

# ═══════════════════════════════════════════════════════════════════════════════
# gh_safe — non-retryable error fails fast
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "gh_safe — fail fast on 404"

# Reset state
_GH_RL_MAX_RETRIES=""
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

echo "0" > "$ATTEMPT_FILE"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
count=\$(cat "$ATTEMPT_FILE")
count=\$((count + 1))
echo "\$count" > "$ATTEMPT_FILE"
echo "HTTP 404 Not Found"
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

_GH_RL_MAX_RETRIES=3
_GH_RL_BASE_BACKOFF=0
_GH_RL_MAX_BACKOFF=0
_GH_RL_BACKOFF_MULTIPLIER=1
_GH_RL_CB_FAILURES=10

exit_code=0
gh_safe gh api test 2>/dev/null || exit_code=$?
attempts=$(cat "$ATTEMPT_FILE")
assert_eq "404 fails fast — only 1 attempt" "1" "$attempts"
if [[ "$exit_code" -ne 0 ]]; then
    assert_pass "404 returns non-zero exit code"
else
    assert_fail "404 returns non-zero exit code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# gh_safe — exhausted retries
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "gh_safe — exhausted retries"

_GH_RL_MAX_RETRIES=""
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

echo "0" > "$ATTEMPT_FILE"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
count=\$(cat "$ATTEMPT_FILE")
count=\$((count + 1))
echo "\$count" > "$ATTEMPT_FILE"
echo "HTTP 503 Service Unavailable"
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

_GH_RL_MAX_RETRIES=3
_GH_RL_BASE_BACKOFF=0
_GH_RL_MAX_BACKOFF=0
_GH_RL_BACKOFF_MULTIPLIER=1
_GH_RL_CB_FAILURES=10

exit_code=0
gh_safe gh api test 2>/dev/null || exit_code=$?
attempts=$(cat "$ATTEMPT_FILE")
assert_eq "exhausted all 3 attempts" "3" "$attempts"
if [[ "$exit_code" -ne 0 ]]; then
    assert_pass "returns failure after exhausting retries"
else
    assert_fail "returns failure after exhausting retries"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Circuit breaker — local fallback
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Circuit breaker — local fallback"

_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

# Circuit breaker should not be tripped initially
if _gh_safe_circuit_check; then
    assert_fail "circuit breaker should be closed initially"
else
    assert_pass "circuit breaker is closed initially"
fi

# Trip the circuit breaker by setting backoff_until to the future
_GH_SAFE_BACKOFF_UNTIL=$(( $(date +%s) + 9999 ))
if _gh_safe_circuit_check; then
    assert_pass "circuit breaker is open after setting backoff_until"
else
    assert_fail "circuit breaker is open after setting backoff_until"
fi

# Reset
_GH_SAFE_BACKOFF_UNTIL=0
_GH_SAFE_CONSECUTIVE_FAILURES=0

# ═══════════════════════════════════════════════════════════════════════════════
# Config loading defaults
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Config loading — defaults when config.sh unavailable"

# Clear cached config
_GH_RL_MAX_RETRIES=""

# Unset _config_get_int to test fallback defaults
if type _config_get_int >/dev/null 2>&1; then
    # Save and temporarily undefine
    eval "$(declare -f _config_get_int | sed 's/_config_get_int/_config_get_int_SAVED/')"
    unset -f _config_get_int 2>/dev/null || true
    _gh_rl_load_config
    eval "$(declare -f _config_get_int_SAVED | sed 's/_config_get_int_SAVED/_config_get_int/')"
    unset -f _config_get_int_SAVED 2>/dev/null || true
else
    _gh_rl_load_config
fi

assert_eq "default max_retries is 4" "4" "$_GH_RL_MAX_RETRIES"
assert_eq "default base_backoff is 2" "2" "$_GH_RL_BASE_BACKOFF"
assert_eq "default max_backoff is 300" "300" "$_GH_RL_MAX_BACKOFF"
assert_eq "default multiplier is 2" "2" "$_GH_RL_BACKOFF_MULTIPLIER"
assert_eq "default circuit_breaker_failures is 3" "3" "$_GH_RL_CB_FAILURES"

# ═══════════════════════════════════════════════════════════════════════════════
# gh_with_retry backward compatibility
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Backward compatibility — gh_with_retry"

# Reset state
_GH_RL_MAX_RETRIES=""
_GH_SAFE_CONSECUTIVE_FAILURES=0
_GH_SAFE_BACKOFF_UNTIL=0

# Source helpers.sh to get gh_with_retry
_SW_HELPERS_LOADED=""
source "$SCRIPT_DIR/lib/helpers.sh"

mock_binary "gh" 'echo "compat output"; exit 0'

result=$(gh_with_retry 3 gh api test 2>/dev/null)
assert_eq "gh_with_retry delegates to gh_safe" "compat output" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
