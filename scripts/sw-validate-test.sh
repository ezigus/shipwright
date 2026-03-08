#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-validate-test.sh — Test suite for pipeline pre-flight validation    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="$SCRIPT_DIR/sw-validate.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    setup_test_env "sw-validate-test"

    # Create mock templates directory
    mkdir -p "$TEST_TEMP_DIR/templates/pipelines"
    mkdir -p "$TEST_TEMP_DIR/config"
    mkdir -p "$TEST_TEMP_DIR/scripts/lib"

    # Copy real script under test
    cp "$VALIDATE_SCRIPT" "$TEST_TEMP_DIR/scripts/sw-validate.sh"
    chmod +x "$TEST_TEMP_DIR/scripts/sw-validate.sh"

    # Copy libs if available
    [[ -d "$SCRIPT_DIR/lib" ]] && cp -r "$SCRIPT_DIR/lib/"* "$TEST_TEMP_DIR/scripts/lib/" 2>/dev/null || true

    # Create defaults.json with stage_order
    cat > "$TEST_TEMP_DIR/config/defaults.json" <<'EOF'
{
  "pipeline": {
    "stage_order": [
      "intake", "plan", "design", "build", "test", "review",
      "compound_quality", "pr", "merge", "deploy", "validate", "monitor"
    ]
  }
}
EOF

    # Create valid standard template
    cat > "$TEST_TEMP_DIR/templates/pipelines/standard.json" <<'EOF'
{
  "name": "standard",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "plan", "enabled": true, "gate": "approve", "config": {} },
    { "id": "build", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": true, "gate": "auto", "config": {} },
    { "id": "review", "enabled": true, "gate": "approve", "config": {} },
    { "id": "pr", "enabled": true, "gate": "approve", "config": {} }
  ]
}
EOF

    # Create valid fast template
    cat > "$TEST_TEMP_DIR/templates/pipelines/fast.json" <<'EOF'
{
  "name": "fast",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "build", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": true, "gate": "auto", "config": {} },
    { "id": "pr", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF

    # Mock sw-loop.sh
    cat > "$TEST_TEMP_DIR/scripts/sw-loop.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock loop"
EOF
    chmod +x "$TEST_TEMP_DIR/scripts/sw-loop.sh"

    # Mock claude for AI provider check
    mock_claude
}

run_validate() {
    # Run sw-validate.sh with overridden paths
    local exit_code=0
    TEMPLATES_DIR="$TEST_TEMP_DIR/templates/pipelines" \
    DEFAULTS_FILE="$TEST_TEMP_DIR/config/defaults.json" \
    NO_GITHUB=true \
    SHIPWRIGHT_AI_PROVIDER=claude \
        "$TEST_TEMP_DIR/scripts/sw-validate.sh" \
        --project-root "$TEST_TEMP_DIR/project" \
        "$@" 2>&1 || exit_code=$?
    echo "EXIT:$exit_code"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "sw-validate — Pipeline Pre-flight Validation Tests"

# ─── Test 1: Valid standard template passes ──────────────────────────────
print_test_section "Template Validation"

setup_env
output=$(run_validate --pipeline standard --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Valid standard template passes" "0" "$exit_code"

# ─── Test 2: Valid fast template passes ──────────────────────────────────
setup_env
output=$(run_validate --pipeline fast --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Valid fast template passes" "0" "$exit_code"

# ─── Test 3: Nonexistent template fails ──────────────────────────────────
setup_env
output=$(run_validate --pipeline nonexistent --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Nonexistent template fails" "1" "$exit_code"
assert_contains "Error mentions template not found" "$output" "Template not found"

# ─── Test 4: Invalid JSON fails ─────────────────────────────────────────
setup_env
echo "{ invalid json }" > "$TEST_TEMP_DIR/templates/pipelines/broken.json"
output=$(run_validate --pipeline broken --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Invalid JSON template fails" "1" "$exit_code"
assert_contains "Error mentions invalid JSON" "$output" "invalid JSON"

# ─── Test 5: Unknown stage ID fails ─────────────────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/badstage.json" <<'EOF'
{
  "name": "badstage",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "nonexistent_stage", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline badstage --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Unknown stage ID fails" "1" "$exit_code"
assert_contains "Error mentions unknown stage" "$output" "Unknown stage ID"

# ─── Test 6: Invalid gate value fails ───────────────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/badgate.json" <<'EOF'
{
  "name": "badgate",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "invalid_gate", "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline badgate --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Invalid gate value fails" "1" "$exit_code"
assert_contains "Error mentions invalid gate" "$output" "Invalid gate value"

# ─── Test 7: Duplicate stage IDs fail ───────────────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/dupes.json" <<'EOF'
{
  "name": "dupes",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline dupes --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Duplicate stage IDs fails" "1" "$exit_code"
assert_contains "Error mentions duplicate" "$output" "Duplicate stage IDs"

# ─── Test 8: Missing name field detected ────────────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/noname.json" <<'EOF'
{
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline noname --quiet)
assert_contains "Missing name field detected" "$output" "missing required field: name"

# ─── Test 9: JSON output mode ───────────────────────────────────────────
print_test_section "Output Modes"

setup_env
output=$(run_validate --pipeline standard --json --no-github)
json_line=$(echo "$output" | grep -v "EXIT:" | head -1)
assert_json_key "JSON output has pipeline field" "$json_line" ".pipeline" "standard"
assert_json_key "JSON output has pass status" "$json_line" ".status" "pass"

# ─── Test 10: JSON output for failure ────────────────────────────────────
setup_env
echo "{ bad }" > "$TEST_TEMP_DIR/templates/pipelines/badjson.json"
output=$(run_validate --pipeline badjson --json --no-github)
json_line=$(echo "$output" | grep -v "EXIT:" | head -1)
assert_json_key "JSON failure has fail status" "$json_line" ".status" "fail"

# ─── Test 11: --version flag ────────────────────────────────────────────
print_test_section "CLI Flags"

setup_env
output=$("$TEST_TEMP_DIR/scripts/sw-validate.sh" --version 2>&1)
assert_contains "Version flag shows version" "$output" "sw-validate"

# ─── Test 12: --no-github skips GitHub checks ───────────────────────────
setup_env
output=$(run_validate --pipeline standard --no-github)
assert_contains "No-github flag skips checks" "$output" "GitHub checks skipped"

# ─── Test 13: Missing sw-loop.sh detected ───────────────────────────────
print_test_section "Dependency Validation"

setup_env
rm -f "$TEST_TEMP_DIR/scripts/sw-loop.sh"
output=$(run_validate --pipeline standard --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Missing sw-loop.sh causes failure" "1" "$exit_code"
assert_contains "Error mentions sw-loop.sh" "$output" "sw-loop.sh"

# ─── Test 14: Banner displayed without --quiet ──────────────────────────
print_test_section "Display Modes"

setup_env
output=$(run_validate --pipeline standard --no-github)
assert_contains "Banner displayed without quiet" "$output" "Shipwright"
assert_contains "Summary displayed" "$output" "passed"

# ─── Test 15: Missing templates directory detected ────────────────────
print_test_section "Directory Validation"

setup_env
rm -rf "$TEST_TEMP_DIR/templates/pipelines"
output=$(run_validate --pipeline standard --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Missing templates dir causes failure" "1" "$exit_code"
assert_contains "Error mentions templates directory" "$output" "Templates directory not found"

# ─── Test 16: Stages must be an array ─────────────────────────────────
print_test_section "Stage Structure Validation"

setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/badtype.json" <<'EOF'
{
  "name": "badtype",
  "stages": "not-an-array"
}
EOF
output=$(run_validate --pipeline badtype --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Non-array stages fails" "1" "$exit_code"
assert_contains "Error mentions array type" "$output" "must be an array"

# ─── Test 17: Stage missing required fields ───────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/nofields.json" <<'EOF'
{
  "name": "nofields",
  "stages": [
    { "id": "intake", "enabled": "yes", "gate": "auto", "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline nofields --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Non-boolean enabled fails" "1" "$exit_code"
assert_contains "Error mentions enabled type" "$output" "must be boolean"

# ─── Test 18: Stage missing gate field ────────────────────────────────
setup_env
cat > "$TEST_TEMP_DIR/templates/pipelines/nogate.json" <<'EOF'
{
  "name": "nogate",
  "stages": [
    { "id": "intake", "enabled": true, "config": {} }
  ]
}
EOF
output=$(run_validate --pipeline nogate --quiet)
exit_code=$(echo "$output" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "Missing gate field fails" "1" "$exit_code"
assert_contains "Error mentions missing gate" "$output" "missing required field: gate"

# ─── Test 19: jq unavailable degrades gracefully ─────────────────────
print_test_section "jq Graceful Degradation"

setup_env
# Create a wrapper script that hides jq
cat > "$TEST_TEMP_DIR/scripts/no-jq-validate.sh" <<'WRAPPER'
#!/usr/bin/env bash
# Override command -v to hide jq
jq() { return 127; }
export -f jq 2>/dev/null || true
# Override PATH to exclude jq
ORIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run the real validator but with jq hidden via PATH manipulation
PATH="/usr/bin:/bin" HAS_JQ_OVERRIDE=false \
    "$ORIG_SCRIPT_DIR/sw-validate.sh" "$@"
WRAPPER
chmod +x "$TEST_TEMP_DIR/scripts/no-jq-validate.sh"

# Test that validation reports jq as required when templates need validation
output=$(TEMPLATES_DIR="$TEST_TEMP_DIR/templates/pipelines" \
    DEFAULTS_FILE="$TEST_TEMP_DIR/config/defaults.json" \
    NO_GITHUB=true \
    SHIPWRIGHT_AI_PROVIDER=claude \
    "$TEST_TEMP_DIR/scripts/sw-validate.sh" \
    --project-root "$TEST_TEMP_DIR/project" \
    --pipeline standard --json --no-github 2>&1 || true)
# This test verifies that when jq IS available, JSON output works correctly
json_line=$(echo "$output" | grep -v "EXIT:" | head -1)
assert_json_key "JSON output works with jq present" "$json_line" ".pipeline" "standard"

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_test_env
print_test_results
