#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet patterns — Cross-Repository Pattern Sharing           ║
# ║  Capture learnings · Query patterns · Share across fleet repos          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Sensitive Data Filter ──────────────────────────────────────────────────
# shellcheck source=lib/sensitive-data-filter.sh
[[ -f "$SCRIPT_DIR/lib/sensitive-data-filter.sh" ]] && source "$SCRIPT_DIR/lib/sensitive-data-filter.sh"
# Fallback if filter not loaded
if [[ "$(type -t _filter_sensitive_data 2>/dev/null)" != "function" ]]; then
  _filter_sensitive_data() { echo "$1"; }
  _has_sensitive_data() { return 0; }
fi

# ─── Constants ──────────────────────────────────────────────────────────────
FLEET_PATTERNS_FILE="${FLEET_PATTERNS_FILE:-${HOME}/.shipwright/fleet-patterns.jsonl}"
FLEET_PATTERNS_LOCK="${FLEET_PATTERNS_FILE}.lock"
PATTERN_VERSION="1.0"
MAX_LOCK_RETRIES=3
LOCK_RETRY_DELAY=0.1

# ─── Content hash for deduplication ─────────────────────────────────────────
_pattern_content_hash() {
    echo -n "$1" | shasum -a 256 | cut -d' ' -f1
}

# ─── Acquire file lock with retries ─────────────────────────────────────────
_acquire_lock() {
    local lock_file="$1"
    local lock_fd="${2:-9}"
    local retries=0

    mkdir -p "$(dirname "$lock_file")"

    while [[ "$retries" -lt "$MAX_LOCK_RETRIES" ]]; do
        if ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
            return 0
        fi
        retries=$((retries + 1))
        sleep "$LOCK_RETRY_DELAY"
    done
    return 1
}

_release_lock() {
    local lock_file="$1"
    rm -f "$lock_file" 2>/dev/null || true
}

# ─── Generate UUID ──────────────────────────────────────────────────────────
_generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: generate pseudo-UUID from /dev/urandom
        od -x /dev/urandom 2>/dev/null | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' || \
        echo "$(date +%s)-$$-$(( RANDOM ))-$(( RANDOM ))"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  CAPTURE — Record a pattern after successful pipeline
# ═══════════════════════════════════════════════════════════════════════════

# fleet_patterns_capture repo_path artifacts_dir pipeline_state_file
# Exit: 0=captured, 1=no pattern, 2=error
fleet_patterns_capture() {
    local repo_path="${1:-}"
    local artifacts_dir="${2:-}"
    local state_file="${3:-}"

    if [[ -z "$repo_path" ]]; then
        warn "fleet_patterns_capture: missing repo_path"
        return 1
    fi

    # Check if sharing is enabled
    local config_file="${HOME}/.shipwright/fleet-config.json"
    local share_enabled="false"
    if [[ -f "$config_file" ]]; then
        share_enabled=$(jq -r '.pattern_share_enabled // false' "$config_file" 2>/dev/null || echo "false")
    fi
    # Also check daemon config
    local daemon_config=".claude/daemon-config.json"
    if [[ "$share_enabled" != "true" ]] && [[ -f "$daemon_config" ]]; then
        share_enabled=$(jq -r '.pattern_share_enabled // false' "$daemon_config" 2>/dev/null || echo "false")
    fi

    if [[ "$share_enabled" != "true" ]]; then
        return 1
    fi

    # Extract pattern data from artifacts
    local title="" description="" problem="" solution="" category="other"
    local pattern_type="pattern" source_stage="build"
    local languages="" frameworks="" test_runners=""

    # Read pipeline state for stage info
    if [[ -n "$state_file" ]] && [[ -f "$state_file" ]]; then
        source_stage=$(grep -oE 'current_stage:\s*\S+' "$state_file" 2>/dev/null | head -1 | sed 's/current_stage:\s*//' || echo "build")
    fi

    # Read error summary for problem/solution
    local error_summary="${artifacts_dir:+${artifacts_dir}/error-summary.json}"
    if [[ -n "$error_summary" ]] && [[ -f "$error_summary" ]]; then
        title=$(jq -r '.summary // empty' "$error_summary" 2>/dev/null | head -c 80 || true)
        problem=$(jq -r '.error // .message // empty' "$error_summary" 2>/dev/null || true)
        solution=$(jq -r '.fix // .resolution // empty' "$error_summary" 2>/dev/null || true)
        pattern_type="fix"
    fi

    # Read plan for additional context
    local plan_file="${artifacts_dir:+${artifacts_dir}/plan.md}"
    if [[ -z "$title" ]] && [[ -n "$plan_file" ]] && [[ -f "$plan_file" ]]; then
        title=$(head -5 "$plan_file" 2>/dev/null | grep -E '^#' | head -1 | sed 's/^#\+\s*//' | head -c 80 || true)
        description=$(head -20 "$plan_file" 2>/dev/null | grep -v '^#' | grep -v '^$' | head -3 | tr '\n' ' ' || true)
    fi

    # Read repo patterns for language/framework
    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -d' ' -f1 | head -c 12)
    local patterns_file="${HOME}/.shipwright/memory/${repo_hash}/patterns.json"
    if [[ -f "$patterns_file" ]]; then
        languages=$(jq -r '.language // empty' "$patterns_file" 2>/dev/null || true)
        frameworks=$(jq -r '.framework // empty' "$patterns_file" 2>/dev/null || true)
        test_runners=$(jq -r '.test_runner // empty' "$patterns_file" 2>/dev/null || true)
    fi
    # Fallback: check package.json in repo
    if [[ -z "$languages" ]] && [[ -f "${repo_path}/package.json" ]]; then
        languages="javascript"
    fi

    # Must have at least a title
    if [[ -z "$title" ]]; then
        return 1
    fi

    # Apply sensitive data filter to all content fields
    title=$(_filter_sensitive_data "$title")
    description=$(_filter_sensitive_data "${description:-}")
    problem=$(_filter_sensitive_data "${problem:-}")
    solution=$(_filter_sensitive_data "${solution:-}")

    # Check for residual sensitive data
    local _sensitive_check=0
    _has_sensitive_data "$title$description$problem$solution" || _sensitive_check=$?
    if [[ "$_sensitive_check" -ne 0 ]]; then
        warn "fleet_patterns_capture: sensitive data detected after redaction — dropping pattern"
        emit_event "fleet.pattern_capture_failed" "repo=$repo_path" "reason=sensitive_data"
        return 2
    fi

    # Dedup check
    local content_hash
    content_hash=$(_pattern_content_hash "${title}${problem}${solution}")
    if [[ -f "$FLEET_PATTERNS_FILE" ]]; then
        if grep -qF "\"content_hash\":\"${content_hash}\"" "$FLEET_PATTERNS_FILE" 2>/dev/null; then
            return 0  # Already captured
        fi
    fi

    # Detect category from content
    local all_text
    all_text=$(echo "$title $description $problem $solution" | tr '[:upper:]' '[:lower:]')
    case "$all_text" in
        *auth*|*login*|*session*|*token*|*credential*) category="auth" ;;
        *api*|*endpoint*|*route*|*request*)            category="api" ;;
        *database*|*query*|*migration*|*sql*)          category="db" ;;
        *ui*|*component*|*render*|*style*|*css*)        category="ui" ;;
        *test*|*spec*|*assert*|*mock*)                  category="test" ;;
        *deploy*|*ci*|*cd*|*pipeline*|*release*)        category="deploy" ;;
        *error*|*exception*|*crash*|*bug*)              category="error" ;;
        *perf*|*speed*|*latency*|*cache*|*optim*)       category="perf" ;;
    esac

    # Build tags from keywords
    local tags="[]"
    tags=$(echo "$all_text" | tr -cs '[:alnum:]' '\n' | sort -u | \
        grep -vxE '^.{1,3}$|^(the|and|for|not|with|this|that|from|have|been)$' | \
        head -10 | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")

    # Build pattern JSON
    local pattern_id
    pattern_id=$(_generate_uuid)
    local captured_at
    captured_at=$(now_iso)

    local repo_name
    repo_name=$(basename "$repo_path")

    local pattern_json
    pattern_json=$(jq -n \
        --arg id "$pattern_id" \
        --arg pv "$PATTERN_VERSION" \
        --arg ca "$captured_at" \
        --arg repo "$repo_name" \
        --arg stage "$source_stage" \
        --arg ptype "$pattern_type" \
        --arg cat "$category" \
        --argjson tags "$tags" \
        --arg lang "${languages:-}" \
        --arg fw "${frameworks:-}" \
        --arg tr "${test_runners:-}" \
        --arg title "$title" \
        --arg desc "${description:-}" \
        --arg prob "${problem:-}" \
        --arg sol "${solution:-}" \
        --arg hash "$content_hash" \
        '{
            id: $id,
            pattern_version: $pv,
            captured_at: $ca,
            captured_by_repo: $repo,
            source_stage: $stage,
            pattern_type: $ptype,
            category: $cat,
            tags: $tags,
            languages: (if $lang == "" then [] else [$lang] end),
            frameworks: (if $fw == "" then [] else [$fw] end),
            test_runners: (if $tr == "" then [] else [$tr] end),
            title: $title,
            description: $desc,
            problem_statement: $prob,
            solution_code: $sol,
            content_hash: $hash,
            success_count: 0,
            failure_count: 0,
            effectiveness_rate: 0,
            is_shared: true,
            sensitive_fields_redacted: []
        }' 2>/dev/null)

    if [[ -z "$pattern_json" ]]; then
        warn "fleet_patterns_capture: failed to build pattern JSON"
        emit_event "fleet.pattern_capture_failed" "repo=$repo_path" "reason=json_build"
        return 2
    fi

    # Write under lock
    mkdir -p "$(dirname "$FLEET_PATTERNS_FILE")"

    if _acquire_lock "$FLEET_PATTERNS_LOCK"; then
        local tmp
        tmp=$(mktemp)
        echo "$pattern_json" | jq -c '.' > "$tmp" 2>/dev/null
        cat "$tmp" >> "$FLEET_PATTERNS_FILE"
        rm -f "$tmp"
        _release_lock "$FLEET_PATTERNS_LOCK"
    else
        warn "fleet_patterns_capture: could not acquire lock after $MAX_LOCK_RETRIES retries"
        emit_event "fleet.pattern_capture_failed" "repo=$repo_path" "reason=lock_timeout"
        return 2
    fi

    emit_event "fleet.pattern_captured" "id=$pattern_id" "repo=$repo_name" "category=$category"
    success "Fleet pattern captured: $title"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  RECORD REUSE — Track effectiveness when a pattern is reused
# ═══════════════════════════════════════════════════════════════════════════

# fleet_patterns_record_reuse pattern_id outcome
# outcome: "success" or "failure"
# Exit: 0=updated, 1=pattern not found, 2=error
fleet_patterns_record_reuse() {
    local pattern_id="${1:-}"
    local outcome="${2:-}"

    if [[ -z "$pattern_id" || -z "$outcome" ]]; then
        warn "fleet_patterns_record_reuse: missing pattern_id or outcome"
        return 2
    fi

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        warn "fleet_patterns_record_reuse: no fleet patterns file"
        return 1
    fi

    # Check pattern exists
    if ! grep -qF "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" 2>/dev/null; then
        return 1
    fi

    if ! _acquire_lock "$FLEET_PATTERNS_LOCK"; then
        warn "fleet_patterns_record_reuse: could not acquire lock"
        return 2
    fi

    local tmp_file
    tmp_file=$(mktemp)
    local updated=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qF "\"id\":\"${pattern_id}\"" 2>/dev/null; then
            local field
            if [[ "$outcome" == "success" ]]; then
                field="success_count"
            else
                field="failure_count"
            fi
            line=$(echo "$line" | jq -c \
                --arg field "$field" \
                '.[$field] = ((.[$field] // 0) + 1) |
                 .effectiveness_rate = (if ((.success_count // 0) + (.failure_count // 0)) > 0
                     then ((.success_count // 0) * 100 / ((.success_count // 0) + (.failure_count // 0)))
                     else 0 end)' 2>/dev/null) || true
            updated=true
        fi
        echo "$line" >> "$tmp_file"
    done < "$FLEET_PATTERNS_FILE"

    if [[ "$updated" == "true" ]]; then
        mv "$tmp_file" "$FLEET_PATTERNS_FILE"
    else
        rm -f "$tmp_file"
    fi

    _release_lock "$FLEET_PATTERNS_LOCK"

    if [[ "$updated" == "true" ]]; then
        emit_event "fleet.pattern_reuse" "id=$pattern_id" "outcome=$outcome"
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
#  QUERY — Find relevant patterns for a repo/context
# ═══════════════════════════════════════════════════════════════════════════

# fleet_patterns_query query repo_language framework max_results
# Returns: JSON array on stdout, [] if no matches
fleet_patterns_query() {
    local query="${1:-}"
    local repo_language="${2:-}"
    local framework="${3:-}"
    local max_results="${4:-5}"

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        echo "[]"
        return 0
    fi

    # Expand query keywords
    local keywords
    keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | \
        grep -vxE '^.{1,2}$|^(the|and|for|not|with|this|that|from)$' || true)

    # Source domain keyword expansion if available
    if [[ "$(type -t _expand_domain_keywords 2>/dev/null)" == "function" ]]; then
        keywords=$(_expand_domain_keywords "$keywords" 2>/dev/null || echo "$keywords")
    fi

    local results_file
    results_file=$(mktemp)

    # Read patterns line by line, score each
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse — skip malformed lines
        local parsed
        parsed=$(echo "$line" | jq -c '.' 2>/dev/null) || continue
        [[ -z "$parsed" ]] && continue

        # Language filter
        if [[ -n "$repo_language" ]]; then
            local lang_match
            lang_match=$(echo "$parsed" | jq -r --arg lang "$repo_language" \
                'if (.languages | length) == 0 then "yes"
                 elif (.languages | map(ascii_downcase) | index($lang | ascii_downcase)) then "yes"
                 else "no" end' 2>/dev/null || echo "no")
            [[ "$lang_match" == "no" ]] && continue
        fi

        # Framework filter (if specified)
        if [[ -n "$framework" ]]; then
            local fw_match
            fw_match=$(echo "$parsed" | jq -r --arg fw "$framework" \
                'if (.frameworks | length) == 0 then "yes"
                 elif (.frameworks | map(ascii_downcase) | index($fw | ascii_downcase)) then "yes"
                 else "no" end' 2>/dev/null || echo "yes")
            [[ "$fw_match" == "no" ]] && continue
        fi

        # Score: effectiveness (0.5) + keyword relevance (0.3) + repo type match (0.2)
        local effectiveness
        effectiveness=$(echo "$parsed" | jq -r '.effectiveness_rate // 0' 2>/dev/null || echo "0")

        local search_text
        search_text=$(echo "$parsed" | jq -r '(.title // "") + " " + (.description // "") + " " + (.problem_statement // "") + " " + (.tags | join(" "))' 2>/dev/null | tr '[:upper:]' '[:lower:]')

        local keyword_matches=0
        local keyword_total=0
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            keyword_total=$((keyword_total + 1))
            if echo "$search_text" | grep -qiF "$kw" 2>/dev/null; then
                keyword_matches=$((keyword_matches + 1))
            fi
        done <<< "$keywords"

        # Skip if no keyword match and query was provided
        if [[ -n "$query" ]] && [[ "$keyword_total" -gt 0 ]] && [[ "$keyword_matches" -eq 0 ]]; then
            continue
        fi

        # Calculate score (integer math: multiply by 100 for precision)
        local eff_score=0
        if [[ "$effectiveness" =~ ^[0-9]+$ ]] && [[ "$effectiveness" -gt 0 ]]; then
            eff_score=$((effectiveness / 2))  # 0-50
        else
            eff_score=25  # Default for unrated patterns
        fi

        local kw_score=0
        if [[ "$keyword_total" -gt 0 ]]; then
            kw_score=$((keyword_matches * 30 / keyword_total))  # 0-30
        fi

        local type_score=0
        if [[ -n "$repo_language" ]]; then
            local has_lang
            has_lang=$(echo "$parsed" | jq -r --arg lang "$repo_language" \
                'if (.languages | length) == 0 then "yes"
                 elif (.languages | map(ascii_downcase) | index($lang | ascii_downcase)) then "yes"
                 else "no" end' 2>/dev/null || echo "no")
            [[ "$has_lang" == "yes" ]] && type_score=20
        else
            type_score=10  # Partial credit when language unknown
        fi

        local total_score=$((eff_score + kw_score + type_score))

        echo "${total_score}|${parsed}" >> "$results_file"
    done < "$FLEET_PATTERNS_FILE"

    # Sort by score, return top N
    local output
    if [[ -s "$results_file" ]]; then
        output=$(sort -t'|' -k1 -rn "$results_file" | head -"$max_results" | cut -d'|' -f2- | jq -s '.' 2>/dev/null || echo "[]")
    else
        output="[]"
    fi
    rm -f "$results_file" 2>/dev/null || true

    emit_event "fleet.pattern_query" "query=$query" "results=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)"
    echo "$output"
}

# ═══════════════════════════════════════════════════════════════════════════
#  CLI COMMANDS
# ═══════════════════════════════════════════════════════════════════════════

# ─── List patterns ──────────────────────────────────────────────────────────
fleet_patterns_list() {
    local limit=20
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)  limit="${2:-20}"; shift 2 ;;
            --limit=*) limit="${1#*=}"; shift ;;
            --json)   json_output=true; shift ;;
            *)        shift ;;
        esac
    done

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo "[]"
        else
            info "No fleet patterns captured yet"
        fi
        return 0
    fi

    if [[ "$json_output" == "true" ]]; then
        tail -"$limit" "$FLEET_PATTERNS_FILE" | jq -s '.' 2>/dev/null || echo "[]"
        return 0
    fi

    echo ""
    echo -e "  ${CYAN:-}${BOLD:-}Fleet Patterns${RESET:-}"
    echo -e "  ${DIM:-}══════════════════════════════════════════${RESET:-}"
    echo ""

    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local title repo category eff captured_at
        title=$(echo "$line" | jq -r '.title // "untitled"' 2>/dev/null)
        repo=$(echo "$line" | jq -r '.captured_by_repo // "unknown"' 2>/dev/null)
        category=$(echo "$line" | jq -r '.category // "other"' 2>/dev/null)
        eff=$(echo "$line" | jq -r '.effectiveness_rate // 0' 2>/dev/null)
        captured_at=$(echo "$line" | jq -r '.captured_at // ""' 2>/dev/null | cut -d'T' -f1)

        printf "  %-50s %-12s %-8s %3s%%  %s\n" \
            "$(echo "$title" | head -c 50)" "$repo" "$category" "$eff" "$captured_at"
        count=$((count + 1))
    done < <(tail -"$limit" "$FLEET_PATTERNS_FILE")

    echo ""
    info "Showing $count patterns (total: $(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' '))"
}

# ─── Search patterns ───────────────────────────────────────────────────────
fleet_patterns_search() {
    local query=""
    local limit=10
    local category=""
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)    limit="${2:-10}"; shift 2 ;;
            --limit=*)  limit="${1#*=}"; shift ;;
            --category) category="${2:-}"; shift 2 ;;
            --category=*) category="${1#*=}"; shift ;;
            --json)     json_output=true; shift ;;
            -*)         shift ;;
            *)          query="${query:+$query }$1"; shift ;;
        esac
    done

    if [[ -z "$query" ]]; then
        error "Usage: shipwright fleet patterns search <query> [--limit N] [--category CAT] [--json]"
        return 1
    fi

    local results
    results=$(fleet_patterns_query "$query" "" "" "$limit")

    # Filter by category if specified
    if [[ -n "$category" ]]; then
        results=$(echo "$results" | jq --arg cat "$category" '[.[] | select(.category == $cat)]' 2>/dev/null || echo "$results")
    fi

    if [[ "$json_output" == "true" ]]; then
        echo "$results"
        return 0
    fi

    local count
    count=$(echo "$results" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then
        info "No patterns found matching: $query"
        return 0
    fi

    echo ""
    echo -e "  ${CYAN:-}${BOLD:-}Search Results for: ${query}${RESET:-}"
    echo -e "  ${DIM:-}══════════════════════════════════════════${RESET:-}"
    echo ""

    echo "$results" | jq -r '.[] | "  \(.title)\n    repo: \(.captured_by_repo)  category: \(.category)  effectiveness: \(.effectiveness_rate)%\n"' 2>/dev/null

    info "Found $count matching patterns"
}

# ─── Show pattern detail ───────────────────────────────────────────────────
fleet_patterns_show() {
    local pattern_id="${1:-}"

    if [[ -z "$pattern_id" ]]; then
        error "Usage: shipwright fleet patterns show <pattern-id>"
        return 1
    fi

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        error "No fleet patterns file found"
        return 1
    fi

    local pattern
    pattern=$(grep "\"id\":\"${pattern_id}\"" "$FLEET_PATTERNS_FILE" 2>/dev/null | head -1)

    if [[ -z "$pattern" ]]; then
        error "Pattern not found: $pattern_id"
        return 1
    fi

    echo "$pattern" | jq '.' 2>/dev/null
}

# ─── Stats ──────────────────────────────────────────────────────────────────
fleet_patterns_stats() {
    local period_days=30
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period)   period_days="${2:-30}"; shift 2 ;;
            --period=*) period_days="${1#*=}"; shift ;;
            --json)     json_output=true; shift ;;
            *)          shift ;;
        esac
    done

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo '{"total":0,"categories":{},"avg_effectiveness":0}'
        else
            info "No fleet patterns captured yet"
        fi
        return 0
    fi

    local stats
    stats=$(jq -s '{
        total: length,
        categories: (group_by(.category) | map({key: .[0].category, value: length}) | from_entries),
        avg_effectiveness: (if length > 0 then (map(.effectiveness_rate) | add / length | . * 10 | round / 10) else 0 end),
        pattern_types: (group_by(.pattern_type) | map({key: .[0].pattern_type, value: length}) | from_entries),
        repos: ([.[].captured_by_repo] | unique | length),
        languages: ([.[].languages[]?] | unique)
    }' "$FLEET_PATTERNS_FILE" 2>/dev/null || echo '{"total":0,"categories":{},"avg_effectiveness":0}')

    if [[ "$json_output" == "true" ]]; then
        echo "$stats"
        return 0
    fi

    echo ""
    echo -e "  ${CYAN:-}${BOLD:-}Fleet Pattern Statistics${RESET:-}"
    echo -e "  ${DIM:-}══════════════════════════════════════════${RESET:-}"
    echo ""

    local total avg repos
    total=$(echo "$stats" | jq -r '.total' 2>/dev/null || echo 0)
    avg=$(echo "$stats" | jq -r '.avg_effectiveness' 2>/dev/null || echo 0)
    repos=$(echo "$stats" | jq -r '.repos' 2>/dev/null || echo 0)

    echo "  Total patterns:       $total"
    echo "  Contributing repos:   $repos"
    echo "  Avg effectiveness:    ${avg}%"
    echo ""
    echo "  Categories:"
    echo "$stats" | jq -r '.categories | to_entries[] | "    \(.key): \(.value)"' 2>/dev/null
    echo ""
    echo "  Pattern types:"
    echo "$stats" | jq -r '.pattern_types | to_entries[] | "    \(.key): \(.value)"' 2>/dev/null
    echo ""
}

# ─── Prune old patterns ────────────────────────────────────────────────────
fleet_patterns_prune() {
    local older_than_days=30
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --older-than)   older_than_days="${2:-30}"; shift 2 ;;
            --older-than=*) older_than_days="${1#*=}"; shift ;;
            --dry-run)      dry_run=true; shift ;;
            *)              shift ;;
        esac
    done

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        info "No fleet patterns file to prune"
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(date +%s) - (older_than_days * 86400) ))
    local cutoff_iso
    cutoff_iso=$(date -u -d "@$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u -r "$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 echo "1970-01-01T00:00:00Z")

    local total_before
    total_before=$(wc -l < "$FLEET_PATTERNS_FILE" | tr -d ' ')

    local kept_file
    kept_file=$(mktemp)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local captured_at
        captured_at=$(echo "$line" | jq -r '.captured_at // ""' 2>/dev/null || echo "")
        if [[ -n "$captured_at" ]] && [[ "$captured_at" > "$cutoff_iso" || "$captured_at" == "$cutoff_iso" ]]; then
            echo "$line" >> "$kept_file"
        fi
    done < "$FLEET_PATTERNS_FILE"

    local total_after=0
    [[ -f "$kept_file" ]] && total_after=$(wc -l < "$kept_file" | tr -d ' ')
    local removed=$((total_before - total_after))

    if [[ "$dry_run" == "true" ]]; then
        info "Would remove $removed patterns older than $older_than_days days ($total_after would remain)"
        rm -f "$kept_file"
        return 0
    fi

    if [[ "$removed" -gt 0 ]]; then
        if _acquire_lock "$FLEET_PATTERNS_LOCK"; then
            mv "$kept_file" "$FLEET_PATTERNS_FILE"
            _release_lock "$FLEET_PATTERNS_LOCK"
            success "Pruned $removed patterns older than $older_than_days days ($total_after remaining)"
            emit_event "fleet.patterns_pruned" "removed=$removed" "remaining=$total_after"
        else
            warn "Could not acquire lock for pruning"
            rm -f "$kept_file"
            return 2
        fi
    else
        info "No patterns older than $older_than_days days to prune"
        rm -f "$kept_file"
    fi
}

# ─── Reuse rate ─────────────────────────────────────────────────────────────
fleet_patterns_reuse_rate() {
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_output=true; shift ;;
            *)      shift ;;
        esac
    done

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo '{"reuse_rate":0,"total":0,"reused":0}'
        else
            info "No fleet patterns captured yet"
        fi
        return 0
    fi

    local stats
    stats=$(jq -s '{
        total: length,
        reused: [.[] | select(.success_count > 0 or .failure_count > 0)] | length,
        reuse_rate: (if length > 0 then ([.[] | select(.success_count > 0 or .failure_count > 0)] | length) * 100 / length else 0 end)
    }' "$FLEET_PATTERNS_FILE" 2>/dev/null || echo '{"reuse_rate":0,"total":0,"reused":0}')

    if [[ "$json_output" == "true" ]]; then
        echo "$stats"
        return 0
    fi

    local rate total reused
    rate=$(echo "$stats" | jq -r '.reuse_rate' 2>/dev/null || echo 0)
    total=$(echo "$stats" | jq -r '.total' 2>/dev/null || echo 0)
    reused=$(echo "$stats" | jq -r '.reused' 2>/dev/null || echo 0)

    echo ""
    info "Reuse rate: ${rate}% ($reused of $total patterns reused across repos)"
}

# ─── Effectiveness breakdown ────────────────────────────────────────────────
fleet_patterns_effectiveness() {
    local category=""
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --category)   category="${2:-}"; shift 2 ;;
            --category=*) category="${1#*=}"; shift ;;
            --json)       json_output=true; shift ;;
            *)            shift ;;
        esac
    done

    if [[ ! -f "$FLEET_PATTERNS_FILE" ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo '[]'
        else
            info "No fleet patterns captured yet"
        fi
        return 0
    fi

    local filter='.'
    if [[ -n "$category" ]]; then
        filter="map(select(.category == \"$category\"))"
    fi

    local stats
    stats=$(jq -s "$filter | group_by(.category) | map({
        category: .[0].category,
        count: length,
        avg_effectiveness: (map(.effectiveness_rate) | add / length | . * 10 | round / 10),
        total_successes: (map(.success_count) | add),
        total_failures: (map(.failure_count) | add)
    })" "$FLEET_PATTERNS_FILE" 2>/dev/null || echo '[]')

    if [[ "$json_output" == "true" ]]; then
        echo "$stats"
        return 0
    fi

    echo ""
    echo -e "  ${CYAN:-}${BOLD:-}Effectiveness by Category${RESET:-}"
    echo -e "  ${DIM:-}══════════════════════════════════════════${RESET:-}"
    echo ""

    printf "  %-12s %8s %15s %10s %10s\n" "Category" "Count" "Avg Eff." "Successes" "Failures"
    echo -e "  ${DIM:-}────────────────────────────────────────────────────────────${RESET:-}"
    echo "$stats" | jq -r '.[] | "  \(.category)|\(.count)|\(.avg_effectiveness)%|\(.total_successes)|\(.total_failures)"' 2>/dev/null | \
    while IFS='|' read -r cat cnt eff succ fail; do
        printf "  %-12s %8s %15s %10s %10s\n" "$cat" "$cnt" "$eff" "$succ" "$fail"
    done
    echo ""
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "  ${CYAN:-}${BOLD:-}shipwright fleet patterns${RESET:-} — Cross-Repository Pattern Sharing"
    echo ""
    echo "  Commands:"
    echo "    list          List captured fleet patterns [--limit N] [--json]"
    echo "    search        Search patterns by keyword [--limit N] [--category CAT] [--json]"
    echo "    show          Show pattern detail by ID"
    echo "    stats         Show pattern statistics [--period DAYS] [--json]"
    echo "    prune         Remove old patterns [--older-than DAYS] [--dry-run]"
    echo "    reuse-rate    Show pattern reuse rate [--json]"
    echo "    effectiveness Effectiveness breakdown by category [--category CAT] [--json]"
    echo ""
    echo "  Configuration:"
    echo "    Set pattern_share_enabled: true in fleet-config.json or daemon-config.json"
    echo ""
}

# ─── Command Router (skip when sourced) ─────────────────────────────────────
# Allow sourcing for function access without triggering CLI dispatch
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SUBCMD="${1:-help}"
    shift 2>/dev/null || true

    case "$SUBCMD" in
        list)          fleet_patterns_list "$@" ;;
        search)        fleet_patterns_search "$@" ;;
        show)          fleet_patterns_show "$@" ;;
        stats)         fleet_patterns_stats "$@" ;;
        prune)         fleet_patterns_prune "$@" ;;
        reuse-rate)    fleet_patterns_reuse_rate "$@" ;;
        effectiveness) fleet_patterns_effectiveness "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: ${SUBCMD}"
            show_help
            exit 1
            ;;
    esac
fi
