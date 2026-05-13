#!/usr/bin/env bash
# ci-reconcile-state.sh — Reconcile a WIP pipeline-state.md after a killed CI job.
#
# Scope: rewrites `running` and `paused` → `interrupted`. These are always
# stale in CI (a graceful exit would have set `interrupted` itself).
# `failed`, `interrupted`, `complete`, `stuck_cycling` are NOT rewritten.
#
# Outputs to stdout: comma-separated list of stages that completed, read from
# pipeline-state.md (both the YAML `stages:` block and the `## Log` section).
# pipeline-state.md is the authoritative record — written atomically by
# mark_stage_complete() on each successful stage exit. Returns completed stages
# for any resumable status so that a pipeline resumed from any state correctly
# skips already-completed work.
#
# Returns empty string only when:
#   - the file does not exist
#   - status is `complete` (re-run should start fresh)
#   - no completed stages are found in either source
#
# Side effect: rewrites `status:` line atomically via tmp+mv when running/paused.
set -euo pipefail

ci_reconcile_state() {
    local state_file="${1:?usage: ci_reconcile_state <state_file>}"
    [[ -f "$state_file" ]] || { echo ""; return 0; }

    local status
    status="$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d '[:space:]')"

    # Rewrite running/paused → interrupted (always stale in CI).
    case "$status" in
        running|paused)
            local tmp
            tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
            sed -E 's/^status:[[:space:]]*(running|paused)[[:space:]]*$/status: interrupted/' \
                "$state_file" > "$tmp" && mv "$tmp" "$state_file"
            ;;
        complete)
            # Pipeline completed — do not emit stages; a re-run should start fresh.
            echo ""; return 0
            ;;
    esac

    # Extract completed stages from pipeline-state.md — the authoritative source.
    # Reads both the YAML `stages:` block and the `## Log` section; emits the union.
    # POSIX awk only — no gawk extensions.
    awk '
        /^stages:[[:space:]]*$/ { in_stages=1; in_log=0; next }
        /^## Log[[:space:]]*$/ { in_log=1; in_stages=0; next }

        # YAML stages block ends at the first non-indented non-empty line
        in_stages && /^[^[:space:]]/ { in_stages=0 }

        # YAML source: "  <stage>: complete"
        in_stages && /^[[:space:]]+[A-Za-z0-9_]+:[[:space:]]+complete/ {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/:[[:space:]]+complete.*$/, "", line)
            if (!(line in seen)) { seen[line]=1; out = (out=="" ? line : out","line) }
        }

        # Log source: stage header line then a complete marker line
        in_log && /^### [A-Za-z0-9_]+ \(/ {
            line=$0; sub(/^### /, "", line); sub(/ \(.*$/, "", line); stage=line; next
        }
        in_log && /^complete \(/ && stage != "" {
            if (!(stage in seen)) { seen[stage]=1; out = (out=="" ? stage : out","stage) }
            stage=""
        }

        END { print out }
    ' "$state_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0:-}" ]]; then
    ci_reconcile_state "$@"
fi
