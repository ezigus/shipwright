#!/usr/bin/env bash
# ci-reconcile-state.sh — Reconcile a WIP pipeline-state.md after a killed CI job.
#
# Scope: only `running` and `paused` → `interrupted`. These are the states that:
#   (a) trigger the misleading "already in progress" guard at sw-pipeline.sh:3054
#   (b) are always stale in CI (CI runs with --skip-gates, never legitimately pauses;
#       a graceful exit would have set 'interrupted' itself).
# `failed`, `interrupted`, `complete`, `stuck_cycling` are intentionally untouched.
#
# Outputs to stdout: comma-separated list of stages with `complete (...)` in the
# `## Log` section (the canonical "complete" emit format from pipeline-state.sh:247).
# Empty string if none.
#
# Side effect: rewrites `status:` line in $1 atomically via tmp+mv.
set -euo pipefail

ci_reconcile_state() {
    local state_file="${1:?usage: ci_reconcile_state <state_file>}"
    [[ -f "$state_file" ]] || { echo ""; return 0; }

    local status
    status="$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d '[:space:]')"
    case "$status" in
        running|paused) ;;
        *) echo ""; return 0 ;;
    esac

    # Extract completed stages from `## Log`.
    # Header line:  '### <stage> (HH:MM:SS)'
    # Outcome line: 'complete (<timing>)' — only emitted from pipeline-state.sh:247
    # POSIX awk only — no gawk extensions.
    awk '
        /^## Log[[:space:]]*$/ { in_log=1; next }
        in_log && /^### [A-Za-z0-9_]+ \(/ {
            line=$0; sub(/^### /, "", line); sub(/ \(.*$/, "", line); stage=line; next
        }
        in_log && /^complete \(/ && stage != "" {
            if (!(stage in seen)) { seen[stage]=1; out = (out=="" ? stage : out","stage) }
            stage=""
        }
        END { print out }
    ' "$state_file"

    # Atomic rewrite: status: running|paused -> interrupted.
    local tmp
    tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
    sed -E 's/^status:[[:space:]]*(running|paused)[[:space:]]*$/status: interrupted/' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0:-}" ]]; then
    ci_reconcile_state "$@"
fi
