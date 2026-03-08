#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-completion.sh — Post-pipeline events, cost, memory, learning   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_COMPLETION_LOADED:-}" ]] && return 0
_PIPELINE_COMPLETION_LOADED=1

VERSION="3.2.4"

# ─── Post-Pipeline Completion ────────────────────────────────────────────
# Handles all post-pipeline bookkeeping: cost, events, memory, learning.
# All errors are swallowed (|| true) to avoid masking the pipeline result.

pipeline_post_completion() {
    local exit_code="$1"

    # Compute total cost for pipeline.completed (prefer actual from Claude when available)
    local model_key="${MODEL:-sonnet}"
    local total_cost
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost="${TOTAL_COST_USD}"
    else
        local input_cost output_cost
        input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')
    fi

    # Send completion notification + event
    local total_dur_s=""
    [[ -n "$PIPELINE_START_EPOCH" ]] && total_dur_s=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
    if [[ "$exit_code" -eq 0 ]]; then
        local total_dur=""
        [[ -n "$total_dur_s" ]] && total_dur=$(format_duration "$total_dur_s")
        local pr_url
        pr_url=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo "")
        notify "Pipeline Complete" "Goal: ${GOAL}\nDuration: ${total_dur:-unknown}\nPR: ${pr_url:-N/A}" "success"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=success" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "stages_passed=${PIPELINE_STAGES_PASSED:-0}" \
            "slowest_stage=${PIPELINE_SLOWEST_STAGE:-}" \
            "pr_url=${pr_url:-}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "success" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "completed" "${PIPELINE_SLOWEST_STAGE:-}" "complete" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Capture success patterns to memory (learn what works — parallel the failure path)
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
        fi
        # Update memory baselines with successful run metrics
        if type memory_update_metrics >/dev/null 2>&1; then
            memory_update_metrics "build_duration_s" "${total_dur_s:-0}" 2>/dev/null || true
            memory_update_metrics "total_cost_usd" "${total_cost:-0}" 2>/dev/null || true
            memory_update_metrics "iterations" "$((SELF_HEAL_COUNT + 1))" 2>/dev/null || true
        fi

        # Record positive fix outcome if self-healing succeeded
        if [[ "$SELF_HEAL_COUNT" -gt 0 && -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            local _success_sig
            _success_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
            if [[ -n "$_success_sig" ]]; then
                bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_success_sig" "true" "true" 2>/dev/null || true
            fi
        fi
    else
        notify "Pipeline Failed" "Goal: ${GOAL}\nFailed at: ${CURRENT_STAGE_ID:-unknown}" "error"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=failure" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "failed_stage=${CURRENT_STAGE_ID:-unknown}" \
            "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "failure" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "failed" "${CURRENT_STAGE_ID:-unknown}" "failed" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Capture failure learnings to memory
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
            bash "$SCRIPT_DIR/sw-memory.sh" analyze-failure "$ARTIFACTS_DIR/.claude-tokens-${CURRENT_STAGE_ID:-build}.log" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true

            # Record negative fix outcome — memory suggested a fix but it didn't resolve the issue
            if [[ "$SELF_HEAL_COUNT" -gt 0 ]]; then
                local _fail_sig
                _fail_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
                if [[ -n "$_fail_sig" ]]; then
                    bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_fail_sig" "true" "false" 2>/dev/null || true
                fi
            fi
        fi
    fi

    # AI-powered outcome learning
    if type skill_analyze_outcome >/dev/null 2>&1; then
        local _failed_stage=""
        local _error_ctx=""
        if [[ "$exit_code" -ne 0 ]]; then
            _failed_stage="${CURRENT_STAGE_ID:-unknown}"
            _error_ctx=$(tail -30 "$ARTIFACTS_DIR/errors-collected.json" 2>/dev/null || true)
        fi
        local _outcome_result="success"
        [[ "$exit_code" -ne 0 ]] && _outcome_result="failure"

        if skill_analyze_outcome "$_outcome_result" "$ARTIFACTS_DIR" "$_failed_stage" "$_error_ctx" 2>/dev/null; then
            info "Skill outcome analysis complete — learnings recorded"
        fi
    fi

    # ── Prediction Validation Events ──
    local pipeline_success="false"
    [[ "$exit_code" -eq 0 ]] && pipeline_success="true"

    # Complexity prediction vs actual iterations
    emit_event "prediction.validated" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "actual_iterations=$SELF_HEAL_COUNT" \
        "success=$pipeline_success"

    # Close intelligence prediction feedback loop
    if type intelligence_validate_prediction >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
        intelligence_validate_prediction \
            "$ISSUE_NUMBER" \
            "${INTELLIGENCE_COMPLEXITY:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "$pipeline_success" 2>/dev/null || true
    fi

    # Validate iterations prediction against actuals
    local ACTUAL_ITERATIONS=$((SELF_HEAL_COUNT + 1))
    if [[ -n "${PREDICTED_ITERATIONS:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "iterations" "$PREDICTED_ITERATIONS" "$ACTUAL_ITERATIONS" 2>/dev/null || true
    fi

    # Close predictive anomaly feedback loop
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local _actual_failure="false"
        [[ "$exit_code" -ne 0 ]] && _actual_failure="true"
        for _anomaly_stage in build test; do
            bash "$SCRIPT_DIR/sw-predictive.sh" confirm-anomaly "$_anomaly_stage" "duration_s" "$_actual_failure" 2>/dev/null || true
        done
    fi

    # Template outcome tracking
    emit_event "template.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "success=$pipeline_success" \
        "duration_s=${total_dur_s:-0}" \
        "complexity=${INTELLIGENCE_COMPLEXITY:-0}"

    # Risk prediction vs actual failure
    local predicted_risk="${INTELLIGENCE_RISK_SCORE:-0}"
    emit_event "risk.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_risk=$predicted_risk" \
        "actual_failure=$([[ "$exit_code" -ne 0 ]] && echo "true" || echo "false")"

    # Per-stage model outcome events (read from stage timings)
    local routing_log="${ARTIFACTS_DIR}/model-routing.log"
    if [[ -f "$routing_log" ]]; then
        while IFS='|' read -r s_stage s_model s_success; do
            [[ -z "$s_stage" ]] && continue
            emit_event "model.outcome" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$s_stage" \
                "model=$s_model" \
                "success=$s_success"
        done < "$routing_log"
    fi

    # Record pipeline outcome for model routing feedback loop
    if type optimize_analyze_outcome >/dev/null 2>&1; then
        optimize_analyze_outcome "$STATE_FILE" 2>/dev/null || true
    fi

    # Auto-learn after pipeline completion (non-blocking)
    if type optimize_tune_templates &>/dev/null; then
        (
            optimize_tune_templates 2>/dev/null
            optimize_learn_iterations 2>/dev/null
            optimize_route_models 2>/dev/null
            optimize_learn_risk_keywords 2>/dev/null
        ) &
    fi

    if type memory_finalize_pipeline >/dev/null 2>&1; then
        memory_finalize_pipeline "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Broadcast discovery for cross-pipeline learning
    if type broadcast_discovery >/dev/null 2>&1; then
        local _disc_result="failure"
        [[ "$exit_code" -eq 0 ]] && _disc_result="success"
        local _disc_files=""
        _disc_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | head -20 | tr '\n' ',' || true)
        broadcast_discovery "pipeline_${_disc_result}" "${_disc_files:-unknown}" \
            "Pipeline ${_disc_result} for issue #${ISSUE_NUMBER:-0} (${PIPELINE_NAME:-unknown} template, stage=${CURRENT_STAGE_ID:-unknown})" \
            "${_disc_result}" 2>/dev/null || true
    fi

    # Emit cost event — prefer actual cost from Claude CLI when available
    local model_key2="${MODEL:-sonnet}"
    local total_cost2
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost2="${TOTAL_COST_USD}"
    else
        local input_cost2 output_cost2
        input_cost2=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key2}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost2=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key2}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost2=$(awk -v i="$input_cost2" -v o="$output_cost2" 'BEGIN{printf "%.4f", i + o}')
    fi

    emit_event "pipeline.cost" \
        "input_tokens=$TOTAL_INPUT_TOKENS" \
        "output_tokens=$TOTAL_OUTPUT_TOKENS" \
        "model=$model_key2" \
        "cost_usd=$total_cost2"

    # Persist cost entry to costs.json + SQLite
    if type cost_record >/dev/null 2>&1; then
        cost_record "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS" "$model_key2" "pipeline" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi

    # Record pipeline outcome for Thompson sampling / outcome-based learning
    if type db_record_outcome >/dev/null 2>&1; then
        local _outcome_success=0
        [[ "$exit_code" -eq 0 ]] && _outcome_success=1
        local _outcome_complexity="medium"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -le 3 ]] && _outcome_complexity="low"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -ge 7 ]] && _outcome_complexity="high"
        db_record_outcome \
            "${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}" \
            "${ISSUE_NUMBER:-}" \
            "${PIPELINE_NAME:-standard}" \
            "$_outcome_success" \
            "${total_dur_s:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "${total_cost2:-0}" \
            "$_outcome_complexity" 2>/dev/null || true
    fi

    # Validate cost prediction against actual
    if [[ -n "${PREDICTED_COST:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "cost" "$PREDICTED_COST" "$total_cost2" 2>/dev/null || true
    fi
}
