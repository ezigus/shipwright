#!/usr/bin/env bash
# tier: integration
# cli-smoke-test.sh — CLI smoke coverage for untested sw-* commands.
# For each sw-* command with no corresponding test file, runs --help and
# verifies it exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_DIR/scripts/lib/test-helpers.sh"

print_test_header "CLI smoke tests (untested sw-* commands)"

setup_test_env

pass=0
fail=0
failed_cmds=""

# Find sw-*.sh files that have no corresponding -test.sh
cd "$REPO_DIR/scripts"
for f in sw-*.sh; do
    [[ "$f" == *-test.sh ]] && continue
    base="${f%.sh}"
    [[ -f "${base}-test.sh" ]] || {
        cmd_name="$base"
        # Run --help, expect exit 0
        if bash "$REPO_DIR/scripts/${f}" --help >/dev/null 2>&1; then
            pass=$(( pass + 1 ))
            assert_pass "${cmd_name} --help exits 0"
        else
            # Some commands may use -h or no --help flag; try bare invocation
            if timeout 5 bash "$REPO_DIR/scripts/${f}" >/dev/null 2>&1; then
                pass=$(( pass + 1 ))
                assert_pass "${cmd_name} runs without error"
            else
                fail=$(( fail + 1 ))
                failed_cmds="${failed_cmds} ${cmd_name}"
                assert_fail "${cmd_name} --help must exit 0"
            fi
        fi
    }
done

echo ""
echo "Smoke results: ${pass} passed, ${fail} failed"
[[ -n "$failed_cmds" ]] && echo "Failed:${failed_cmds}"

cleanup_test_env
print_test_results
