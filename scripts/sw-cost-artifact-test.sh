#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-artifact test — Cross-machine baselines fetch           ║
# ║  Exercises lib/cost/artifact-fetch.sh with a `gh` shim                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Per-test sandbox ─────────────────────────────────────────────────────────
setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/baselines"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/gh-fixtures"
    mkdir -p "$TEST_TEMP_DIR/downloads"

    # Real jq passthrough.
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # `gh` shim — routes subcommands to fixture files. Test populates fixtures
    # via env vars _GH_LIST_FIXTURE and _GH_DOWNLOAD_DIR.
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Minimal `gh` shim:
#   gh repo view --json nameWithOwner -q '.nameWithOwner'  → echoes $_GH_REPO_SLUG
#   gh api -H ... /repos/.../artifacts...                  → cats $_GH_LIST_FIXTURE
#   gh run download --name <name> --dir <dir> --repo <slug> → copies
#                                                            $_GH_DOWNLOAD_DIR/<name>/*
#                                                            into <dir>
set -e
case "${1:-}" in
    repo)
        if [[ "${2:-}" == "view" ]]; then
            echo "${_GH_REPO_SLUG:-owner/repo}"
            exit 0
        fi
        ;;
    api)
        # Skip flags; find the path argument (starts with /).
        for arg in "$@"; do
            case "$arg" in
                /*) _PATH="$arg" ;;
            esac
        done
        if [[ -n "${_GH_LIST_FIXTURE:-}" && -f "$_GH_LIST_FIXTURE" ]]; then
            cat "$_GH_LIST_FIXTURE"
            exit 0
        fi
        echo "{}"
        exit 0
        ;;
    run)
        # gh run download --name <name> --dir <dir> --repo <slug>
        _NAME=""; _DIR=""
        shift  # consume "run"
        shift  # consume "download"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) _NAME="$2"; shift 2 ;;
                --dir)  _DIR="$2";  shift 2 ;;
                --repo) shift 2 ;;
                *) shift ;;
            esac
        done
        src="${_GH_DOWNLOAD_DIR:-}/${_NAME}"
        if [[ -n "$_NAME" && -n "$_DIR" && -d "$src" ]]; then
            mkdir -p "$_DIR"
            cp -R "${src}/." "$_DIR/" 2>/dev/null || true
            exit 0
        fi
        # Simulated failure when the fixture is missing.
        exit 1
        ;;
esac
echo "" ; exit 0
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    unset NO_GITHUB
    export _GH_REPO_SLUG="acme/repo"
    export SW_BASELINE_DIR="$TEST_TEMP_DIR/home/.shipwright/baselines"
}

_test_cleanup_hook() { cleanup_test_env 2>/dev/null || true; }

# Build a fixture artifact list. Args: <output> <count>
# Generates `count` artifacts named cost-breakdown-issue-42-run-<i>-attempt-1.
make_list_fixture() {
    local out="$1"
    local count="${2:-3}"
    local i=1
    local items="["
    while [[ $i -le $count ]]; do
        local rid=$((100 + i))
        [[ $i -gt 1 ]] && items+=","
        items+="$(jq -nc \
            --arg name "cost-breakdown-issue-42-run-${rid}-attempt-1" \
            --argjson rid "$rid" \
            --arg created "2026-05-0${i}T12:00:00Z" \
            '{name: $name, id: $rid, workflow_run: {id: $rid}, created_at: $created, size_in_bytes: 1024}')"
        i=$((i + 1))
    done
    items+="]"
    jq -nc --argjson arts "$items" '{artifacts: $arts}' > "$out"
}

# Build a valid cost-breakdown.json with given schema_version. Args:
# <dir> <schema_version> [stage_cost]
make_breakdown_fixture() {
    local dir="$1"
    local sv="$2"
    local cost="${3:-0.25}"
    mkdir -p "$dir"
    jq -n \
        --argjson sv "$sv" \
        --argjson cost "$cost" \
        '{
            schema_version: $sv,
            pipeline_id: "p1",
            issue: "42",
            generated_at: "2026-05-01T00:00:00Z",
            summary: {
                total_input_tokens: 1000,
                total_output_tokens: 200,
                total_cost_usd: $cost,
                iteration_count: 1,
                stage_count: 1
            },
            by_stage: [
                {stage: "build", input_tokens: 1000, output_tokens: 200,
                 cost_usd: $cost, count: 1, models: ["sonnet"]}
            ],
            by_iteration: []
        }' > "$dir/cost-breakdown.json"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════
print_test_header "Shipwright Cross-Machine Cost-Artifact Tests"

setup_env

# Source the library under test. baselines.sh provides
# baseline_update_from_breakdown which artifact-fetch depends on.
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/cost/baselines.sh"
source "$SCRIPT_DIR/lib/cost/artifact-fetch.sh"

# ─── Test 1: cost_list_remote_breakdowns parses fixture ──────────────────────
print_test_section "cost_list_remote_breakdowns"

list_fixture="$TEST_TEMP_DIR/gh-fixtures/list.json"
make_list_fixture "$list_fixture" 3
export _GH_LIST_FIXTURE="$list_fixture"

list_out=$(cost_list_remote_breakdowns "all" 5 2>/dev/null) || list_out=""
list_count=$(printf '%s\n' "$list_out" | grep -c "cost-breakdown-issue-42-run-" || true)
if [[ "$list_count" -eq 3 ]]; then
    assert_pass "list returns all 3 fixture artifacts when filter=all"
else
    assert_fail "list returns 3 artifacts" "got ${list_count}: $list_out"
fi

# Filter by specific issue
list_out2=$(cost_list_remote_breakdowns "issue:42" 10 2>/dev/null) || list_out2=""
if [[ $(printf '%s\n' "$list_out2" | grep -c "issue\":\"42") -eq 3 ]]; then
    assert_pass "list filters by issue:42 correctly"
else
    assert_fail "list filters by issue:42" "got: $list_out2"
fi

list_out3=$(cost_list_remote_breakdowns "issue:999" 10 2>/dev/null) || list_out3=""
if [[ -z "$(printf '%s' "$list_out3" | tr -d '[:space:]')" ]]; then
    assert_pass "list filters by issue:999 returns empty (no match)"
else
    assert_fail "list issue:999 empty" "got: $list_out3"
fi

# Limit honoured
list_limited=$(cost_list_remote_breakdowns "all" 2 2>/dev/null) || list_limited=""
limited_count=$(printf '%s\n' "$list_limited" | grep -c "cost-breakdown-issue-42-run-" || true)
if [[ "$limited_count" -eq 2 ]]; then
    assert_pass "list honours limit=2"
else
    assert_fail "list honours limit" "got ${limited_count} entries"
fi

# ─── Test 2: cost_fetch_remote_breakdowns happy path ─────────────────────────
print_test_section "cost_fetch_remote_breakdowns — happy path"

# Stage downloadable fixtures: one per run id, each valid schema_version=1.
export _GH_DOWNLOAD_DIR="$TEST_TEMP_DIR/downloads"
for rid in 101 102 103; do
    make_breakdown_fixture "${_GH_DOWNLOAD_DIR}/cost-breakdown-issue-42-run-${rid}-attempt-1" 1 "0.10"
done

# Clear any existing baselines
rm -rf "$SW_BASELINE_DIR"
mkdir -p "$SW_BASELINE_DIR"

cost_fetch_remote_breakdowns "issue:42" 10 >/dev/null 2>&1 || true

if [[ -f "$SW_BASELINE_DIR/.fetched-runs.json" ]]; then
    merged=$(jq '.merged | length' "$SW_BASELINE_DIR/.fetched-runs.json" 2>/dev/null || echo "0")
    if [[ "$merged" -eq 3 ]]; then
        assert_pass "happy path: 3 artifacts merged into .fetched-runs.json"
    else
        assert_fail "happy path: 3 merged" "actual=${merged}"
    fi
else
    assert_fail "happy path: .fetched-runs.json created" "missing"
fi

if [[ -f "$SW_BASELINE_DIR/issue-42-costs.json" ]]; then
    n_build=$(jq -r '.stages.build.n // 0' "$SW_BASELINE_DIR/issue-42-costs.json" 2>/dev/null || echo "0")
    if [[ "$n_build" -ge 3 ]]; then
        assert_pass "happy path: per-issue baseline build.n >= 3"
    else
        assert_fail "happy path: per-issue baseline updated" "n=${n_build}"
    fi
else
    assert_fail "happy path: per-issue baseline file created" "missing"
fi

if [[ -f "$SW_BASELINE_DIR/stage-costs.json" ]]; then
    n_all=$(jq -r '.stages.build.n // 0' "$SW_BASELINE_DIR/stage-costs.json" 2>/dev/null || echo "0")
    if [[ "$n_all" -ge 3 ]]; then
        assert_pass "happy path: all-issues baseline build.n >= 3"
    else
        assert_fail "happy path: all-issues baseline updated" "n=${n_all}"
    fi
fi

# ─── Test 3: schema_version mismatch → skipped, not merged ───────────────────
print_test_section "schema_version mismatch"

# New empty world
rm -rf "$SW_BASELINE_DIR"
mkdir -p "$SW_BASELINE_DIR"

# Re-stage with schema_version=999 (incompatible)
for rid in 201 202; do
    make_breakdown_fixture "${_GH_DOWNLOAD_DIR}/cost-breakdown-issue-42-run-${rid}-attempt-1" 999 "0.10"
done
# Update list fixture
jq -nc '{
    artifacts: [
        {name: "cost-breakdown-issue-42-run-201-attempt-1", id: 201,
         workflow_run: {id: 201}, created_at: "2026-05-04T00:00:00Z", size_in_bytes: 1024},
        {name: "cost-breakdown-issue-42-run-202-attempt-1", id: 202,
         workflow_run: {id: 202}, created_at: "2026-05-05T00:00:00Z", size_in_bytes: 1024}
    ]
}' > "$list_fixture"

cost_fetch_remote_breakdowns "issue:42" 5 >/dev/null 2>&1 || true

if [[ -f "$SW_BASELINE_DIR/.fetched-runs.json" ]]; then
    merged=$(jq '.merged | length' "$SW_BASELINE_DIR/.fetched-runs.json" 2>/dev/null || echo "0")
    skipped=$(jq '.skipped | length' "$SW_BASELINE_DIR/.fetched-runs.json" 2>/dev/null || echo "0")
    if [[ "$merged" -eq 0 && "$skipped" -ge 2 ]]; then
        assert_pass "schema_version mismatch: 0 merged, ${skipped} skipped"
    else
        assert_fail "schema_version mismatch" "merged=${merged} skipped=${skipped}"
    fi
    reason=$(jq -r '.skipped["201"].reason // empty' "$SW_BASELINE_DIR/.fetched-runs.json" 2>/dev/null || echo "")
    if [[ "$reason" == "schema_mismatch" ]]; then
        assert_pass "schema_mismatch reason recorded"
    else
        assert_fail "schema_mismatch reason recorded" "got: $reason"
    fi
fi

if [[ ! -f "$SW_BASELINE_DIR/issue-42-costs.json" ]] \
   || [[ "$(jq -r '.stages.build.n // 0' "$SW_BASELINE_DIR/issue-42-costs.json" 2>/dev/null || echo 0)" -eq 0 ]]; then
    assert_pass "schema_version mismatch: per-issue baseline not poisoned"
else
    assert_fail "schema_version mismatch: baseline not poisoned" "issue baseline polluted"
fi

# ─── Test 4: idempotency — re-running fetch is a no-op ───────────────────────
print_test_section "idempotency"

rm -rf "$SW_BASELINE_DIR"
mkdir -p "$SW_BASELINE_DIR"

# Restore valid fixtures
for rid in 301 302; do
    make_breakdown_fixture "${_GH_DOWNLOAD_DIR}/cost-breakdown-issue-42-run-${rid}-attempt-1" 1 "0.30"
done
jq -nc '{
    artifacts: [
        {name: "cost-breakdown-issue-42-run-301-attempt-1", id: 301,
         workflow_run: {id: 301}, created_at: "2026-05-06T00:00:00Z", size_in_bytes: 1024},
        {name: "cost-breakdown-issue-42-run-302-attempt-1", id: 302,
         workflow_run: {id: 302}, created_at: "2026-05-07T00:00:00Z", size_in_bytes: 1024}
    ]
}' > "$list_fixture"

cost_fetch_remote_breakdowns "issue:42" 5 >/dev/null 2>&1 || true
first_n=$(jq -r '.stages.build.n // 0' "$SW_BASELINE_DIR/issue-42-costs.json" 2>/dev/null || echo 0)

# Run again — should not re-merge.
cost_fetch_remote_breakdowns "issue:42" 5 >/dev/null 2>&1 || true
second_n=$(jq -r '.stages.build.n // 0' "$SW_BASELINE_DIR/issue-42-costs.json" 2>/dev/null || echo 0)

if [[ "$first_n" -eq "$second_n" && "$first_n" -ge 2 ]]; then
    assert_pass "idempotency: re-run leaves n unchanged (${first_n} == ${second_n})"
else
    assert_fail "idempotency: re-run unchanged" "first=${first_n} second=${second_n}"
fi

# ─── Test 5: gh missing → returns 1, no pipeline failure ─────────────────────
print_test_section "gh missing"

# Hide the gh shim by setting _GH_BIN to a nonexistent binary.
( export _GH_BIN="/nonexistent/gh-binary-that-does-not-exist"
  if cost_fetch_remote_breakdowns "all" 5 >/dev/null 2>&1; then
      assert_fail "gh missing: returns 1" "got rc=0"
  else
      assert_pass "gh missing: returns 1 (soft failure)"
  fi
)

# ─── Test 6: NO_GITHUB=true short-circuits ───────────────────────────────────
print_test_section "NO_GITHUB respected"

( export NO_GITHUB=true
  if cost_fetch_remote_breakdowns "all" 5 >/dev/null 2>&1; then
      assert_fail "NO_GITHUB respected" "returned 0 instead of 1"
  else
      assert_pass "NO_GITHUB=true short-circuits (returns 1)"
  fi
)

# ─── Test 7: filter parser sanitizes issue digits ───────────────────────────
print_test_section "filter sanitization"

if _artifact_fetch_match_filter "cost-breakdown-issue-42-run-1-attempt-1" "issue:42"; then
    assert_pass "match: legit issue match"
else
    assert_fail "match: legit issue match"
fi
if _artifact_fetch_match_filter "cost-breakdown-issue-42-run-1-attempt-1" "issue:42; rm -rf /"; then
    assert_pass "match: non-digit chars stripped, still matches issue 42"
else
    assert_fail "match: shell-metachar sanitization"
fi
if _artifact_fetch_match_filter "pipeline-logs-issue-42-run-1" "all"; then
    assert_fail "match: non-cost-breakdown artifact rejected"
else
    assert_pass "match: non-cost-breakdown artifact rejected"
fi

# ─── Test 8: limit clamping ──────────────────────────────────────────────────
print_test_section "limit clamping"

if [[ "$(_artifact_fetch_clamp_limit 0)" == "1" ]]; then
    assert_pass "clamp: 0 → 1"
else
    assert_fail "clamp: 0 → 1" "got $(_artifact_fetch_clamp_limit 0)"
fi
if [[ "$(_artifact_fetch_clamp_limit 9999)" == "100" ]]; then
    assert_pass "clamp: 9999 → 100"
else
    assert_fail "clamp: 9999 → 100"
fi
if [[ "$(_artifact_fetch_clamp_limit '')" == "20" ]]; then
    assert_pass "clamp: empty → 20 (default)"
else
    assert_fail "clamp: empty → 20"
fi
if [[ "$(_artifact_fetch_clamp_limit 'abc')" == "20" ]]; then
    assert_pass "clamp: non-numeric → 20 (default)"
else
    assert_fail "clamp: non-numeric → 20"
fi

# ─── Test 9: CLI integration — sw cost breakdown-fetch / breakdown-list ──────
print_test_section "CLI subcommands"

# Restore valid fixtures so listing works.
jq -nc '{
    artifacts: [
        {name: "cost-breakdown-issue-42-run-401-attempt-1", id: 401,
         workflow_run: {id: 401}, created_at: "2026-05-08T00:00:00Z", size_in_bytes: 1024}
    ]
}' > "$list_fixture"
make_breakdown_fixture "${_GH_DOWNLOAD_DIR}/cost-breakdown-issue-42-run-401-attempt-1" 1 "0.50"

# `breakdown-list` should not download but should print our 1 entry.
list_cli_out=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown-list "issue:42" 5 2>&1) || true
if printf '%s' "$list_cli_out" | grep -q "cost-breakdown-issue-42-run-401-attempt-1"; then
    assert_pass "CLI: breakdown-list returns fixture entry"
else
    assert_fail "CLI: breakdown-list" "output: $(printf '%s' "$list_cli_out" | head -3)"
fi

# `breakdown-fetch` should accept the same args.
rm -rf "$SW_BASELINE_DIR"
mkdir -p "$SW_BASELINE_DIR"
fetch_cli_out=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown-fetch "issue:42" 5 2>&1) || true
if [[ -f "$SW_BASELINE_DIR/.fetched-runs.json" ]] && \
   [[ "$(jq '.merged | length' "$SW_BASELINE_DIR/.fetched-runs.json" 2>/dev/null || echo 0)" -ge 1 ]]; then
    assert_pass "CLI: breakdown-fetch merges fixture"
else
    assert_fail "CLI: breakdown-fetch" "output: $(printf '%s' "$fetch_cli_out" | head -5)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
print_test_results
