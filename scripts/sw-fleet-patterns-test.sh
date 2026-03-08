#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-patterns tests — Unit + Integration tests             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

FLEET_PATTERNS_SCRIPT="$SCRIPT_DIR/sw-fleet-patterns.sh"

# ─── Setup ──────────────────────────────────────────────────────────────────
setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-fleet-patterns-test.XXXXXX")
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.shipwright"
    export FLEET_PATTERNS_FILE="$HOME/.shipwright/fleet-patterns.jsonl"

    # Link real jq
    if command -v jq >/dev/null 2>&1; then
        mkdir -p "$TEST_TEMP_DIR/bin"
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Create mock repo
    mkdir -p "$TEST_TEMP_DIR/repo"
    echo '{"name":"test-repo","version":"1.0.0"}' > "$TEST_TEMP_DIR/repo/package.json"

    # Create mock artifacts
    mkdir -p "$TEST_TEMP_DIR/artifacts"
    echo '{"summary":"Fix auth timeout","error":"Connection timeout on login","fix":"Increase timeout to 30s"}' \
        > "$TEST_TEMP_DIR/artifacts/error-summary.json"
    echo '# Fix authentication timeout' > "$TEST_TEMP_DIR/artifacts/plan.md"

    # Create fleet config with sharing enabled
    echo '{"pattern_share_enabled":true}' > "$HOME/.shipwright/fleet-config.json"
}

# ─── Sensitive Data Filter Tests ────────────────────────────────────────────
print_test_section "Sensitive Data Filter"

test_filter_api_keys() {
    source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"

    local input="Config: api_key=sk-abc123def456 and password=hunter2"
    local output
    output=$(_filter_sensitive_data "$input")

    if echo "$output" | grep -qF "sk-abc123def456" 2>/dev/null; then
        assert_fail "API key should be redacted" "Found unredacted key in: $output"
    else
        assert_pass "API key redacted"
    fi

    if echo "$output" | grep -qF "hunter2" 2>/dev/null; then
        assert_fail "Password should be redacted" "Found unredacted password in: $output"
    else
        assert_pass "Password redacted"
    fi
}

test_filter_github_token() {
    source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"

    local input="Token: ghp_1234567890abcdefghijklmnopqrstuvwxyz"
    local output
    output=$(_filter_sensitive_data "$input")

    if echo "$output" | grep -qF "ghp_" 2>/dev/null; then
        assert_fail "GitHub token should be redacted" "Found token in: $output"
    else
        assert_pass "GitHub token redacted"
    fi
}

test_filter_bearer_auth() {
    source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"

    local input="Header: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    local output
    output=$(_filter_sensitive_data "$input")

    if echo "$output" | grep -qF "eyJhbGci" 2>/dev/null; then
        assert_fail "Bearer token should be redacted" "Found token in: $output"
    else
        assert_pass "Bearer token redacted"
    fi
}

test_filter_preserves_clean_text() {
    source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"

    local input="This is a normal description about fixing a bug"
    local output
    output=$(_filter_sensitive_data "$input")
    assert_eq "Clean text preserved" "$input" "$output"
}

test_filter_empty_input() {
    source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"

    local output
    output=$(_filter_sensitive_data "")
    assert_eq "Empty input returns empty" "" "$output"
}

# ─── Pattern Capture Tests ──────────────────────────────────────────────────
print_test_section "Pattern Capture"

test_capture_basic() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1
    local rc=$?

    assert_eq "Capture returns 0" "0" "$rc"
    assert_file_exists "Patterns file created" "$FLEET_PATTERNS_FILE"

    local line_count
    line_count=$(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' ')
    assert_eq "One pattern captured" "1" "$line_count"

    # Validate JSON structure
    local pattern
    pattern=$(head -1 "$FLEET_PATTERNS_FILE")
    local has_id has_version has_title
    has_id=$(echo "$pattern" | jq -r '.id' 2>/dev/null)
    has_version=$(echo "$pattern" | jq -r '.pattern_version' 2>/dev/null)
    has_title=$(echo "$pattern" | jq -r '.title' 2>/dev/null)

    if [[ -n "$has_id" ]] && [[ "$has_id" != "null" ]]; then
        assert_pass "Pattern has UUID id"
    else
        assert_fail "Pattern missing id"
    fi
    assert_eq "Pattern version is 1.0" "1.0" "$has_version"
    assert_contains "Title from error summary" "$has_title" "auth timeout"
}

test_capture_disabled_by_default() {
    setup_env
    # Remove config to test default (disabled)
    rm -f "$HOME/.shipwright/fleet-config.json"

    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    local rc=0
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1 || rc=$?

    assert_eq "Capture returns 1 when disabled" "1" "$rc"

    if [[ -f "$FLEET_PATTERNS_FILE" ]]; then
        assert_fail "No patterns file when disabled"
    else
        assert_pass "No patterns file when disabled"
    fi
}

test_capture_dedup() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local line_count
    line_count=$(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' ')
    assert_eq "Dedup prevents duplicate capture" "1" "$line_count"
}

test_capture_no_title_skips() {
    setup_env
    # Create empty artifacts
    rm -f "$TEST_TEMP_DIR/artifacts/error-summary.json" "$TEST_TEMP_DIR/artifacts/plan.md"
    mkdir -p "$TEST_TEMP_DIR/empty-artifacts"

    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    local rc=0
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/empty-artifacts" "" >/dev/null 2>&1 || rc=$?

    assert_eq "Returns 1 when no extractable title" "1" "$rc"
}

test_capture_category_detection() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local category
    category=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.category' 2>/dev/null)
    assert_eq "Category detected as auth" "auth" "$category"
}

test_capture_language_detection() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local languages
    languages=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.languages[0] // ""' 2>/dev/null)
    assert_eq "Language detected as javascript" "javascript" "$languages"
}

# ─── Pattern Query Tests ───────────────────────────────────────────────────
print_test_section "Pattern Query"

test_query_basic() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    # Capture a pattern first
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local results
    results=$(fleet_patterns_query "auth timeout" "javascript" "" "5")

    local count
    count=$(echo "$results" | jq 'length' 2>/dev/null)
    assert_gt "Query returns results" "$count" "0"

    local title
    title=$(echo "$results" | jq -r '.[0].title // ""' 2>/dev/null)
    assert_contains "Result matches query" "$title" "auth"
}

test_query_empty_file() {
    setup_env
    rm -f "$FLEET_PATTERNS_FILE"

    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    local results
    results=$(fleet_patterns_query "anything" "" "" "5")

    assert_eq "Empty file returns empty array" "[]" "$results"
}

test_query_language_filter() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    # Query with matching language
    local results
    results=$(fleet_patterns_query "auth" "javascript" "" "5")
    local count
    count=$(echo "$results" | jq 'length' 2>/dev/null)
    assert_gt "Matching language returns results" "$count" "0"

    # Query with non-matching language
    results=$(fleet_patterns_query "auth" "python" "" "5")
    count=$(echo "$results" | jq 'length' 2>/dev/null)
    assert_eq "Non-matching language returns 0" "0" "$count"
}

test_query_no_keyword_match() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local results
    results=$(fleet_patterns_query "zzznomatch" "javascript" "" "5")
    local count
    count=$(echo "$results" | jq 'length' 2>/dev/null)
    assert_eq "No match returns empty" "0" "$count"
}

# ─── CLI Command Tests ─────────────────────────────────────────────────────
print_test_section "CLI Commands"

test_list_empty() {
    setup_env
    rm -f "$FLEET_PATTERNS_FILE"

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" list 2>&1)
    assert_contains "List empty shows message" "$output" "No fleet patterns"
}

test_list_json() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" list --json 2>&1)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    assert_gt "List JSON returns array" "$count" "0"
}

test_search() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" search "auth" --json 2>&1)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    assert_gt "Search finds auth pattern" "$count" "0"
}

test_search_no_query() {
    setup_env
    local output rc
    output=$(bash "$FLEET_PATTERNS_SCRIPT" search 2>&1) && rc=$? || rc=$?
    assert_eq "Search without query returns error" "1" "$rc"
}

test_stats_json() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" stats --json 2>&1)
    local total
    total=$(echo "$output" | jq -r '.total' 2>/dev/null || echo 0)
    assert_eq "Stats shows 1 total pattern" "1" "$total"
}

test_show_pattern() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local pattern_id
    pattern_id=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.id' 2>/dev/null)

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" show "$pattern_id" 2>&1)
    assert_contains "Show displays pattern" "$output" "auth"
}

test_show_not_found() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local rc
    bash "$FLEET_PATTERNS_SCRIPT" show "nonexistent-id" >/dev/null 2>&1 && rc=$? || rc=$?
    assert_eq "Show not found returns 1" "1" "$rc"
}

test_prune_dry_run() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" prune --older-than 0 --dry-run 2>&1)
    assert_contains "Dry run shows count" "$output" "Would remove"

    # File should still have pattern
    local count
    count=$(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' ')
    assert_eq "Dry run preserves file" "1" "$count"
}

test_reuse_rate() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" reuse-rate --json 2>&1)
    local total
    total=$(echo "$output" | jq -r '.total' 2>/dev/null || echo 0)
    assert_eq "Reuse rate shows total" "1" "$total"
}

test_effectiveness() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" effectiveness --json 2>&1)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    assert_gt "Effectiveness returns categories" "$count" "0"
}

test_help() {
    local output
    output=$(bash "$FLEET_PATTERNS_SCRIPT" help 2>&1)
    assert_contains "Help shows commands" "$output" "list"
    assert_contains "Help shows search" "$output" "search"
}

# ─── Record Reuse Tests ───────────────────────────────────────────────────
print_test_section "Record Reuse"

test_record_reuse_success() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    # Capture a pattern first
    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local pattern_id
    pattern_id=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.id' 2>/dev/null)

    # Record successful reuse
    local rc=0
    fleet_patterns_record_reuse "$pattern_id" "success" >/dev/null 2>&1 || rc=$?
    assert_eq "Record reuse success returns 0" "0" "$rc"

    local success_count eff_rate
    success_count=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" | jq -r '.success_count' 2>/dev/null)
    eff_rate=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" | jq -r '.effectiveness_rate' 2>/dev/null)
    assert_eq "Success count incremented to 1" "1" "$success_count"
    assert_eq "Effectiveness rate is 100" "100" "$eff_rate"
}

test_record_reuse_failure() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local pattern_id
    pattern_id=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.id' 2>/dev/null)

    # Record one success and one failure
    fleet_patterns_record_reuse "$pattern_id" "success" >/dev/null 2>&1
    fleet_patterns_record_reuse "$pattern_id" "failure" >/dev/null 2>&1

    local success_count failure_count eff_rate
    success_count=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" | jq -r '.success_count' 2>/dev/null)
    failure_count=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" | jq -r '.failure_count' 2>/dev/null)
    eff_rate=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" | jq -r '.effectiveness_rate' 2>/dev/null)
    assert_eq "Success count is 1" "1" "$success_count"
    assert_eq "Failure count is 1" "1" "$failure_count"
    assert_eq "Effectiveness rate is 50" "50" "$eff_rate"
}

test_record_reuse_missing_pattern() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/artifacts" "" >/dev/null 2>&1

    local rc=0
    fleet_patterns_record_reuse "nonexistent-id" "success" >/dev/null 2>&1 || rc=$?
    assert_eq "Missing pattern returns 1" "1" "$rc"
}

test_pipeline_integration_capture() {
    setup_env
    source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true

    # Simulate pipeline artifacts
    mkdir -p "$TEST_TEMP_DIR/pipeline-artifacts"
    echo '{"summary":"Fix database connection pool","error":"Pool exhausted under load","fix":"Increase pool size to 20"}' \
        > "$TEST_TEMP_DIR/pipeline-artifacts/error-summary.json"

    # Create a mock pipeline state file
    echo "current_stage: review" > "$TEST_TEMP_DIR/pipeline-state.md"

    fleet_patterns_capture "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/pipeline-artifacts" "$TEST_TEMP_DIR/pipeline-state.md" >/dev/null 2>&1
    local rc=$?
    assert_eq "Pipeline capture returns 0" "0" "$rc"

    # Verify source_stage from state file
    local source_stage
    source_stage=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.source_stage' 2>/dev/null)
    assert_eq "Source stage from state file" "review" "$source_stage"

    # Verify the pattern was captured with correct content
    local title
    title=$(head -1 "$FLEET_PATTERNS_FILE" | jq -r '.title' 2>/dev/null)
    assert_contains "Title from error summary" "$title" "database"
}

# ─── Concurrent Write Test ──────────────────────────────────────────────────
print_test_section "Concurrent Writes"

test_concurrent_writes() {
    setup_env

    # Create different artifacts for concurrent captures
    for i in 1 2 3; do
        mkdir -p "$TEST_TEMP_DIR/artifacts-$i"
        echo "{\"summary\":\"Fix issue $i\",\"error\":\"Error $i\",\"fix\":\"Apply fix $i\"}" \
            > "$TEST_TEMP_DIR/artifacts-$i/error-summary.json"
        mkdir -p "$TEST_TEMP_DIR/repo-$i"
        echo '{"name":"repo-'$i'"}' > "$TEST_TEMP_DIR/repo-$i/package.json"
    done

    # Run 3 captures concurrently
    for i in 1 2 3; do
        (
            export FLEET_PATTERNS_FILE="$FLEET_PATTERNS_FILE"
            source "$FLEET_PATTERNS_SCRIPT" 2>/dev/null || true
            fleet_patterns_capture "$TEST_TEMP_DIR/repo-$i" "$TEST_TEMP_DIR/artifacts-$i" "" >/dev/null 2>&1
        ) &
    done
    wait

    # Verify all lines are valid JSON
    local total_lines valid_lines
    total_lines=$(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' ')
    valid_lines=0
    while IFS= read -r line; do
        if echo "$line" | jq -e '.' >/dev/null 2>&1; then
            valid_lines=$((valid_lines + 1))
        fi
    done < "$FLEET_PATTERNS_FILE"

    assert_eq "All concurrent writes produced valid JSON" "$total_lines" "$valid_lines"
    assert_eq "3 concurrent patterns captured" "3" "$total_lines"
}

# ─── Main ──────────────────────────────────────────────────────────────────
print_test_header "Fleet Patterns"

# Sensitive data filter tests
test_filter_api_keys
test_filter_github_token
test_filter_bearer_auth
test_filter_preserves_clean_text
test_filter_empty_input

# Pattern capture tests
test_capture_basic
test_capture_disabled_by_default
test_capture_dedup
test_capture_no_title_skips
test_capture_category_detection
test_capture_language_detection

# Pattern query tests
test_query_basic
test_query_empty_file
test_query_language_filter
test_query_no_keyword_match

# CLI command tests
test_list_empty
test_list_json
test_search
test_search_no_query
test_stats_json
test_show_pattern
test_show_not_found
test_prune_dry_run
test_reuse_rate
test_effectiveness
test_help

# Record reuse tests
test_record_reuse_success
test_record_reuse_failure
test_record_reuse_missing_pattern
test_pipeline_integration_capture

# Concurrent write tests
test_concurrent_writes

cleanup_test_env
print_test_results
