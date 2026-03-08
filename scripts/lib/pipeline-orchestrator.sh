#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-orchestrator.sh — Core pipeline dispatch loop                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_ORCHESTRATOR_LOADED:-}" ]] && return 0
_PIPELINE_ORCHESTRATOR_LOADED=1

VERSION="3.2.4"

# ─── Main Pipeline Loop ──────────────────────────────────────────────────

run_pipeline() {
    # Rotate event log if needed (standalone mode)
    rotate_event_log_if_needed

    # Initialize audit trail for this pipeline run
    if type audit_init >/dev/null 2>&1; then
        audit_init || true
    fi

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG")

    local stage_count enabled_count
    stage_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_count=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    local completed=0

    # Check which stages are enabled to determine if we use the self-healing loop
    local build_enabled test_enabled
    build_enabled=$(jq -r '.stages[] | select(.id == "build") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    test_enabled=$(jq -r '.stages[] | select(.id == "test") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    local use_self_healing=false
    if [[ "$build_enabled" == "true" && "$test_enabled" == "true" && "$BUILD_TEST_RETRIES" -gt 0 ]]; then
        use_self_healing=true
    fi

    while IFS= read -r -u 3 stage; do
        local id enabled gate
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        gate=$(echo "$stage" | jq -r '.gate')

        CURRENT_STAGE_ID="$id"

        # Human intervention: check for skip-stage directive
        if [[ -f "$ARTIFACTS_DIR/skip-stage.txt" ]]; then
            local skip_list
            skip_list="$(cat "$ARTIFACTS_DIR/skip-stage.txt" 2>/dev/null || true)"
            if echo "$skip_list" | grep -qx "$id" 2>/dev/null; then
                info "Stage ${BOLD}${id}${RESET} skipped by human directive"
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=human_skip"
                # Remove this stage from the skip file
                local tmp_skip
                tmp_skip="$(mktemp)"
                # shellcheck disable=SC2064  # intentional expansion at definition time
                trap "rm -f '$tmp_skip'" RETURN
                grep -vx "$id" "$ARTIFACTS_DIR/skip-stage.txt" > "$tmp_skip" 2>/dev/null || true
                mv "$tmp_skip" "$ARTIFACTS_DIR/skip-stage.txt"
                continue
            fi
        fi

        # Human intervention: check for human message
        if [[ -f "$ARTIFACTS_DIR/human-message.txt" ]]; then
            local human_msg
            human_msg="$(cat "$ARTIFACTS_DIR/human-message.txt" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo ""
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                emit_event "pipeline.human_message" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "message=$human_msg"
                rm -f "$ARTIFACTS_DIR/human-message.txt"
            fi
        fi

        if [[ "$enabled" != "true" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (disabled)${RESET}"
            continue
        fi

        # Intelligence: evaluate whether to skip this stage
        local skip_reason=""
        skip_reason=$(pipeline_should_skip_stage "$id" 2>/dev/null) || true
        if [[ -n "$skip_reason" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (intelligence: ${skip_reason})${RESET}"
            set_stage_status "$id" "complete"
            completed=$((completed + 1))
            continue
        fi

        local stage_status
        stage_status=$(get_stage_status "$id")
        if [[ "$stage_status" == "complete" ]]; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— already complete${RESET}"
            completed=$((completed + 1))
            continue
        fi

        # CI resume: skip stages marked as completed from previous run
        if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "$id"; then
            # Verify artifacts survived the merge — regenerate if missing
            if verify_stage_artifacts "$id"; then
                echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— skipped (CI resume)${RESET}"
                set_stage_status "$id" "complete"
                completed=$((completed + 1))
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=ci_resume"
                continue
            else
                warn "Stage $id marked complete but artifacts missing — regenerating"
                emit_event "stage.artifact_miss" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
            fi
        fi

        # Self-healing build→test loop: when we hit build, run both together
        if [[ "$id" == "build" && "$use_self_healing" == "true" ]]; then
            # TDD: generate tests before build when enabled
            if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
                stage_test_first || true
            fi
            # Gate check for build
            local build_gate
            build_gate=$(echo "$stage" | jq -r '.gate')
            if [[ "$build_gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
                show_stage_preview "build"
                local answer=""
                if [[ -t 0 ]]; then
                    read -rp "  Proceed with build+test (self-healing)? [Y/n] " answer || true
                fi
                if [[ "$answer" =~ ^[Nn] ]]; then
                    update_status "paused" "build"
                    info "Pipeline paused. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                    return 0
                fi
            fi

            if self_healing_build_test; then
                completed=$((completed + 2))  # Both build and test

                # Intelligence: reassess complexity after build+test
                local reassessment
                reassessment=$(pipeline_reassess_complexity 2>/dev/null) || true
                if [[ -n "$reassessment" && "$reassessment" != "as_expected" ]]; then
                    info "Complexity reassessment: ${reassessment}"
                fi
            else
                update_status "failed" "test"
                error "Pipeline failed: build→test self-healing exhausted"
                return 1
            fi
            continue
        fi

        # TDD: generate tests before build when enabled (non-self-healing path)
        if [[ "$id" == "build" && "$use_self_healing" != "true" ]] && [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
            stage_test_first || true
        fi

        # Skip test if already handled by self-healing loop
        if [[ "$id" == "test" && "$use_self_healing" == "true" ]]; then
            stage_status=$(get_stage_status "test")
            if [[ "$stage_status" == "complete" ]]; then
                echo -e "  ${GREEN}✓ test${RESET} ${DIM}— completed in build→test loop${RESET}"
            fi
            continue
        fi

        # Gate check
        if [[ "$gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
            show_stage_preview "$id"
            local answer=""
            if [[ -t 0 ]]; then
                read -rp "  Proceed with ${id}? [Y/n] " answer || true
            else
                # Non-interactive: auto-approve (shouldn't reach here if headless detection works)
                info "Non-interactive mode — auto-approving ${id}"
            fi
            if [[ "$answer" =~ ^[Nn] ]]; then
                update_status "paused" "$id"
                info "Pipeline paused at ${BOLD}$id${RESET}. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                return 0
            fi
        fi

        # Budget enforcement check (skip with --ignore-budget)
        if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local budget_rc=0
            bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
            if [[ "$budget_rc" -eq 2 ]]; then
                warn "Daily budget exceeded — pausing pipeline before stage ${BOLD}$id${RESET}"
                warn "Resume with --ignore-budget to override, or wait until tomorrow"
                emit_event "pipeline.budget_paused" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
                update_status "paused" "$id"
                return 0
            fi
        fi

        # Intelligence: per-stage model routing (UCB1 when DB has data, else A/B testing)
        local recommended_model="" from_ucb1=false
        if type ucb1_select_model >/dev/null 2>&1; then
            recommended_model=$(ucb1_select_model "$id" 2>/dev/null || echo "")
            [[ -n "$recommended_model" ]] && from_ucb1=true
        fi
        if [[ -z "$recommended_model" ]] && type intelligence_recommend_model >/dev/null 2>&1; then
            local stage_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
            local budget_remaining=""
            if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
                budget_remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            fi
            local recommended_json
            recommended_json=$(intelligence_recommend_model "$id" "$stage_complexity" "$budget_remaining" 2>/dev/null || echo "")
            recommended_model=$(echo "$recommended_json" | jq -r '.model // empty' 2>/dev/null || echo "")
        fi
        if [[ -n "$recommended_model" && "$recommended_model" != "null" ]]; then
            if [[ "$from_ucb1" == "true" ]]; then
                # UCB1 already balances exploration/exploitation — use directly
                export CLAUDE_MODEL="$recommended_model"
                emit_event "intelligence.model_ucb1" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "model=$recommended_model"
            else
                # A/B testing for intelligence recommendation
                local ab_ratio=20
                local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
                if [[ -f "$daemon_cfg" ]]; then
                    local cfg_ratio
                    cfg_ratio=$(jq -r '.intelligence.ab_test_ratio // 0.2' "$daemon_cfg" 2>/dev/null || echo "0.2")
                    ab_ratio=$(awk -v r="$cfg_ratio" 'BEGIN{printf "%d", r * 100}' 2>/dev/null || echo "20")
                fi

                local routing_file="${HOME}/.shipwright/optimization/model-routing.json"
                local use_recommended=false
                local ab_group="control"

                if [[ -f "$routing_file" ]]; then
                    local stage_samples total_samples
                    stage_samples=$(jq -r --arg s "$id" '.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0' "$routing_file" 2>/dev/null || echo "0")
                    total_samples=$(jq -r --arg s "$id" '((.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0) + (.routes[$s].opus_samples // .[$s].opus_samples // 0))' "$routing_file" 2>/dev/null || echo "0")
                    if [[ "${total_samples:-0}" -ge 50 ]]; then
                        use_recommended=true
                        ab_group="graduated"
                    fi
                fi

                if [[ "$use_recommended" != "true" ]]; then
                    local roll=$((RANDOM % 100))
                    if [[ "$roll" -lt "$ab_ratio" ]]; then
                        use_recommended=true
                        ab_group="experiment"
                    fi
                fi

                if [[ "$use_recommended" == "true" ]]; then
                    export CLAUDE_MODEL="$recommended_model"
                else
                    export CLAUDE_MODEL="opus"
                fi

                emit_event "intelligence.model_ab" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "recommended=$recommended_model" \
                    "applied=$CLAUDE_MODEL" \
                    "ab_group=$ab_group" \
                    "ab_ratio=$ab_ratio"
            fi
        fi

        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: ${id}${RESET} ${DIM}[$((completed + 1))/${enabled_count}]${RESET}"
        update_status "running" "$id"
        record_stage_start "$id"
        local stage_start_epoch
        stage_start_epoch=$(now_epoch)
        emit_event "stage.started" "issue=${ISSUE_NUMBER:-0}" "stage=$id"

        # Mark GitHub Check Run as in-progress
        if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
            gh_checks_stage_update "$id" "in_progress" "" "Stage $id started" 2>/dev/null || true
        fi

        # Audit: stage start
        if type audit_emit >/dev/null 2>&1; then
            audit_emit "stage.start" "stage=$id" || true
        fi

        local stage_model_used="${CLAUDE_MODEL:-${MODEL:-opus}}"
        if run_stage_with_retry "$id"; then
            mark_stage_complete "$id"
            completed=$((completed + 1))
            # Capture project pattern after intake (for memory context in later stages)
            if [[ "$id" == "intake" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-memory.sh" pattern "project" "{}" 2>/dev/null) || true
            fi
            local timing stage_dur_s
            timing=$(get_stage_timing "$id")
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            success "Stage ${BOLD}$id${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "stage.completed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s" "result=success"
            # Audit: stage complete
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=pass" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on every stage transition (not just build/test)
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "" 2>/dev/null || true
            fi
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 1 "$stage_dur_s" 0 2>/dev/null || true
            # Broadcast discovery for cross-pipeline learning
            if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
                local _disc_cat _disc_patterns _disc_text
                _disc_cat="$id"
                case "$id" in
                    plan)   _disc_patterns="*.md"; _disc_text="Plan completed: ${GOAL:-goal}" ;;
                    design) _disc_patterns="*.md,*.ts,*.tsx,*.js"; _disc_text="Design completed for ${GOAL:-goal}" ;;
                    build)  _disc_patterns="src/*,*.ts,*.tsx,*.js"; _disc_text="Build completed" ;;
                    test)   _disc_patterns="*.test.*,*_test.*"; _disc_text="Tests passed" ;;
                    review) _disc_patterns="*.md,*.ts,*.tsx"; _disc_text="Review completed" ;;
                    *)      _disc_patterns="*"; _disc_text="Stage $id completed" ;;
                esac
                bash "$SCRIPT_DIR/sw-discovery.sh" broadcast "$_disc_cat" "$_disc_patterns" "$_disc_text" "" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
        else
            # Self-healing: review blocked → rebuild with review findings
            if [[ "$id" == "review" && "$use_self_healing" == "true" ]] \
                && [[ -f "$ARTIFACTS_DIR/review-blockers.md" ]] \
                && [[ -s "$ARTIFACTS_DIR/review-blockers.md" ]]; then
                info "Review blocked — attempting review self-healing rebuild..."
                if self_healing_review_build_test; then
                    mark_stage_complete "$id"
                    completed=$((completed + 1))
                    echo "${id}|${stage_model_used:-opus}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
                    continue
                fi
                # Self-healing exhausted — fall through to normal failure
            fi

            mark_stage_failed "$id"
            local stage_dur_s
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            error "Pipeline failed at stage: ${BOLD}$id${RESET}"
            update_status "failed" "$id"
            emit_event "stage.failed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$id" \
                "duration_s=$stage_dur_s" \
                "error=${LAST_STAGE_ERROR:-unknown}" \
                "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}"
            # Audit: stage failed
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=fail" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on failure too
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "${LAST_STAGE_ERROR:-unknown}" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|false" >> "${ARTIFACTS_DIR}/model-routing.log"
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 0 "$stage_dur_s" 0 2>/dev/null || true
            # Cancel any remaining in_progress check runs
            pipeline_cancel_check_runs 2>/dev/null || true
            return 1
        fi
    done 3<<< "$stages"

    # Pipeline complete!
    update_status "complete" ""
    PIPELINE_STAGES_PASSED="$completed"
    PIPELINE_SLOWEST_STAGE=""
    if type get_slowest_stage >/dev/null 2>&1; then
        PIPELINE_SLOWEST_STAGE=$(get_slowest_stage 2>/dev/null || true)
    fi
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
    success "Pipeline complete! ${completed}/${enabled_count} stages passed in ${total_dur:-unknown}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"

    # Show summary
    echo ""
    if [[ -f "$ARTIFACTS_DIR/pr-url.txt" ]]; then
        echo -e "  ${BOLD}PR:${RESET}        $(cat "$ARTIFACTS_DIR/pr-url.txt")"
    fi
    echo -e "  ${BOLD}Branch:${RESET}    $GIT_BRANCH"
    [[ -n "${GITHUB_ISSUE:-}" ]] && echo -e "  ${BOLD}Issue:${RESET}     $GITHUB_ISSUE"
    echo -e "  ${BOLD}Duration:${RESET}  $total_dur"
    echo -e "  ${BOLD}Artifacts:${RESET} $ARTIFACTS_DIR/"
    echo ""

    # Capture learnings to memory (success or failure)
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Final GitHub progress update
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
    fi

    # Post-completion cleanup
    pipeline_post_completion_cleanup
}

# ─── Post-Completion Cleanup ──────────────────────────────────────────────
# Cleans up transient artifacts after a successful pipeline run.

pipeline_post_completion_cleanup() {
    local cleaned=0

    # 1. Clear checkpoints and context files (they only matter for resume; pipeline is done)
    if [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_count=0
        local cp_file
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-checkpoint.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-claude-context.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        if [[ "$cp_count" -gt 0 ]]; then
            cleaned=$((cleaned + cp_count))
        fi
    fi

    # 2. Clear per-run intelligence artifacts (not needed after completion)
    local intel_files=(
        "${ARTIFACTS_DIR}/classified-findings.json"
        "${ARTIFACTS_DIR}/reassessment.json"
        "${ARTIFACTS_DIR}/skip-stage.txt"
        "${ARTIFACTS_DIR}/human-message.txt"
    )
    local f
    for f in "${intel_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            cleaned=$((cleaned + 1))
        fi
    done

    # 3. Clear stale pipeline state (mark as idle so next run starts clean)
    if [[ -f "$STATE_FILE" ]]; then
        # Reset status to idle (preserves the file for reference but unblocks new runs)
        local tmp_state
        tmp_state=$(mktemp)
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_state'" RETURN
        sed 's/^status: .*/status: idle/' "$STATE_FILE" > "$tmp_state" 2>/dev/null || true
        mv "$tmp_state" "$STATE_FILE"
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "pipeline.cleanup" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cleaned=$cleaned" \
            "type=post_completion"
    fi
}

# Cancel any lingering in_progress GitHub Check Runs (called on abort/interrupt)
pipeline_cancel_check_runs() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return
    fi

    if ! type gh_checks_stage_update >/dev/null 2>&1; then
        return
    fi

    local ids_file="${ARTIFACTS_DIR:-/dev/null}/check-run-ids.json"
    [[ -f "$ids_file" ]] || return

    local stage
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        gh_checks_stage_update "$stage" "completed" "cancelled" "Pipeline interrupted" 2>/dev/null || true
    done < <(jq -r 'keys[]' "$ids_file" 2>/dev/null || true)
}

# ─── Dry Run Mode ───────────────────────────────────────────────────────────
# Shows what would happen without executing
run_dry_run() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━ Dry Run: Pipeline Validation ━━━${RESET}"
    echo ""

    # Validate pipeline config
    if [[ ! -f "$PIPELINE_CONFIG" ]]; then
        error "Pipeline config not found: $PIPELINE_CONFIG"
        return 1
    fi

    # Validate JSON structure
    local validate_json
    validate_json=$(jq . "$PIPELINE_CONFIG" 2>/dev/null) || {
        error "Pipeline config is not valid JSON: $PIPELINE_CONFIG"
        return 1
    }

    # Extract pipeline metadata
    local pipeline_name stages_count enabled_stages gated_stages
    pipeline_name=$(jq -r '.name // "unknown"' "$PIPELINE_CONFIG")
    stages_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_stages=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    gated_stages=$(jq '[.stages[] | select(.enabled == true and .gate == "approve")] | length' "$PIPELINE_CONFIG")

    # Build model (per-stage override or default)
    local default_model stage_model
    default_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG")
    stage_model="$MODEL"
    [[ -z "$stage_model" ]] && stage_model="$default_model"

    echo -e "  ${BOLD}Pipeline:${RESET}       $pipeline_name"
    echo -e "  ${BOLD}Stages:${RESET}         $enabled_stages enabled of $stages_count total"
    if [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}         ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}         $gated_stages approval gate(s)"
    fi
    echo -e "  ${BOLD}Model:${RESET}         $stage_model"
    echo ""

    # Table header
    echo -e "${CYAN}${BOLD}Stage         Enabled  Gate     Model${RESET}"
    echo -e "${CYAN}────────────────────────────────────────${RESET}"

    # List all stages
    while IFS= read -r stage_json; do
        local stage_id stage_enabled stage_gate stage_config_model stage_model_display
        stage_id=$(echo "$stage_json" | jq -r '.id')
        stage_enabled=$(echo "$stage_json" | jq -r '.enabled')
        stage_gate=$(echo "$stage_json" | jq -r '.gate')

        # Determine stage model (config override or default)
        stage_config_model=$(echo "$stage_json" | jq -r '.config.model // ""')
        if [[ -n "$stage_config_model" && "$stage_config_model" != "null" ]]; then
            stage_model_display="$stage_config_model"
        else
            stage_model_display="$default_model"
        fi

        # Format enabled
        local enabled_str
        if [[ "$stage_enabled" == "true" ]]; then
            enabled_str="${GREEN}yes${RESET}"
        else
            enabled_str="${DIM}no${RESET}"
        fi

        # Format gate
        local gate_str
        if [[ "$stage_enabled" == "true" ]]; then
            if [[ "$stage_gate" == "approve" ]]; then
                gate_str="${YELLOW}approve${RESET}"
            else
                gate_str="${GREEN}auto${RESET}"
            fi
        else
            gate_str="${DIM}—${RESET}"
        fi

        printf "%-15s %s  %s  %s\n" "$stage_id" "$enabled_str" "$gate_str" "$stage_model_display"
    done < <(jq -c '.stages[]' "$PIPELINE_CONFIG")

    echo ""

    # Validate required tools
    echo -e "${BLUE}${BOLD}━━━ Tool Validation ━━━${RESET}"
    echo ""

    local tool_errors=0
    local required_tools=("git" "jq")
    local ai_provider ai_cmd
    ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
    ai_cmd="$(ai_provider_command "$ai_provider" 2>/dev/null || echo "$ai_provider")"
    local optional_tools=("gh" "$ai_cmd" "bc")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            tool_errors=$((tool_errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool"
        fi
    done

    echo ""

    # Cost estimation: use historical averages from past pipelines when available
    echo -e "${BLUE}${BOLD}━━━ Estimated Resource Usage ━━━${RESET}"
    echo ""

    local stages_json
    stages_json=$(jq '[.stages[] | select(.enabled == true)]' "$PIPELINE_CONFIG" 2>/dev/null || echo "[]")
    local est
    est=$(estimate_pipeline_cost "$stages_json")
    local input_tokens_estimate output_tokens_estimate
    input_tokens_estimate=$(echo "$est" | jq -r '.input_tokens // 0')
    output_tokens_estimate=$(echo "$est" | jq -r '.output_tokens // 0')

    # Calculate cost based on selected model
    local input_rate output_rate input_cost output_cost total_cost
    input_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.input // 3" 2>/dev/null || echo "3")
    output_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.output // 15" 2>/dev/null || echo "15")

    # Cost calculation: tokens per million * rate
    input_cost=$(awk -v tokens="$input_tokens_estimate" -v rate="$input_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    output_cost=$(awk -v tokens="$output_tokens_estimate" -v rate="$output_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')

    echo -e "  ${BOLD}Estimated Input Tokens:${RESET}  ~$input_tokens_estimate"
    echo -e "  ${BOLD}Estimated Output Tokens:${RESET} ~$output_tokens_estimate"
    echo -e "  ${BOLD}Model Cost Rate:${RESET}        $stage_model"
    echo -e "  ${BOLD}Estimated Cost:${RESET}         \$$total_cost USD"
    echo ""

    # Validate composed pipeline if intelligence is enabled
    if [[ -f "$ARTIFACTS_DIR/composed-pipeline.json" ]] && type composer_validate_pipeline >/dev/null 2>&1; then
        echo -e "${BLUE}${BOLD}━━━ Intelligence-Composed Pipeline ━━━${RESET}"
        echo ""

        if composer_validate_pipeline "$(cat "$ARTIFACTS_DIR/composed-pipeline.json" 2>/dev/null || echo "")" 2>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} Composed pipeline is valid"
        else
            echo -e "  ${YELLOW}⚠${RESET} Composed pipeline validation failed (will use template defaults)"
        fi
        echo ""
    fi

    # Final validation result
    if [[ "$tool_errors" -gt 0 ]]; then
        error "Dry run validation failed: $tool_errors required tool(s) missing"
        return 1
    fi

    success "Dry run validation passed"
    echo ""
    echo -e "  To execute this pipeline: ${DIM}remove --dry-run flag${RESET}"
    echo ""
    return 0
}

# ─── Reasoning Trace Generation ──────────────────────────────────────────────
# Multi-step autonomous reasoning traces for pipeline start (before stages run)

generate_reasoning_trace() {
    local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
    local issue="${ISSUE_NUMBER:-}"
    local goal="${GOAL:-}"

    # Step 1: Analyze issue complexity and risk
    local complexity="medium"
    local risk_score=50
    if [[ -n "$issue" ]] && type intelligence_analyze_issue >/dev/null 2>&1; then
        local issue_json analysis
        issue_json=$(gh issue view "$issue" --json number,title,body,labels 2>/dev/null || echo "{}")
        if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then
                    complexity="low"
                elif [[ "$comp_num" -le 6 ]]; then
                    complexity="medium"
                else
                    complexity="high"
                fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    elif [[ -n "$goal" ]]; then
        issue_json=$(jq -n --arg title "${goal}" --arg body "" '{title: $title, body: $body, labels: []}')
        if type intelligence_analyze_issue >/dev/null 2>&1; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then complexity="low"; elif [[ "$comp_num" -le 6 ]]; then complexity="medium"; else complexity="high"; fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    fi

    # Step 2: Query similar past issues
    local similar_context=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        similar_context=$(memory_semantic_search "$goal" "" 3 2>/dev/null || echo "")
    fi

    # Step 3: Select template using Thompson sampling
    local selected_template="${PIPELINE_TEMPLATE:-}"
    if [[ -z "$selected_template" ]] && type thompson_select_template >/dev/null 2>&1; then
        selected_template=$(thompson_select_template "$complexity" 2>/dev/null || echo "standard")
    fi
    [[ -z "$selected_template" ]] && selected_template="standard"

    # Step 4: Predict failure modes from memory
    local failure_predictions=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        failure_predictions=$(memory_semantic_search "failure error $goal" "" 3 2>/dev/null || echo "")
    fi

    # Save reasoning traces to DB
    if type db_save_reasoning_trace >/dev/null 2>&1; then
        db_save_reasoning_trace "$job_id" "complexity_analysis" \
            "issue=$issue goal=$goal" \
            "Analyzed complexity=$complexity risk=$risk_score" \
            "complexity=$complexity risk_score=$risk_score" 0.7 2>/dev/null || true

        db_save_reasoning_trace "$job_id" "template_selection" \
            "complexity=$complexity historical_outcomes" \
            "Thompson sampling over historical success rates" \
            "template=$selected_template" 0.8 2>/dev/null || true

        if [[ -n "$similar_context" && "$similar_context" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "similar_issues" \
                "$goal" \
                "Found similar past issues for context injection" \
                "$similar_context" 0.6 2>/dev/null || true
        fi

        if [[ -n "$failure_predictions" && "$failure_predictions" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "failure_prediction" \
                "$goal" \
                "Predicted potential failure modes from history" \
                "$failure_predictions" 0.5 2>/dev/null || true
        fi
    fi

    # Export for use by pipeline stages
    [[ -n "$selected_template" && -z "${PIPELINE_TEMPLATE:-}" ]] && export PIPELINE_TEMPLATE="$selected_template"

    emit_event "reasoning.trace" "job_id=$job_id" "complexity=$complexity" "risk=$risk_score" "template=${selected_template:-standard}" 2>/dev/null || true
}
