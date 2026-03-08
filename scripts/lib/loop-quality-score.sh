#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_QUALITY_SCORE_LOADED:-}" ]] && return 0
_LOOP_QUALITY_SCORE_LOADED=1

# ─── Iteration Quality Scoring with Adaptive Prompting ────────────────────────
#
# Computes a weighted quality score per iteration based on:
#  - test_delta (40%):      Change in test count vs baseline (normalized to [0..100])
#  - compile_success (30%): Binary (100 if no compile errors, 0 if compile fails)
#  - error_reduction (20%): Percent reduction in error count from baseline
#  - code_churn (10%):      Risk assessment from changed lines (normalized to [0..100])
#
# Actions triggered by score:
#  - score < 15:  Escalate to Opus (high-cost, deep reasoning)
#  - score 15-30: Adapt prompt (inject examples, constraints, guidance)
#  - score >= 30: Continue current strategy
#
# Score history and components are logged to events.jsonl and loop-state.md
# for trend analysis and dashboard visualization.

# ─── Quality Metrics Tracking ──────────────────────────────────────────────────

# Initialize quality tracking state file (per session)
init_quality_state() {
    local state_file="$LOG_DIR/quality-scores.jsonl"

    # Create header comment with metric definitions
    {
        echo "# Iteration Quality Scores"
        echo "# Weights: test_delta=40%, compile_success=30%, error_reduction=20%, code_churn=10%"
        echo "# Score < 15: escalate to Opus, 15-30: adapt prompt, >= 30: continue"
        echo ""
    } > "$state_file"
}

# Extract baseline metrics from first iteration or previous best iteration
get_baseline_metrics() {
    local iteration="$1"
    local baseline_file="$LOG_DIR/baseline-metrics.txt"

    # On first iteration, establish baseline
    if [[ "$iteration" -le 1 ]]; then
        # Initialize baseline from current project state
        local test_count=0
        local error_count=0

        # Attempt to count tests from codebase (vitest compatible)
        if [[ -f "package.json" ]]; then
            test_count=$(grep -o '"test"' *.test.* 2>/dev/null | wc -l || echo 0)
            [[ "$test_count" -eq 0 ]] && test_count=$(find . -name "*.test.js" -o -name "*.test.ts" 2>/dev/null | wc -l || echo 0)
        fi

        {
            echo "iteration=1"
            echo "test_count=$test_count"
            echo "error_count=$error_count"
            echo "file_changes=0"
        } > "$baseline_file"

        echo "$baseline_file"
        return 0
    fi

    # On subsequent iterations, return baseline file if it exists
    if [[ -f "$baseline_file" ]]; then
        echo "$baseline_file"
        return 0
    fi

    # Fallback: return empty (will use zero baseline)
    return 1
}

# Normalize a raw metric to [0..100] scale
# Args: metric_value, min_acceptable, max_acceptable, invert (true/false)
# Returns: normalized score [0..100]
normalize_metric() {
    local value="$1"
    local min="$2"
    local max="$3"
    local invert="${4:-false}"

    # Handle edge cases
    if [[ -z "$value" ]]; then value=0; fi
    if [[ -z "$min" ]]; then min=0; fi
    if [[ -z "$max" ]]; then max=100; fi

    # Clamp to range
    if (( $(echo "$value < $min" | bc -l 2>/dev/null) )); then
        value="$min"
    elif (( $(echo "$value > $max" | bc -l 2>/dev/null) )); then
        value="$max"
    fi

    # Normalize to [0..100]
    local range=$(echo "$max - $min" | bc -l 2>/dev/null || echo 1)
    [[ "$range" == "0" ]] && range=1
    local normalized=$(echo "100 * ($value - $min) / $range" | bc -l 2>/dev/null || echo 50)

    if [[ "$invert" == "true" ]]; then
        normalized=$(echo "100 - $normalized" | bc -l 2>/dev/null || echo 50)
    fi

    # Return integer 0-100
    printf "%.0f" "$normalized"
}

# Compute test delta score (±N tests normalized to [0..100])
# A change of ±30 tests or more = extreme (0 or 100)
# No change = neutral (50)
compute_test_delta_score() {
    local prev_test_count="$1"
    local curr_test_count="$2"

    [[ -z "$prev_test_count" ]] && prev_test_count=0
    [[ -z "$curr_test_count" ]] && curr_test_count=0

    local delta=$(( curr_test_count - prev_test_count ))

    # Positive change (more tests) = good (up to 100 at +30 tests)
    # Negative change (fewer tests) = bad (down to 0 at -30 tests)
    # Neutral at 0 change = 50

    if [[ "$delta" -ge 30 ]]; then
        echo 100
    elif [[ "$delta" -le -30 ]]; then
        echo 0
    else
        # Map ±30 range to 0-100: delta ∈ [-30, 30] → score ∈ [0, 100]
        local score=$(( (delta + 30) * 100 / 60 ))
        echo "$score"
    fi
}

# Compute compile success score (100 if no compile errors, 0 if errors)
compute_compile_success_score() {
    local test_log="$1"

    # Check for compile/syntax errors in test output
    if grep -iq "error\|syntax\|failed to compile\|compilation failed" "$test_log" 2>/dev/null; then
        echo 0
    else
        echo 100
    fi
}

# Compute error reduction score (percent reduction from baseline to current)
compute_error_reduction_score() {
    local prev_error_count="$1"
    local curr_error_count="$2"

    [[ -z "$prev_error_count" ]] && prev_error_count=0
    [[ -z "$curr_error_count" ]] && curr_error_count=0

    # Edge case: no baseline errors
    if [[ "$prev_error_count" -eq 0 ]]; then
        if [[ "$curr_error_count" -eq 0 ]]; then
            echo 100  # Still good (no errors)
        else
            echo 0    # Introduced errors
        fi
        return 0
    fi

    # Percent reduction: (prev - curr) / prev * 100
    local reduction_pct=$(( (prev_error_count - curr_error_count) * 100 / prev_error_count ))

    # Clamp to [0, 100]
    if [[ "$reduction_pct" -lt 0 ]]; then
        echo 0
    elif [[ "$reduction_pct" -gt 100 ]]; then
        echo 100
    else
        echo "$reduction_pct"
    fi
}

# Compute code churn score (lines changed as fraction of total project size)
# High churn (>10%) = risky = lower score
# Low churn (<1%) = conservative = higher score
compute_code_churn_score() {
    local lines_added="$1"
    local lines_deleted="$2"
    local total_lines="$3"

    [[ -z "$lines_added" ]] && lines_added=0
    [[ -z "$lines_deleted" ]] && lines_deleted=0
    [[ -z "$total_lines" ]] && total_lines=1000

    local churn=$(( (lines_added + lines_deleted) * 100 / total_lines ))

    # Map churn [0..20%] to score [100..0]
    # 0% churn = 100 (no change)
    # 20% churn = 0 (very high risk)
    local score
    if [[ "$churn" -ge 20 ]]; then
        score=0
    elif [[ "$churn" -le 0 ]]; then
        score=100
    else
        score=$(( 100 - (churn * 5) ))
    fi

    echo "$score"
}

# ─── Main Scoring Function ─────────────────────────────────────────────────────

# Compute iteration quality score
# Returns: quality_score (0-100), and logs component breakdown
compute_iteration_quality_score() {
    local iteration="$1"
    local test_log="$2"
    local test_passed="${3:-unknown}"

    [[ -z "$iteration" ]] && iteration="$ITERATION"
    [[ -z "$test_log" ]] && test_log="$LOG_DIR/tests-iter-${iteration}.log"

    # Collect metrics
    local prev_test_count=0
    local curr_test_count=0
    local prev_error_count=0
    local curr_error_count=0
    local lines_added=0
    local lines_deleted=0
    local total_lines=1000

    # Try to extract metrics from test log
    if [[ -f "$test_log" ]]; then
        # Count test runs (lines starting with PASS/FAIL)
        curr_test_count=$(grep -c "^✓\|^✗\|PASS\|FAIL" "$test_log" 2>/dev/null || echo 0)

        # Count error lines
        curr_error_count=$(grep -ic "error" "$test_log" 2>/dev/null || echo 0)
    fi

    # Get git diff stats for churn
    if [[ -d ".git" ]]; then
        local diff_stat
        diff_stat=$(git diff --numstat HEAD 2>/dev/null | awk '{added+=$1; deleted+=$2} END {print added " " deleted}')
        read -r lines_added lines_deleted <<< "$diff_stat"

        # Total lines in repo
        total_lines=$(find . -type f \( -name "*.js" -o -name "*.ts" -o -name "*.tsx" \) 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo 1000)
    fi

    # Compute normalized component scores
    local test_delta_score
    test_delta_score=$(compute_test_delta_score "$prev_test_count" "$curr_test_count")

    local compile_score
    compile_score=$(compute_compile_success_score "$test_log")

    local error_reduction_score
    error_reduction_score=$(compute_error_reduction_score "$prev_error_count" "$curr_error_count")

    local churn_score
    churn_score=$(compute_code_churn_score "$lines_added" "$lines_deleted" "$total_lines")

    # Weighted average: test_delta=40%, compile_success=30%, error_reduction=20%, code_churn=10%
    local quality_score
    quality_score=$(echo "($test_delta_score * 0.40) + ($compile_score * 0.30) + ($error_reduction_score * 0.20) + ($churn_score * 0.10)" | bc -l 2>/dev/null)
    quality_score=$(printf "%.0f" "$quality_score")

    # Log component breakdown
    if [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]]; then
        {
            echo "{\"iteration\":$iteration,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"quality_score\":$quality_score,\"components\":{\"test_delta\":$test_delta_score,\"compile_success\":$compile_score,\"error_reduction\":$error_reduction_score,\"code_churn\":$churn_score}}"
        } >> "$LOG_DIR/quality-scores.jsonl" 2>/dev/null || true
    fi

    # Emit event
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop.quality_scored" \
            "iteration=$iteration" \
            "quality_score=$quality_score" \
            "test_delta=$test_delta_score" \
            "compile_success=$compile_score" \
            "error_reduction=$error_reduction_score" \
            "code_churn=$churn_score" \
            "test_passed=$test_passed" 2>/dev/null || true
    fi

    echo "$quality_score"
}

# ─── Adaptive Actions Based on Quality Score ────────────────────────────────────

# Check if quality score triggers prompt adaptation
should_adapt_prompt() {
    local quality_score="$1"
    local iteration="$2"

    [[ -z "$quality_score" ]] && return 1
    [[ -z "$iteration" ]] && iteration="$ITERATION"

    # Threshold: score < 30 triggers adaptation
    [[ "$quality_score" -lt 30 ]]
}

# Check if quality score triggers model escalation
should_escalate_model() {
    local quality_score="$1"
    local iteration="$2"
    local escalation_state_file="$LOG_DIR/escalation-state.txt"

    [[ -z "$quality_score" ]] && return 1
    [[ -z "$iteration" ]] && iteration="$ITERATION"

    # Threshold: score < 15 for 2+ consecutive iterations triggers escalation
    if [[ "$quality_score" -lt 15 ]]; then
        # Read escalation counter
        local escalation_count=0
        if [[ -f "$escalation_state_file" ]]; then
            escalation_count=$(cat "$escalation_state_file" 2>/dev/null || echo 0)
        fi

        escalation_count=$(( escalation_count + 1 ))
        echo "$escalation_count" > "$escalation_state_file"

        # Trigger on 2+ consecutive low scores
        [[ "$escalation_count" -ge 2 ]]
    else
        # Reset counter on good score
        echo "0" > "$escalation_state_file" 2>/dev/null || true
        return 1
    fi
}

# Adapt prompt based on low quality score
adapt_prompt_for_quality() {
    local quality_score="$1"
    local iteration="$2"

    [[ -z "$quality_score" ]] && return
    [[ -z "$iteration" ]] && iteration="$ITERATION"

    if ! should_adapt_prompt "$quality_score" "$iteration"; then
        return
    fi

    local adaptation=""

    # Score-based guidance
    if [[ "$quality_score" -lt 15 ]]; then
        adaptation="⚠ Quality score: $quality_score (CRITICAL LOW). This iteration made minimal progress. Be strategic: focus on small, well-tested changes. Avoid refactoring or complex features. Verify your changes don't break existing functionality."
    elif [[ "$quality_score" -lt 30 ]]; then
        adaptation="⚠ Quality score: $quality_score (LOW). Progress is slow. Review what's blocking you and try a different approach. Add test coverage incrementally. Commit working code frequently."
    fi

    if [[ -n "$adaptation" ]]; then
        # Inject into GOAL for next iteration
        GOAL="${GOAL}

## Iteration Quality Feedback
$adaptation"

        # Log adaptation
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.quality_adapted" \
                "iteration=$iteration" \
                "quality_score=$quality_score" \
                "action=prompt_adaptation" 2>/dev/null || true
        fi
    fi
}

# Escalate to Opus model based on low quality score
escalate_model_for_quality() {
    local quality_score="$1"
    local iteration="$2"
    local current_model="${3:-haiku}"

    [[ -z "$quality_score" ]] && return
    [[ -z "$iteration" ]] && iteration="$ITERATION"

    if ! should_escalate_model "$quality_score" "$iteration"; then
        return
    fi

    # Escalate model to Opus
    export CLAUDE_MODEL="opus"
    export SW_ESCALATED_MODEL="opus"

    info "Quality score $quality_score on iteration $iteration — escalating to Opus model"

    # Log escalation
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop.quality_escalated" \
            "iteration=$iteration" \
            "quality_score=$quality_score" \
            "previous_model=$current_model" \
            "escalated_model=opus" 2>/dev/null || true
    fi

    return 0
}

# ─── Dashboard Integration ────────────────────────────────────────────────────

# Append quality score to loop-state.md for dashboard visibility
append_quality_score_to_state() {
    local quality_score="$1"
    local iteration="$2"
    local components_json="$3"

    [[ -z "$quality_score" ]] && return
    [[ -z "$iteration" ]] && iteration="$ITERATION"

    local state_file="$LOG_DIR/loop-state.md"

    if [[ ! -f "$state_file" ]]; then
        return
    fi

    # Append quality score section to state file
    {
        echo ""
        echo "## Iteration Quality (Iteration $iteration)"
        echo "- Quality Score: $quality_score/100"
        if [[ -n "$components_json" ]]; then
            echo "- Components: $components_json"
        fi
    } >> "$state_file" 2>/dev/null || true
}
