#!/usr/bin/env bash
# stage-cost.sh — per-stage cost recording bracket helpers
# Sourced by pipeline stage functions. Extracted for testability.
#
# Usage pattern in each stage function:
#   record_stage_cost_start "stagename"   ← at function entry
#   ...stage work...
#   record_stage_cost_end "stagename"     ← before every return and at natural end
#
# V1 limitations (documented, not blocking):
#   - MODEL may be approximate: some stages override MODEL locally (e.g. stage_design
#     uses design_model). We record ${MODEL:-sonnet} which is an approximation.
#   - Stage-retry snapshot overwrite: on retry the second _start overwrites the
#     snapshot, so the pipeline-local sidecar captures only the last attempt's delta.
#     First-attempt cost still lands in global costs.json via cost_record.
[[ -n "${_STAGE_COST_LOADED:-}" ]] && return 0
_STAGE_COST_LOADED=1

# record_stage_cost_start <stage_name>
# Call at the top of each stage function. Snapshots current cumulative token totals.
# Bash 3.2 safe: eval is used (not declare -A) because stage names are hardcoded constants.
record_stage_cost_start() {
    local stage="$1"
    eval "_STAGE_SNAP_INPUT_${stage}=\${TOTAL_INPUT_TOKENS:-0}"
    eval "_STAGE_SNAP_OUTPUT_${stage}=\${TOTAL_OUTPUT_TOKENS:-0}"
}

# record_stage_cost_end <stage_name>
# Call before every return in a stage function and at the natural end.
# Computes delta vs snapshot, writes to:
#   1. Global costs.json via cost_record (historical analytics, now with real stage names)
#   2. $ARTIFACTS_DIR/stage-costs.jsonl (pipeline-local, source of truth for cost-breakdown.json)
# No-ops silently when both token deltas are zero (stage made no Claude calls).
record_stage_cost_end() {
    local stage="$1"
    local _vin="_STAGE_SNAP_INPUT_${stage}"
    local _vout="_STAGE_SNAP_OUTPUT_${stage}"
    local _delta_in=$(( ${TOTAL_INPUT_TOKENS:-0}  - ${!_vin:-0} ))
    local _delta_out=$(( ${TOTAL_OUTPUT_TOKENS:-0} - ${!_vout:-0} ))
    [[ "$_delta_in" -le 0 && "$_delta_out" -le 0 ]] && return 0
    # 1. Global costs.json (historical analytics — real stage names from now on)
    if type cost_record >/dev/null 2>&1; then
        cost_record "$_delta_in" "$_delta_out" "${MODEL:-sonnet}" \
            "$stage" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi
    # 2. Pipeline-local sidecar (concurrent-pipeline safe; never queries global ledger)
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
        local _ts
        _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq -cn \
            --arg stage "$stage" \
            --argjson input "$_delta_in" \
            --argjson output "$_delta_out" \
            --arg model "${MODEL:-sonnet}" \
            --arg ts "$_ts" \
            '{stage: $stage, input_tokens: $input, output_tokens: $output, model: $model, ts: $ts}' \
            2>/dev/null >> "${ARTIFACTS_DIR}/stage-costs.jsonl" || true
    fi
}
