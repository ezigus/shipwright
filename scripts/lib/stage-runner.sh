#!/usr/bin/env bash
# stage-runner.sh — Unified stage execution wrapper
# Provides run_stage <name> that handles retry/error/event-emit.
# Source from sw-pipeline.sh after pipeline-state.sh.
set -euo pipefail
[[ -n "${_STAGE_RUNNER_LOADED:-}" ]] && return 0
_STAGE_RUNNER_LOADED=1

# run_stage <stage_name> [max_retries]
# Calls stage_<stage_name>(), records timing, emits events, handles errors.
# Returns 0 on success, 1 on failure after retries.
run_stage() {
    local stage_name="$1"
    local max_retries="${2:-0}"
    local stage_fn="stage_${stage_name}"

    if ! type "$stage_fn" >/dev/null 2>&1; then
        error "run_stage: no function '${stage_fn}' defined" || true
        return 1
    fi

    local attempt=0
    local exit_code=0
    while [[ $attempt -le $max_retries ]]; do
        attempt=$(( attempt + 1 ))
        emit_event "stage.start" "stage=${stage_name}" "attempt=${attempt}" 2>/dev/null || true
        record_stage_start "$stage_name" 2>/dev/null || true

        if "$stage_fn"; then
            exit_code=0
            emit_event "stage.complete" "stage=${stage_name}" "attempt=${attempt}" 2>/dev/null || true
            mark_stage_complete "$stage_name" 2>/dev/null || true
            return 0
        else
            exit_code=$?
            emit_event "stage.failed" "stage=${stage_name}" "attempt=${attempt}" "exit=${exit_code}" 2>/dev/null || true
            if [[ $attempt -le $max_retries ]]; then
                warn "Stage '${stage_name}' failed (attempt ${attempt}/${max_retries}), retrying..." || true
            fi
        fi
    done

    error "Stage '${stage_name}' failed after ${attempt} attempt(s)" || true
    return "$exit_code"
}
