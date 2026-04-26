#!/usr/bin/env bash
# loop-cost.sh — per-iteration cost recording for the build loop
# Sourced by sw-loop.sh. Extracted here for testability (no sw-loop.sh side effects).
[[ -n "${_LOOP_COST_LOADED:-}" ]] && return 0
_LOOP_COST_LOADED=1

# record_iteration_cost <iter_num>
# Appends one JSON line to $ITER_COST_JSONL using deltas from snapshot vars
# (_ITER_SNAP_INPUT, _ITER_SNAP_OUTPUT, _ITER_SNAP_COST_MC) that must be set
# immediately before run_claude_iteration.
record_iteration_cost() {
    local iter_num="${1:-0}"
    [[ -z "${ITER_COST_JSONL:-}" ]] && return 0
    local _delta_in=$(( ${LOOP_INPUT_TOKENS:-0}    - ${_ITER_SNAP_INPUT:-0}    ))
    local _delta_out=$(( ${LOOP_OUTPUT_TOKENS:-0}   - ${_ITER_SNAP_OUTPUT:-0}   ))
    local _delta_mc=$((  ${LOOP_COST_MILLICENTS:-0} - ${_ITER_SNAP_COST_MC:-0}  ))
    local _cost_usd="0"
    [[ "$_delta_mc" -gt 0 ]] && \
        _cost_usd=$(awk "BEGIN {printf \"%.6f\", ${_delta_mc}/100000}" 2>/dev/null || echo "0")
    local _ts
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -cn \
        --argjson iter "$iter_num" \
        --argjson input "$_delta_in" \
        --argjson output "$_delta_out" \
        --arg cost "$_cost_usd" \
        --arg ts "$_ts" \
        '{iteration: $iter, input_tokens: $input, output_tokens: $output, cost_usd: ($cost|tonumber), ts: $ts}' \
        2>/dev/null >> "$ITER_COST_JSONL" || true
}
