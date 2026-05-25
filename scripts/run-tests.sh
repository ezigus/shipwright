#!/usr/bin/env bash
# run-tests.sh — Tiered test runner for Shipwright.
# Supports --tier {unit,integration,e2e,all} (default: all).
# Reports per-tier counts in CI job summary format.
# Scans for "# tier: <X>" header in each test file;
# falls back to directory location during migration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIER="${1:-all}"
# Strip leading --tier flag if provided
[[ "$TIER" == "--tier" ]] && { TIER="${2:-all}"; shift 2 || true; }
[[ "$TIER" == --* ]] && { TIER="${TIER#--}"; }

TESTS_DIR="$REPO_DIR/tests"
SCRIPTS_DIR="$REPO_DIR/scripts"

unit_pass=0; unit_fail=0
integration_pass=0; integration_fail=0
e2e_pass=0; e2e_fail=0

# Detect tier from file header or directory location
_file_tier() {
    local f="$1"
    # Check for explicit "# tier: X" header in first 5 lines
    local header_tier
    header_tier=$(head -5 "$f" 2>/dev/null | grep -E '^# tier:' | head -1 | sed 's/# tier: *//' | tr -d ' ' || true)
    if [[ -n "$header_tier" ]]; then
        echo "$header_tier"
        return
    fi
    # Fall back to directory location
    case "$f" in
        */tests/unit/*) echo "unit" ;;
        */tests/integration/*) echo "integration" ;;
        */tests/e2e/*) echo "e2e" ;;
        *) echo "integration" ;;  # default during migration
    esac
}

# Run a single test file; update pass/fail counters
_run_test() {
    local f="$1"
    local tier="$2"
    local name
    name="$(basename "$f")"
    if bash "$f" 2>&1; then
        case "$tier" in
            unit) unit_pass=$(( unit_pass + 1 )) ;;
            integration) integration_pass=$(( integration_pass + 1 )) ;;
            e2e) e2e_pass=$(( e2e_pass + 1 )) ;;
        esac
        echo "PASS [$tier] $name"
    else
        case "$tier" in
            unit) unit_fail=$(( unit_fail + 1 )) ;;
            integration) integration_fail=$(( integration_fail + 1 )) ;;
            e2e) e2e_fail=$(( e2e_fail + 1 )) ;;
        esac
        echo "FAIL [$tier] $name" >&2
    fi
}

# Collect and run tests matching the requested tier
_run_tier() {
    local requested="$1"
    local -a files=()

    # Scan tier directories first
    if [[ -d "$TESTS_DIR/unit" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "$TESTS_DIR/unit" -name '*.sh' -type f 2>/dev/null | sort)
    fi
    if [[ -d "$TESTS_DIR/integration" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "$TESTS_DIR/integration" -name '*.sh' -type f 2>/dev/null | sort)
    fi
    if [[ -d "$TESTS_DIR/e2e" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "$TESTS_DIR/e2e" -name '*.sh' -type f 2>/dev/null | sort)
    fi

    # Also scan scripts/ for tagged test files (migration period)
    while IFS= read -r f; do
        head -5 "$f" 2>/dev/null | grep -qE '^# tier:' && files+=("$f")
    done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name '*-test.sh' -type f 2>/dev/null | sort)
    # Also scan tests/ root
    while IFS= read -r f; do files+=("$f"); done < <(find "$TESTS_DIR" -maxdepth 1 -name '*-test.sh' -type f 2>/dev/null | sort)

    for f in "${files[@]+"${files[@]}"}"; do
        [[ -x "$f" || -f "$f" ]] || continue
        local tier
        tier="$(_file_tier "$f")"
        if [[ "$requested" == "all" || "$tier" == "$requested" ]]; then
            _run_test "$f" "$tier"
        fi
    done
}

_run_tier "$TIER"

# CI job summary format
total_pass=$(( unit_pass + integration_pass + e2e_pass ))
total_fail=$(( unit_fail + integration_fail + e2e_fail ))

echo ""
echo "=== Test Results ==="
echo "unit $unit_pass/$(( unit_pass + unit_fail )) passed, integration $integration_pass/$(( integration_pass + integration_fail )) passed, e2e $e2e_pass/$(( e2e_pass + e2e_fail )) passed"
echo "Total: $total_pass passed, $total_fail failed"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Test Results"
        echo "| Tier | Passed | Failed | Total |"
        echo "|------|--------|--------|-------|"
        echo "| unit | $unit_pass | $unit_fail | $(( unit_pass + unit_fail )) |"
        echo "| integration | $integration_pass | $integration_fail | $(( integration_pass + integration_fail )) |"
        echo "| e2e | $e2e_pass | $e2e_fail | $(( e2e_pass + e2e_fail )) |"
        echo ""
        echo "**unit $unit_pass/$(( unit_pass + unit_fail )) passed, integration $integration_pass/$(( integration_pass + integration_fail )) passed, e2e $e2e_pass/$(( e2e_pass + e2e_fail )) passed**"
    } >> "$GITHUB_STEP_SUMMARY"
fi

[[ $total_fail -eq 0 ]]
