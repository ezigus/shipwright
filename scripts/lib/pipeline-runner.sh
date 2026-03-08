#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-runner.sh — Stage execution with retry and error classification║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_RUNNER_LOADED:-}" ]] && return 0
_PIPELINE_RUNNER_LOADED=1

VERSION="3.2.4"

# ─── Error Classification ──────────────────────────────────────────────────
# Classifies errors to determine whether retrying makes sense.
# Returns: "infrastructure", "logic", "configuration", or "unknown"

classify_error() {
    local stage_id="$1"
    local log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
    [[ ! -f "$log_file" ]] && log_file="${ARTIFACTS_DIR}/test-results.log"
    [[ ! -f "$log_file" ]] && { echo "unknown"; return; }

    local log_tail
    log_tail=$(tail -50 "$log_file" 2>/dev/null || echo "")

    # Generate error signature for history lookup
    local error_sig
    error_sig=$(echo "$log_tail" | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -3 | cksum | awk '{print $1}' || echo "0")

    # Check classification history first (learned from previous runs)
    local class_history="${HOME}/.shipwright/optimization/error-classifications.json"
    if [[ -f "$class_history" ]]; then
        local cached_class
        cached_class=$(jq -r --arg sig "$error_sig" '.[$sig].classification // empty' "$class_history" 2>/dev/null || true)
        if [[ -n "$cached_class" && "$cached_class" != "null" ]]; then
            echo "$cached_class"
            return
        fi
    fi

    local classification="unknown"

    # Infrastructure errors: timeout, OOM, network — retry makes sense
    if echo "$log_tail" | grep -qiE 'timeout|timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|network|socket hang up|OOM|out of memory|killed|signal 9|Cannot allocate memory'; then
        classification="infrastructure"
    # Configuration errors: missing env, wrong path — don't retry, escalate
    elif echo "$log_tail" | grep -qiE 'ENOENT|not found|No such file|command not found|MODULE_NOT_FOUND|Cannot find module|missing.*env|undefined variable|permission denied|EACCES'; then
        classification="configuration"
    # Logic errors: assertion failures, type errors — retry won't help without code change
    elif echo "$log_tail" | grep -qiE 'AssertionError|assert.*fail|Expected.*but.*got|TypeError|ReferenceError|SyntaxError|CompileError|type mismatch|cannot assign|incompatible type'; then
        classification="logic"
    # Build errors: compilation failures
    elif echo "$log_tail" | grep -qiE 'error\[E[0-9]+\]|error: aborting|FAILED.*compile|build failed|tsc.*error|eslint.*error'; then
        classification="logic"
    # Intelligence fallback: Claude classification for unknown errors
    elif [[ "$classification" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && [[ "$(type -t ai_run_json 2>/dev/null)" == "function" ]]; then
        local ai_class ai_json ai_provider ai_out ai_err
        ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
        ai_out=$(mktemp "${TMPDIR:-/tmp}/sw-classify-ai.XXXXXX")
        ai_err=$(mktemp "${TMPDIR:-/tmp}/sw-classify-ai-err.XXXXXX")
        ai_json=$(ai_run_json "$ai_provider" "Classify this error as exactly one of: infrastructure, configuration, logic, unknown.

Error output:
$(echo "$log_tail" | tail -20)

Reply with ONLY the classification word, nothing else." "haiku" "1" "$ai_out" "$ai_err" 2>/dev/null || true)
        rm -f "$ai_out" "$ai_err"
        ai_class=$(echo "$ai_json" | jq -r '.result_text // ""' 2>/dev/null || echo "")
        ai_class=$(echo "$ai_class" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$ai_class" in
            infrastructure|configuration|logic) classification="$ai_class" ;;
        esac
    fi

    # Map retry categories to shared taxonomy (from lib/compat.sh SW_ERROR_CATEGORIES)
    # Retry uses: infrastructure, configuration, logic, unknown
    # Shared uses: test_failure, build_error, lint_error, timeout, dependency, flaky, config, security, permission, unknown
    local canonical_category="unknown"
    case "$classification" in
        infrastructure) canonical_category="timeout" ;;
        configuration)  canonical_category="config" ;;
        logic)
            case "$stage_id" in
                test) canonical_category="test_failure" ;;
                *)    canonical_category="build_error" ;;
            esac
            ;;
    esac

    # Record classification for future runs (using both retry and canonical categories)
    if [[ -n "$error_sig" && "$error_sig" != "0" ]]; then
        local class_dir="${HOME}/.shipwright/optimization"
        mkdir -p "$class_dir" 2>/dev/null || true
        local tmp_class
        tmp_class="$(mktemp)"
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_class'" RETURN
        if [[ -f "$class_history" ]]; then
            jq --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '.[$sig] = {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}' \
                "$class_history" > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        else
            jq -n --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '{($sig): {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}}' \
                > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        fi
    fi

    echo "$classification"
}

# ─── Stage Runner ───────────────────────────────────────────────────────────

run_stage_with_retry() {
    local stage_id="$1"
    local max_retries
    max_retries=$(jq -r --arg id "$stage_id" '(.stages[] | select(.id == $id) | .config.retries) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_retries" || "$max_retries" == "null" ]] && max_retries=0

    local attempt=0
    local prev_error_class=""
    while true; do
        if "stage_${stage_id}"; then
            return 0
        fi

        # Capture error_class and error snippet for stage.failed / pipeline.completed events
        local error_class
        error_class=$(classify_error "$stage_id")
        LAST_STAGE_ERROR_CLASS="$error_class"
        LAST_STAGE_ERROR=""
        local _log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
        [[ ! -f "$_log_file" ]] && _log_file="${ARTIFACTS_DIR}/test-results.log"
        if [[ -f "$_log_file" ]]; then
            LAST_STAGE_ERROR=$(tail -20 "$_log_file" 2>/dev/null | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -1 | cut -c1-200 || true)
        fi

        attempt=$((attempt + 1))

        # Critical fix: if plan stage already has a valid artifact, skip retry
        if [[ "$stage_id" == "plan" ]]; then
            local plan_artifact="${ARTIFACTS_DIR}/plan.md"
            if [[ -s "$plan_artifact" ]]; then
                local existing_lines
                existing_lines=$(wc -l < "$plan_artifact" 2>/dev/null | xargs)
                existing_lines="${existing_lines:-0}"
                if [[ "$existing_lines" -gt 10 ]]; then
                    info "Plan already exists (${existing_lines} lines) — skipping retry, advancing"
                    emit_event "retry.skipped_existing_artifact" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "artifact_lines=$existing_lines"
                    return 0
                fi
            fi
        fi

        if [[ "$attempt" -gt "$max_retries" ]]; then
            return 1
        fi

        # Classify done above; decide whether retry makes sense

        emit_event "retry.classified" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "error_class=$error_class"

        case "$error_class" in
            infrastructure)
                info "Error classified as infrastructure (timeout/network/OOM) — retry makes sense"
                ;;
            configuration)
                error "Error classified as configuration (missing env/path) — skipping retry, escalating"
                emit_event "retry.escalated" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$stage_id" \
                    "reason=configuration_error"
                return 1
                ;;
            logic)
                if [[ "$error_class" == "$prev_error_class" ]]; then
                    error "Error classified as logic (assertion/type error) with same class — retry won't help without code change"
                    emit_event "retry.skipped" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "reason=repeated_logic_error"
                    return 1
                fi
                warn "Error classified as logic — retrying once in case build fixes it"
                ;;
            *)
                info "Error classification: unknown — retrying"
                ;;
        esac
        prev_error_class="$error_class"

        if type db_save_reasoning_trace >/dev/null 2>&1; then
            local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
            local error_msg="${LAST_STAGE_ERROR:-$error_class}"
            db_save_reasoning_trace "$job_id" "retry_reasoning" \
                "stage=$stage_id error=$error_msg" \
                "Stage failed, analyzing error pattern before retry" \
                "retry_strategy=self_heal" 0.6 2>/dev/null || true
        fi

        warn "Stage $stage_id failed (attempt $attempt/$((max_retries + 1)), class: $error_class) — retrying..."
        # Exponential backoff with jitter to avoid thundering herd
        local backoff=$((2 ** attempt))
        [[ "$backoff" -gt 16 ]] && backoff=16
        local jitter=$(( RANDOM % (backoff + 1) ))
        local total_sleep=$((backoff + jitter))
        info "Backing off ${total_sleep}s before retry..."
        sleep "$total_sleep"

        # Write debugging context for the retry attempt to consume
        local _retry_ctx_file="${ARTIFACTS_DIR}/.retry-context-${stage_id}.md"
        {
            echo "## Previous Attempt Failed"
            echo ""
            echo "**Error classification:** ${error_class}"
            echo "**Attempt:** ${attempt} of $((max_retries + 1))"
            echo ""
            echo "### Error Output (last 30 lines)"
            echo '```'
            tail -30 "$_log_file" 2>/dev/null || echo "(no log available)"
            echo '```'
            echo ""
            # Check for existing artifacts that should be preserved
            local _existing_artifacts=""
            for _af in plan.md design.md test-results.log; do
                if [[ -s "${ARTIFACTS_DIR}/${_af}" ]]; then
                    local _af_lines
                    _af_lines=$(wc -l < "${ARTIFACTS_DIR}/${_af}" 2>/dev/null | xargs)
                    _existing_artifacts="${_existing_artifacts}  - ${_af} (${_af_lines} lines)\n"
                fi
            done
            if [[ -n "$_existing_artifacts" ]]; then
                echo "### Existing Artifacts (PRESERVE these)"
                echo -e "$_existing_artifacts"
                echo "These artifacts exist from previous successful stages. Use them as-is unless they are the source of the problem."
                echo ""
            fi
            # Adaptive: check if additional skills could help this retry
            if type skill_memory_get_recommendations >/dev/null 2>&1; then
                local _retry_skills
                _retry_skills=$(skill_memory_get_recommendations "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null || true)
                if [[ -n "$_retry_skills" ]]; then
                    echo "### Skills Recommended by Learning System"
                    echo "Based on historical success rates, these skills may improve the retry:"
                    echo "- $(printf '%s' "$_retry_skills" | sed 's/,/\n- /g')"
                    echo ""
                fi
            fi

            echo "### Investigation Required"
            echo "Before attempting a fix:"
            echo "1. Read the error output above carefully"
            echo "2. Identify the ROOT CAUSE — not just the symptom"
            echo "3. If previous artifacts exist and are correct, build on them"
            echo "4. If previous artifacts are flawed, explain what's wrong before fixing"
        } > "$_retry_ctx_file" 2>/dev/null || true

        emit_event "retry.context_written" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "context_file=$_retry_ctx_file"
    done
}
