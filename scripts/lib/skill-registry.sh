# skill-registry.sh — Maps (issue_type, stage) → skill prompt fragment files
# Source from pipeline-stages.sh. Skills are prompt fragments in scripts/skills/*.md
[[ -n "${_SKILL_REGISTRY_LOADED:-}" ]] && return 0
_SKILL_REGISTRY_LOADED=1

SKILLS_DIR="${SKILLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)}"

# skill_get_prompts — Returns newline-separated list of skill file paths for a given (issue_type, stage).
#   $1: issue_type (frontend|backend|api|database|infrastructure|documentation|security|performance|refactor|testing)
#   $2: stage (plan|design|build|review|compound_quality|pr|deploy|validate|monitor)
# Prints absolute paths to skill .md files, one per line. Skips missing files silently.
skill_get_prompts() {
    local issue_type="${1:-backend}" stage="${2:-plan}"
    local skills=()

    case "${stage}" in
        plan)
            case "${issue_type}" in
                frontend)      skills=(brainstorming frontend-design product-thinking) ;;
                api)           skills=(brainstorming api-design) ;;
                database)      skills=(brainstorming data-pipeline) ;;
                security)      skills=(brainstorming security-audit) ;;
                performance)   skills=(brainstorming performance) ;;
                testing)       skills=(testing-strategy) ;;
                documentation) skills=(documentation) ;;
                backend)       skills=(brainstorming) ;;
                refactor)      skills=(brainstorming) ;;
                infrastructure) skills=(brainstorming) ;;
                *)             skills=(brainstorming) ;;
            esac
            ;;
        build)
            case "${issue_type}" in
                frontend)      skills=(frontend-design) ;;
                api)           skills=(api-design) ;;
                database)      skills=(data-pipeline) ;;
                security)      skills=(security-audit) ;;
                performance)   skills=(performance) ;;
                testing)       skills=(testing-strategy) ;;
                documentation) skills=(documentation) ;;
                *)             skills=() ;;
            esac
            ;;
        review)
            case "${issue_type}" in
                frontend)      skills=(two-stage-review) ;;
                api)           skills=(two-stage-review security-audit) ;;
                database)      skills=(two-stage-review) ;;
                security)      skills=(two-stage-review security-audit) ;;
                performance)   skills=(two-stage-review) ;;
                testing)       skills=(two-stage-review) ;;
                documentation) skills=() ;;
                backend)       skills=(two-stage-review) ;;
                refactor)      skills=(two-stage-review) ;;
                infrastructure) skills=(two-stage-review) ;;
                *)             skills=(two-stage-review) ;;
            esac
            ;;
        design)
            case "${issue_type}" in
                frontend)       skills=(architecture-design frontend-design) ;;
                api)            skills=(architecture-design api-design) ;;
                database)       skills=(architecture-design data-pipeline) ;;
                security)       skills=(architecture-design security-audit) ;;
                performance)    skills=(architecture-design performance) ;;
                documentation)  skills=() ;;
                *)              skills=(architecture-design) ;;
            esac
            ;;
        compound_quality)
            case "${issue_type}" in
                frontend)       skills=(adversarial-quality testing-strategy) ;;
                api)            skills=(adversarial-quality security-audit) ;;
                security)       skills=(adversarial-quality security-audit) ;;
                performance)    skills=(adversarial-quality performance) ;;
                documentation)  skills=() ;;
                *)              skills=(adversarial-quality) ;;
            esac
            ;;
        pr)
            case "${issue_type}" in
                documentation)  skills=(pr-quality) ;;
                *)              skills=(pr-quality) ;;
            esac
            ;;
        deploy)
            case "${issue_type}" in
                frontend)       skills=(deploy-safety) ;;
                api)            skills=(deploy-safety security-audit) ;;
                database)       skills=(deploy-safety data-pipeline) ;;
                security)       skills=(deploy-safety security-audit) ;;
                infrastructure) skills=(deploy-safety) ;;
                documentation)  skills=() ;;
                *)              skills=(deploy-safety) ;;
            esac
            ;;
        validate)
            case "${issue_type}" in
                frontend)       skills=(validation-thoroughness) ;;
                api)            skills=(validation-thoroughness security-audit) ;;
                security)       skills=(validation-thoroughness security-audit) ;;
                documentation)  skills=() ;;
                *)              skills=(validation-thoroughness) ;;
            esac
            ;;
        monitor)
            case "${issue_type}" in
                frontend)       skills=(observability) ;;
                api)            skills=(observability) ;;
                database)       skills=(observability) ;;
                security)       skills=(observability) ;;
                performance)    skills=(observability performance) ;;
                infrastructure) skills=(observability) ;;
                documentation)  skills=() ;;
                *)              skills=(observability) ;;
            esac
            ;;
        *)
            skills=()
            ;;
    esac

    [[ ${#skills[@]} -eq 0 ]] && return 0
    local skill
    for skill in "${skills[@]}"; do
        local path="${SKILLS_DIR}/${skill}.md"
        if [[ -f "$path" ]]; then
            echo "$path"
        fi
    done
}

# skill_load_prompts — Concatenates all skill prompt fragments for a given (issue_type, stage).
#   $1: issue_type
#   $2: stage
# Returns the combined prompt text. Returns empty string if no skills match.
skill_load_prompts() {
    local issue_type="${1:-backend}" stage="${2:-plan}"
    local combined=""
    local path

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ -f "$path" ]]; then
            local content
            content=$(cat "$path" 2>/dev/null || true)
            if [[ -n "$content" ]]; then
                combined="${combined}
${content}
"
            fi
        fi
    done < <(skill_get_prompts "$issue_type" "$stage")

    echo "$combined"
}

# skill_has_two_stage_review — Check if the issue type uses two-stage review.
#   $1: issue_type
# Returns 0 (true) if two-stage review is active, 1 (false) otherwise.
skill_has_two_stage_review() {
    local issue_type="${1:-backend}"
    local paths
    paths=$(skill_get_prompts "$issue_type" "review")
    echo "$paths" | grep -q "two-stage-review" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# ADAPTIVE SKILL SELECTION ENHANCEMENTS (Level 2)
# ─────────────────────────────────────────────────────────────────────────────

# skill_detect_from_body — Analyze issue body text to detect additional relevant skills.
#   $1: issue_body text
#   $2: stage (default "plan")
# Returns newline-separated additional skill file paths beyond label-based skills.
# Gracefully returns empty if no body provided.
skill_detect_from_body() {
    local body="${1:-}" stage="${2:-plan}"
    local extra_skills=()

    [[ -z "$body" ]] && return 0

    # Convert to lowercase for case-insensitive matching
    local body_lower=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')

    # Keyword patterns → skill names (not paths)
    # These will be resolved to SKILLS_DIR/${skill}.md paths
    local skill_candidates=()

    # Accessibility/UX patterns
    if echo "$body_lower" | grep -qE '(accessibility|a11y|wcag|aria|keyboard|screen.?reader|color.?blind|dyslexia|contrast)'; then
        skill_candidates+=(frontend-design)
    fi

    # Migration/Schema patterns
    if echo "$body_lower" | grep -qE '(migration|schema|database.?(refactor|redesign)|column|index|constraint)'; then
        skill_candidates+=(data-pipeline)
    fi

    # Security/Auth patterns
    if echo "$body_lower" | grep -qE '(security|auth|owasp|xss|injection|csrf|vulnerability|encryption|ssl|tls)'; then
        skill_candidates+=(security-audit)
    fi

    # Performance/Latency patterns
    if echo "$body_lower" | grep -qE '(performance|latency|slow|timeout|p95|p99|benchmark|memory.?leak|cache)'; then
        skill_candidates+=(performance)
    fi

    # API/REST/GraphQL patterns
    if echo "$body_lower" | grep -qE '(api|endpoint|rest|graphql|http|json|query|mutation)'; then
        skill_candidates+=(api-design)
    fi

    # Testing patterns
    if echo "$body_lower" | grep -qE '(test|coverage|unit|integration|e2e|mock|stub|fixture)'; then
        skill_candidates+=(testing-strategy)
    fi

    # Architecture/Design patterns
    if echo "$body_lower" | grep -qE '(architecture|component|module|layer|boundary|dependency|coupling|cohesion)'; then
        skill_candidates+=(architecture-design)
    fi

    # Debugging patterns (useful for troubleshooting in most stages)
    if echo "$body_lower" | grep -qE '(debug|trace|log|monitor|observe|metric|alert)'; then
        [[ "$stage" == "build" || "$stage" == "test" ]] && skill_candidates+=(systematic-debugging)
    fi

    # Convert candidates to file paths
    local skill
    for skill in "${skill_candidates[@]}"; do
        local path="${SKILLS_DIR}/${skill}.md"
        if [[ -f "$path" ]]; then
            echo "$path"
        fi
    done
}

# skill_weight_by_complexity — Adjust skill set based on issue complexity.
#   $1: complexity (1-10, from INTELLIGENCE_COMPLEXITY)
#   $2: skills (newline-separated file paths)
# Returns filtered skill paths:
#   - Complexity 1-3: only essential skills (first skill in list)
#   - Complexity 4-7: all standard skills (no change)
#   - Complexity 8-10: add cross-cutting concerns (security-audit, performance if not present)
skill_weight_by_complexity() {
    local complexity="${1:-5}" skills="${2:-}"

    [[ -z "$skills" ]] && return 0

    # Parse complexity level
    complexity=$(printf '%d' "$complexity" 2>/dev/null || echo "5")
    [[ "$complexity" -lt 1 ]] && complexity=1
    [[ "$complexity" -gt 10 ]] && complexity=10

    # Simple issues: only first (essential) skill
    if [[ "$complexity" -le 3 ]]; then
        echo "$skills" | head -1
        return 0
    fi

    # Standard complexity: return all skills as-is
    if [[ "$complexity" -le 7 ]]; then
        echo "$skills"
        return 0
    fi

    # Complex issues: add cross-cutting concerns
    # Echo all provided skills first
    echo "$skills"

    # Add security-audit if not already present
    if ! echo "$skills" | grep -q "security-audit.md" 2>/dev/null; then
        local sec_path="${SKILLS_DIR}/security-audit.md"
        [[ -f "$sec_path" ]] && echo "$sec_path"
    fi

    # Add performance if not already present
    if ! echo "$skills" | grep -q "performance.md" 2>/dev/null; then
        local perf_path="${SKILLS_DIR}/performance.md"
        [[ -f "$perf_path" ]] && echo "$perf_path"
    fi
}

# skill_select_adaptive — Intelligent skill selection combining all signals.
#   $1: issue_type
#   $2: stage
#   $3: issue_body (optional)
#   $4: complexity (optional, 1-10, default 5)
# Returns newline-separated skill file paths, deduplicated and ordered.
# Combines: static registry + body analysis + complexity weighting.
skill_select_adaptive() {
    local issue_type="${1:-backend}" stage="${2:-plan}"
    local body="${3:-}" complexity="${4:-5}"

    # 1. Get base skills from static registry
    local base_skills
    base_skills=$(skill_get_prompts "$issue_type" "$stage")

    # 2. Detect additional skills from issue body
    local body_skills=""
    if [[ -n "$body" ]]; then
        body_skills=$(skill_detect_from_body "$body" "$stage")
    fi

    # 3. Merge and deduplicate
    local all_skills
    all_skills=$(printf '%s\n%s' "$base_skills" "$body_skills" | sort -u | grep -v '^$')

    # 4. Weight by complexity
    all_skills=$(skill_weight_by_complexity "$complexity" "$all_skills")

    # 5. Final deduplication (complexity weighting may have added duplicates)
    all_skills=$(echo "$all_skills" | sort -u | grep -v '^$')

    echo "$all_skills"
}

# ─────────────────────────────────────────────────────────────────────────────
# AI-POWERED SKILL SELECTION (Tier 1)
# ─────────────────────────────────────────────────────────────────────────────

GENERATED_SKILLS_DIR="${SKILLS_DIR}/generated"
REFINEMENTS_DIR="${GENERATED_SKILLS_DIR}/_refinements"

# skill_build_catalog — Build a compact skill index for the LLM router prompt.
#   $1: issue_type (optional — for memory context)
#   $2: stage (optional — for memory context)
# Returns: multi-line text, one skill per line with description and optional memory stats.
skill_build_catalog() {
    local issue_type="${1:-}" stage="${2:-}"
    local catalog=""

    # Scan curated skills
    local skill_file
    for skill_file in "$SKILLS_DIR"/*.md; do
        [[ ! -f "$skill_file" ]] && continue
        local name
        name=$(basename "$skill_file" .md)
        # Extract first meaningful line as description (skip headers, blank lines)
        local desc
        desc=$(grep -v '^#\|^$\|^---\|^\*\*IMPORTANT' "$skill_file" 2>/dev/null | head -1 | cut -c1-120 || echo "")
        [[ -z "$desc" ]] && desc=$(head -1 "$skill_file" | sed 's/^#* *//' | cut -c1-120)

        local memory_hint=""
        if [[ -n "$issue_type" && -n "$stage" ]] && type skill_memory_get_success_rate >/dev/null 2>&1; then
            local rate
            rate=$(skill_memory_get_success_rate "$issue_type" "$stage" "$name" 2>/dev/null || true)
            [[ -n "$rate" ]] && memory_hint=" [${rate}% success for ${issue_type}/${stage}]"
        fi

        catalog="${catalog}
- ${name}: ${desc}${memory_hint}"
    done

    # Scan generated skills
    if [[ -d "$GENERATED_SKILLS_DIR" ]]; then
        for skill_file in "$GENERATED_SKILLS_DIR"/*.md; do
            [[ ! -f "$skill_file" ]] && continue
            local name
            name=$(basename "$skill_file" .md)
            local desc
            desc=$(grep -v '^#\|^$\|^---\|^\*\*IMPORTANT' "$skill_file" 2>/dev/null | head -1 | cut -c1-120 || echo "")
            [[ -z "$desc" ]] && desc=$(head -1 "$skill_file" | sed 's/^#* *//' | cut -c1-120)

            local memory_hint=""
            if [[ -n "$issue_type" && -n "$stage" ]] && type skill_memory_get_success_rate >/dev/null 2>&1; then
                local rate
                rate=$(skill_memory_get_success_rate "$issue_type" "$stage" "$name" 2>/dev/null || true)
                [[ -n "$rate" ]] && memory_hint=" [${rate}% success for ${issue_type}/${stage}]"
            fi

            catalog="${catalog}
- ${name} [generated]: ${desc}${memory_hint}"
        done
    fi

    echo "$catalog"
}

# skill_analyze_issue — LLM-powered skill selection and gap detection.
#   $1: issue_title
#   $2: issue_body
#   $3: issue_labels
#   $4: artifacts_dir (where to write skill-plan.json)
#   $5: intelligence_json (optional — reuse from intelligence_analyze_issue)
# Returns: 0 on success (skill-plan.json written), 1 on failure (caller should fallback)
# Requires: _intelligence_call_claude() from sw-intelligence.sh
skill_analyze_issue() {
    local title="${1:-}" body="${2:-}" labels="${3:-}"
    local artifacts_dir="${4:-${ARTIFACTS_DIR:-.claude/pipeline-artifacts}}"
    local intelligence_json="${5:-}"

    # Verify we have the LLM call function
    if ! type _intelligence_call_claude >/dev/null 2>&1; then
        return 1
    fi

    # Build the skill catalog
    local catalog
    catalog=$(skill_build_catalog "" "" 2>/dev/null || true)
    [[ -z "$catalog" ]] && return 1

    # Build memory recommendations
    local memory_context=""
    if type skill_memory_get_recommendations >/dev/null 2>&1; then
        local recs
        recs=$(skill_memory_get_recommendations "backend" "plan" 2>/dev/null || true)
        [[ -n "$recs" ]] && memory_context="Historical skill performance: $recs"
    fi

    # Build the prompt
    local prompt
    prompt="You are a pipeline skill router. Analyze this GitHub issue and select the best skills for each pipeline stage.

## Issue
Title: ${title}
Labels: ${labels}
Body:
${body}

## Available Skills
${catalog}

${memory_context:+## Historical Context
$memory_context
}
${intelligence_json:+## Intelligence Analysis
$intelligence_json
}
## Pipeline Stages
Skills can be assigned to: plan, design, build, review, compound_quality, pr, deploy, validate, monitor

## Instructions
1. Classify the issue type (frontend|backend|api|database|infrastructure|documentation|security|performance|refactor|testing)
2. Select 1-4 skills per stage from the catalog. Only select skills relevant to that stage.
3. For each selected skill, write a one-sentence rationale explaining WHY this skill matters for THIS specific issue (not generic advice).
4. If the issue needs expertise not covered by any existing skill, generate a new skill with focused, actionable content (200-400 words).
5. Identify specific review focus areas and risk areas for this issue.

## Response Format (JSON only, no markdown)
{
  \"issue_type\": \"frontend\",
  \"confidence\": 0.92,
  \"secondary_domains\": [\"accessibility\", \"real-time\"],
  \"complexity_assessment\": {
    \"score\": 6,
    \"reasoning\": \"Brief explanation\"
  },
  \"skill_plan\": {
    \"plan\": [\"skill-name-1\", \"skill-name-2\"],
    \"design\": [\"skill-name\"],
    \"build\": [\"skill-name\"],
    \"review\": [\"skill-name\"],
    \"compound_quality\": [\"skill-name\"],
    \"pr\": [\"skill-name\"],
    \"deploy\": [\"skill-name\"],
    \"validate\": [],
    \"monitor\": []
  },
  \"skill_rationale\": {
    \"skill-name-1\": \"Why this skill matters for this specific issue\",
    \"skill-name-2\": \"Why this skill matters\"
  },
  \"generated_skills\": [
    {
      \"name\": \"new-skill-name\",
      \"reason\": \"Why no existing skill covers this\",
      \"content\": \"## Skill Title\\n\\nActionable guidance...\"
    }
  ],
  \"review_focus\": [\"specific area 1\", \"specific area 2\"],
  \"risk_areas\": [\"specific risk 1\"]
}"

    # Call the LLM
    local cache_key="skill_analysis_$(echo "${title}${body}" | md5sum 2>/dev/null | cut -c1-16 || echo "${RANDOM}")"
    local result
    if ! result=$(_intelligence_call_claude "$prompt" "$cache_key" 3600 "haiku"); then
        return 1
    fi

    # Validate the response has required fields
    local valid
    valid=$(echo "$result" | jq 'has("issue_type") and has("skill_plan") and has("skill_rationale")' 2>/dev/null || echo "false")
    if [[ "$valid" != "true" ]]; then
        warn "Skill analysis returned invalid JSON — falling back to static selection"
        return 1
    fi

    # Write skill-plan.json
    mkdir -p "$artifacts_dir"
    echo "$result" | jq '.' > "$artifacts_dir/skill-plan.json"

    # Save any generated skills to disk
    local gen_count
    gen_count=$(echo "$result" | jq '.generated_skills | length' 2>/dev/null || echo "0")
    if [[ "$gen_count" -gt 0 ]]; then
        mkdir -p "$GENERATED_SKILLS_DIR"
        local i
        for i in $(seq 0 $((gen_count - 1))); do
            local gen_name gen_content
            gen_name=$(echo "$result" | jq -r ".generated_skills[$i].name" 2>/dev/null)
            gen_content=$(echo "$result" | jq -r ".generated_skills[$i].content" 2>/dev/null)
            if [[ -n "$gen_name" && "$gen_name" != "null" && -n "$gen_content" && "$gen_content" != "null" ]]; then
                # Only write if doesn't already exist (don't overwrite improved versions)
                if [[ ! -f "$GENERATED_SKILLS_DIR/${gen_name}.md" ]]; then
                    printf '%b\n' "$gen_content" > "$GENERATED_SKILLS_DIR/${gen_name}.md"
                    info "Generated new skill: ${gen_name}"
                fi
            fi
        done
    fi

    # Update INTELLIGENCE_ISSUE_TYPE from analysis
    local analyzed_type
    analyzed_type=$(echo "$result" | jq -r '.issue_type // empty' 2>/dev/null)
    if [[ -n "$analyzed_type" ]]; then
        export INTELLIGENCE_ISSUE_TYPE="$analyzed_type"
    fi

    # Update INTELLIGENCE_COMPLEXITY from analysis
    local analyzed_complexity
    analyzed_complexity=$(echo "$result" | jq -r '.complexity_assessment.score // empty' 2>/dev/null)
    if [[ -n "$analyzed_complexity" ]]; then
        export INTELLIGENCE_COMPLEXITY="$analyzed_complexity"
    fi

    return 0
}
