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
