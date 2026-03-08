#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-self-heal.sh — Build→Test and Review self-healing loops        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_SELF_HEAL_LOADED:-}" ]] && return 0
_PIPELINE_SELF_HEAL_LOADED=1

VERSION="3.2.4"

# ─── Self-Healing Build→Test Feedback Loop ─────────────────────────────────
# When tests fail after a build, this captures the error and re-runs the build
# with the error context, so Claude can fix the issue automatically.

self_healing_build_test() {
    local cycle=0
    local max_cycles="$BUILD_TEST_RETRIES"
    local last_test_error=""

    # Convergence tracking
    local prev_error_sig="" consecutive_same_error=0
    local prev_fail_count=0 zero_convergence_streak=0

    # Vitals-driven adaptive limit (preferred over static BUILD_TEST_RETRIES)
    if type pipeline_adaptive_limit >/dev/null 2>&1; then
        local _vitals_json=""
        if type pipeline_compute_vitals >/dev/null 2>&1; then
            _vitals_json=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_limit
        vitals_limit=$(pipeline_adaptive_limit "build_test" "$_vitals_json" 2>/dev/null) || true
        if [[ -n "$vitals_limit" && "$vitals_limit" =~ ^[0-9]+$ && "$vitals_limit" -gt 0 ]]; then
            info "Vitals-driven build-test limit: ${max_cycles} → ${vitals_limit}"
            max_cycles="$vitals_limit"
            emit_event "vitals.adaptive_limit" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=build_test" \
                "original=$BUILD_TEST_RETRIES" \
                "vitals_limit=$vitals_limit"
        fi
    # Fallback: intelligence-based adaptive limits
    elif type composer_estimate_iterations >/dev/null 2>&1; then
        local estimated
        estimated=$(composer_estimate_iterations \
            "${INTELLIGENCE_ANALYSIS:-{}}" \
            "${HOME}/.shipwright/optimization/iteration-model.json" 2>/dev/null || echo "")
        if [[ -n "$estimated" && "$estimated" =~ ^[0-9]+$ && "$estimated" -gt 0 ]]; then
            max_cycles="$estimated"
            emit_event "intelligence.adaptive_iterations" \
                "issue=${ISSUE_NUMBER:-0}" \
                "estimated=$estimated" \
                "original=$BUILD_TEST_RETRIES"
        fi
    fi

    # Fallback: adaptive cycle limits from optimization data
    if [[ "$max_cycles" == "$BUILD_TEST_RETRIES" ]]; then
        local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_iter_model" ]]; then
            local adaptive_bt_limit
            adaptive_bt_limit=$(pipeline_adaptive_cycles "$max_cycles" "build_test" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_bt_limit" && "$adaptive_bt_limit" =~ ^[0-9]+$ && "$adaptive_bt_limit" -gt 0 && "$adaptive_bt_limit" != "$max_cycles" ]]; then
                info "Adaptive build-test cycles: ${max_cycles} → ${adaptive_bt_limit}"
                max_cycles="$adaptive_bt_limit"
            fi
        fi
    fi

    while [[ "$cycle" -le "$max_cycles" ]]; do
        cycle=$((cycle + 1))

        if [[ "$cycle" -gt 1 ]]; then
            SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
            echo ""
            echo -e "${YELLOW}${BOLD}━━━ Self-Healing Cycle ${cycle}/$((max_cycles + 1)) ━━━${RESET}"
            info "Feeding test failure back to build loop..."

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "🔄 **Self-healing cycle ${cycle}** — rebuilding with error context" 2>/dev/null || true
            fi

            # Reset build/test stage statuses for retry
            set_stage_status "build" "retrying"
            set_stage_status "test" "pending"
        fi

        # ── Run Build Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: build${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="build"

        # Inject error context on retry cycles
        if [[ "$cycle" -gt 1 && -n "$last_test_error" ]]; then
            # Query memory for known fixes
            local _memory_fix=""
            if type memory_closed_loop_inject >/dev/null 2>&1; then
                local _error_sig_short
                _error_sig_short=$(echo "$last_test_error" | head -3 || echo "")
                _memory_fix=$(memory_closed_loop_inject "$_error_sig_short" 2>/dev/null) || true
            fi

            local memory_prefix=""
            if [[ -n "$_memory_fix" ]]; then
                info "Memory suggests fix: $(echo "$_memory_fix" | head -1)"
                memory_prefix="KNOWN FIX (from past success): ${_memory_fix}

"
            fi

            # Temporarily augment the goal with error context
            local original_goal="$GOAL"
            GOAL="$GOAL

${memory_prefix}IMPORTANT — Previous build attempt failed tests. Fix these errors:
$last_test_error

Focus on fixing the failing tests while keeping all passing tests working."

            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                GOAL="$original_goal"
                return 1
            fi
            GOAL="$original_goal"
        else
            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                return 1
            fi
        fi

        # ── Run Test Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: test${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="test"
        update_status "running" "test"
        record_stage_start "test"

        if run_stage_with_retry "test"; then
            mark_stage_complete "test"
            local timing
            timing=$(get_stage_timing "test")
            success "Stage ${BOLD}test${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "convergence.tests_passed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle"
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                local _diff_count
                _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                local _snap_files _snap_error
                _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                _snap_files="${_snap_files:-0}"
                _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                _snap_error="${_snap_error:-}"
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-test}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
            fi
            # Record fix outcome when tests pass after a retry with memory injection (pipeline path)
            if [[ "$cycle" -gt 1 && -n "${last_test_error:-}" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                local _sig
                _sig=$(echo "$last_test_error" | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
                [[ -n "$_sig" ]] && bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_sig" "true" "true" 2>/dev/null || true
            fi
            return 0  # Tests passed!
        fi

        # Tests failed — capture error for next cycle
        local test_log="$ARTIFACTS_DIR/test-results.log"

        # Detect infrastructure errors that self-healing cannot fix (no point cycling)
        if grep -q "Unable to find a device matching" "$test_log" 2>/dev/null; then
            error "Infrastructure error: simulator not found — self-healing cannot fix this"
            error "Check 'xcrun simctl list devices available' and fix the test destination"
            if [[ -n "${ISSUE_NUMBER:-}" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "❌ **Infrastructure error**: simulator destination not found. This is a test configuration issue, not a code problem. Fix the simulator setup and re-run." >/dev/null 2>&1 || true
            fi
            mark_stage_failed "test"
            return 1
        fi

        # Extract meaningful errors — skip simulator destination lists and boilerplate
        last_test_error=$(grep -vE '^\s*\{ platform:|Available destinations|The requested device|no available devices' "$test_log" 2>/dev/null \
            | grep -E 'error:|FAIL|fail:|assert|panic|xcodebuild: error|Build FAILED|Undefined symbol|cannot find|fatal' 2>/dev/null \
            | tail -20 || true)
        if [[ -z "$last_test_error" ]]; then
            # Fallback: get last lines but still filter out sim list
            last_test_error=$(grep -vE '^\s*\{ platform:|Available destinations|The requested device|no available devices' "$test_log" 2>/dev/null | tail -15 || echo "Test command failed with no output")
        fi
        mark_stage_failed "test"

        # ── Convergence Detection ──
        # Hash the error output to detect repeated failures
        local error_sig
        error_sig=$(echo "$last_test_error" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "unknown")

        # Count failing tests (extract from common patterns)
        local current_fail_count=0
        current_fail_count=$(grep -ciE 'fail|error|FAIL' "$test_log" 2>/dev/null || true)
        current_fail_count="${current_fail_count:-0}"

        if [[ "$error_sig" == "$prev_error_sig" ]]; then
            consecutive_same_error=$((consecutive_same_error + 1))
        else
            consecutive_same_error=1
        fi
        prev_error_sig="$error_sig"

        # Check: same error 3 times consecutively → stuck
        if [[ "$consecutive_same_error" -ge 3 ]]; then
            error "Convergence: stuck on same error for 3 consecutive cycles — exiting early"
            emit_event "convergence.stuck" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "error_sig=$error_sig" \
                "consecutive=$consecutive_same_error"
            notify "Build Convergence" "Stuck on unfixable error after ${cycle} cycles" "error"
            return 1
        fi

        # Track convergence rate: did we reduce failures?
        if [[ "$cycle" -gt 1 && "$prev_fail_count" -gt 0 ]]; then
            if [[ "$current_fail_count" -ge "$prev_fail_count" ]]; then
                zero_convergence_streak=$((zero_convergence_streak + 1))
            else
                zero_convergence_streak=0
            fi

            # Check: zero convergence for 2 consecutive iterations → plateau
            if [[ "$zero_convergence_streak" -ge 2 ]]; then
                error "Convergence: no progress for 2 consecutive cycles (${current_fail_count} failures remain) — exiting early"
                emit_event "convergence.plateau" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "cycle=$cycle" \
                    "fail_count=$current_fail_count" \
                    "streak=$zero_convergence_streak"
                notify "Build Convergence" "No progress after ${cycle} cycles — plateau reached" "error"
                return 1
            fi
        fi
        prev_fail_count="$current_fail_count"

        info "Convergence: error_sig=${error_sig:0:8} repeat=${consecutive_same_error} failures=${current_fail_count} no_progress=${zero_convergence_streak}"

        if [[ "$cycle" -le "$max_cycles" ]]; then
            warn "Tests failed — will attempt self-healing (cycle $((cycle + 1))/$((max_cycles + 1)))"
            notify "Self-Healing" "Tests failed on cycle ${cycle}, retrying..." "warn"
        fi
    done

    error "Self-healing exhausted after $((max_cycles + 1)) cycles"
    notify "Self-Healing Failed" "Tests still failing after $((max_cycles + 1)) build-test cycles" "error"
    return 1
}

# ─── Review Self-Healing ──────────────────────────────────────────────────
# When the review stage blocks on critical/security issues, inject the review
# findings back into the build loop goal and re-run build→test→review until
# all issues are resolved or retry cycles are exhausted.

self_healing_review_build_test() {
    local cycle=0
    local max_cycles="$REVIEW_BUILD_RETRIES"
    local blockers_file="$ARTIFACTS_DIR/review-blockers.md"

    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
        echo ""
        echo -e "${YELLOW}${BOLD}━━━ Review Self-Healing Cycle ${cycle}/${max_cycles} ━━━${RESET}"
        info "Injecting review findings into build loop..."

        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" \
                "🔄 **Review self-healing cycle ${cycle}** — rebuilding to address review blockers" 2>/dev/null || true
        fi

        # Load review blockers
        local review_context=""
        if [[ -f "$blockers_file" ]]; then
            review_context=$(cat "$blockers_file")
        fi
        if [[ -z "${review_context// }" ]]; then
            review_context="Code review found critical/security issues that must be fixed."
        fi

        # Inject review blockers into goal for the build loop
        local original_goal="$GOAL"
        GOAL="$GOAL

IMPORTANT — Code review found critical/security issues that MUST be fixed:
${review_context}

Fix ALL of the above issues completely. Do not introduce any new critical or security issues."

        # Re-run build→test loop with the review context in goal
        if ! self_healing_build_test; then
            GOAL="$original_goal"
            error "Build loop failed during review self-healing cycle ${cycle}"
            return 1
        fi
        GOAL="$original_goal"

        # Build+test passed — re-run review to check if blockers are resolved
        echo ""
        echo -e "${CYAN}${BOLD}▸ Re-running review (self-healing cycle ${cycle})${RESET}"
        CURRENT_STAGE_ID="review"
        update_status "running" "review"
        record_stage_start "review"
        set_stage_status "review" "pending"

        if run_stage_with_retry "review"; then
            mark_stage_complete "review"
            local timing
            timing=$(get_stage_timing "review")
            success "Stage ${BOLD}review${RESET} complete after self-healing ${DIM}(${timing})${RESET}"
            emit_event "review.self_healed" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
            return 0
        fi

        # Review still blocked — refresh blockers for next cycle
        grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$ARTIFACTS_DIR/review.md" \
            > "$blockers_file" 2>/dev/null || true
        warn "Review still blocked after cycle ${cycle}"
        emit_event "review.still_blocked" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
    done

    error "Review self-healing exhausted after ${max_cycles} cycle(s)"
    return 1
}

# ─── Auto-Rebase ──────────────────────────────────────────────────────────

auto_rebase() {
    info "Syncing with ${BASE_BRANCH}..."

    # Fetch latest — GIT_TERMINAL_PROMPT=0 prevents blocking on HTTPS credential prompts
    GIT_TERMINAL_PROMPT=0 git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || {
        warn "Could not fetch origin/${BASE_BRANCH}"
        return 0
    }

    # Check if rebase is needed
    local behind
    behind=$(git rev-list --count "HEAD..origin/${BASE_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        success "Already up to date with ${BASE_BRANCH}"
        return 0
    fi

    info "Rebasing onto origin/${BASE_BRANCH} ($behind commits behind)..."
    if git rebase "origin/${BASE_BRANCH}" --quiet 2>/dev/null; then
        success "Rebase successful"
    else
        warn "Rebase conflict detected — aborting rebase"
        git rebase --abort 2>/dev/null || true
        warn "Falling back to merge..."
        if git merge "origin/${BASE_BRANCH}" --no-edit --quiet 2>/dev/null; then
            success "Merge successful"
        else
            git merge --abort 2>/dev/null || true
            error "Both rebase and merge failed — manual intervention needed"
            return 1
        fi
    fi
}
