#\!/usr/bin/env bash
# pipeline-stages-intake.sh — Stage implementations
# Source from sw-pipeline.sh. Requires all pipeline globals and state/github/detection/quality modules.
set -euo pipefail

# Module guard - prevent double-sourcing
[[ -n "${PIPELINE_STAGES_INTAKE_LOADED:-}" ]] && return 0
PIPELINE_STAGES_INTAKE_LOADED=1

prune_context_section() {
    local section_name="${1:-section}"
    local content="${2:-}"
    local max_chars="${3:-5000}"

    [[ -z "$content" ]] && return 0

    local content_len=${#content}
    if [[ "$content_len" -le "$max_chars" ]]; then
        printf '%s' "$content"
        return 0
    fi

    # JSON content — try jq summary extraction
    local first_char="${content:0:1}"
    if [[ "$first_char" == "{" || "$first_char" == "[" ]]; then
        local summary=""
        # Try extracting summary/results fields
        summary=$(printf '%s' "$content" | jq -r '
            if type == "object" then
                to_entries | map(
                    if (.value | type) == "array" then
                        "\(.key): \(.value | length) items"
                    elif (.value | type) == "object" then
                        "\(.key): \(.value | keys | join(", "))"
                    else
                        "\(.key): \(.value)"
                    end
                ) | join("\n")
            elif type == "array" then
                .[:5] | map(tostring) | join("\n")
            else . end
        ' 2>/dev/null) || true

        if [[ -n "$summary" && ${#summary} -le "$max_chars" ]]; then
            printf '%s' "$summary"
            return 0
        fi
        # jq failed or still too large — fall through to text truncation
    fi

    # Text content — sandwich approach (first N + last N lines)
    local line_count=0
    line_count=$(printf '%s\n' "$content" | wc -l | xargs)

    # Calculate how many lines to keep from each end
    # Approximate chars-per-line to figure out line budget
    local avg_chars_per_line=80
    if [[ "$line_count" -gt 0 ]]; then
        avg_chars_per_line=$(( content_len / line_count ))
        [[ "$avg_chars_per_line" -lt 20 ]] && avg_chars_per_line=20
    fi
    local total_lines_budget=$(( max_chars / avg_chars_per_line ))
    [[ "$total_lines_budget" -lt 4 ]] && total_lines_budget=4
    local half=$(( total_lines_budget / 2 ))

    local head_part=""
    local tail_part=""
    head_part=$(printf '%s\n' "$content" | head -"$half")
    tail_part=$(printf '%s\n' "$content" | tail -"$half")

    printf '%s\n[... %s truncated: %d→%d chars ...]\n%s' \
        "$head_part" "$section_name" "$content_len" "$max_chars" "$tail_part"
}


guard_prompt_size() {
    local stage_name="${1:-stage}"
    local prompt="${2:-}"
    local max_chars="${3:-$PIPELINE_PROMPT_BUDGET}"

    local prompt_len=${#prompt}
    if [[ "$prompt_len" -le "$max_chars" ]]; then
        printf '%s' "$prompt"
        return 0
    fi

    warn "${stage_name} prompt too large (${prompt_len} chars, budget ${max_chars}) — truncating"
    emit_event "pipeline.prompt_truncated" \
        "stage=$stage_name" \
        "original=$prompt_len" \
        "budget=$max_chars" 2>/dev/null || true

    printf '%s\n\n... [CONTEXT TRUNCATED: %s prompt exceeded %d char budget. Focus on the goal and requirements.]' \
        "${prompt:0:$max_chars}" "$stage_name" "$max_chars"
}


_safe_base_log() {
    local branch="${BASE_BRANCH:-main}"
    git rev-parse --verify "$branch" >/dev/null 2>&1 || { echo ""; return 0; }
    git log "$@" "${branch}..HEAD" 2>/dev/null || true
}


_safe_base_diff() {
    local branch="${BASE_BRANCH:-main}"
    git rev-parse --verify "$branch" >/dev/null 2>&1 || { git diff HEAD~5 "$@" 2>/dev/null || true; return 0; }
    git diff "${branch}...HEAD" "$@" 2>/dev/null || true
}


show_stage_preview() {
    local stage_id="$1"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Stage: ${stage_id} ━━━${RESET}"
    case "$stage_id" in
        intake)   echo -e "  Fetch issue, detect task type, create branch, self-assign" ;;
        plan)     echo -e "  Generate plan via Claude, post task checklist to issue" ;;
        design)   echo -e "  Generate Architecture Decision Record (ADR), evaluate alternatives" ;;
        build)    echo -e "  Delegate to ${CYAN}shipwright loop${RESET} for autonomous building" ;;
        test_first) echo -e "  Generate tests from requirements (TDD mode) before implementation" ;;
        test)     echo -e "  Run test suite and check coverage" ;;
        review)   echo -e "  AI code review on the diff, post findings" ;;
        compound_quality) echo -e "  Adversarial review, negative tests, e2e, DoD audit" ;;
        pr)       echo -e "  Create GitHub PR with labels, reviewers, milestone" ;;
        merge)    echo -e "  Wait for CI checks, merge PR, optionally delete branch" ;;
        deploy)   echo -e "  Deploy to staging/production with rollback" ;;
        validate) echo -e "  Smoke tests, health checks, close issue" ;;
        monitor)  echo -e "  Post-deploy monitoring, health checks, auto-rollback" ;;
    esac
    echo ""
}


stage_intake() {
    CURRENT_STAGE_ID="intake"
    local project_lang
    project_lang=$(detect_project_lang)
    info "Project: ${BOLD}$project_lang${RESET}"

    # 1. Fetch issue metadata if --issue provided
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local meta
        meta=$(gh_get_issue_meta "$ISSUE_NUMBER")

        if [[ -n "$meta" ]]; then
            GOAL=$(echo "$meta" | jq -r '.title // ""')
            ISSUE_BODY=$(echo "$meta" | jq -r '.body // ""')
            ISSUE_LABELS=$(echo "$meta" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)
            ISSUE_MILESTONE=$(echo "$meta" | jq -r '.milestone.title // ""' 2>/dev/null || true)
            ISSUE_ASSIGNEES=$(echo "$meta" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null || true)
            [[ "$ISSUE_MILESTONE" == "null" ]] && ISSUE_MILESTONE=""
            [[ "$ISSUE_LABELS" == "null" ]] && ISSUE_LABELS=""
        else
            # Fallback: just get title
            GOAL=$(gh issue view "$ISSUE_NUMBER" --json title -q .title 2>/dev/null) || {
                error "Failed to fetch issue #$ISSUE_NUMBER"
                return 1
            }
        fi

        GITHUB_ISSUE="#$ISSUE_NUMBER"
        info "Issue #$ISSUE_NUMBER: ${BOLD}$GOAL${RESET}"

        if [[ -n "$ISSUE_LABELS" ]]; then
            info "Labels: ${DIM}$ISSUE_LABELS${RESET}"
        fi
        if [[ -n "$ISSUE_MILESTONE" ]]; then
            info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
        fi

        # Self-assign
        gh_assign_self "$ISSUE_NUMBER"

        # Add in-progress label
        gh_add_labels "$ISSUE_NUMBER" "pipeline/in-progress"
    fi

    # 2. Detect task type
    TASK_TYPE=$(detect_task_type "$GOAL")
    local suggested_template
    suggested_template=$(template_for_type "$TASK_TYPE")
    info "Detected: ${BOLD}$TASK_TYPE${RESET} → team template: ${CYAN}$suggested_template${RESET}"

    # 3. Auto-detect test command if not provided
    if [[ -z "$TEST_CMD" ]]; then
        TEST_CMD=$(detect_test_cmd)
        if [[ -n "$TEST_CMD" ]]; then
            info "Auto-detected test: ${DIM}$TEST_CMD${RESET}"
        fi
    fi

    # 4. Create branch with smart prefix
    local prefix
    prefix=$(branch_prefix_for_type "$TASK_TYPE")
    local slug
    slug=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    slug="${slug%-}"
    [[ -n "$ISSUE_NUMBER" ]] && slug="${slug}-${ISSUE_NUMBER}"
    GIT_BRANCH="${prefix}/${slug}"

    git checkout -b "$GIT_BRANCH" 2>/dev/null || {
        info "Branch $GIT_BRANCH exists, checking out"
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    }
    success "Branch: ${BOLD}$GIT_BRANCH${RESET}"

    # 5. Post initial progress comment on GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_post_progress "$ISSUE_NUMBER" "$body"
    fi

    # 6. Save artifacts
    save_artifact "intake.json" "$(jq -n \
        --arg goal "$GOAL" --arg type "$TASK_TYPE" \
        --arg template "$suggested_template" --arg branch "$GIT_BRANCH" \
        --arg issue "${GITHUB_ISSUE:-}" --arg lang "$project_lang" \
        --arg test_cmd "${TEST_CMD:-}" --arg labels "${ISSUE_LABELS:-}" \
        --arg milestone "${ISSUE_MILESTONE:-}" --arg body "${ISSUE_BODY:-}" \
        '{goal:$goal, type:$type, template:$template, branch:$branch,
          issue:$issue, language:$lang, test_cmd:$test_cmd,
          labels:$labels, milestone:$milestone, body:$body}')"

    log_stage "intake" "Goal: $GOAL
Type: $TASK_TYPE → template: $suggested_template
Branch: $GIT_BRANCH
Language: $project_lang
Test cmd: ${TEST_CMD:-none detected}"
}


