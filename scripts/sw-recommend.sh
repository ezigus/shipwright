#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright recommend — intelligent template auto-recommendation engine   ║
# ║  Combines 8 signal sources: labels, DORA, quality, Thompson sampling,    ║
# ║  template weights, AI analysis, repo heuristics, and fallback            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"

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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
WEIGHTS_FILE="${HOME}/.shipwright/template-weights.json"
REPO_DIR="${REPO_DIR:-${PWD}}"

# ─── Valid templates ────────────────────────────────────────────────────────
VALID_TEMPLATES="fast standard full hotfix enterprise cost-aware autonomous"

# ════════════════════════════════════════════════════════════════════════════
# Signal 1: Label overrides (hard rules — highest priority)
# ════════════════════════════════════════════════════════════════════════════
_labels_template() {
    local labels_csv="${1:-}"
    [[ -z "$labels_csv" ]] && echo "" && return

    local labels_lower
    labels_lower=$(echo "$labels_csv" | tr '[:upper:]' '[:lower:]')

    if echo "$labels_lower" | grep -qE '(hotfix|incident|emergency|urgent)'; then
        echo "hotfix"; return
    fi
    if echo "$labels_lower" | grep -qE '(security|vulnerability|cve|compliance)'; then
        echo "enterprise"; return
    fi
    if echo "$labels_lower" | grep -qE '(cost|budget|economy)'; then
        echo "cost-aware"; return
    fi
    if echo "$labels_lower" | grep -qE '(trivial|docs|documentation|typo|chore)'; then
        echo "fast"; return
    fi
    if echo "$labels_lower" | grep -qE '(epic|major|architecture|breaking|refactor)'; then
        echo "full"; return
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 2: DORA escalation (safety override)
# ════════════════════════════════════════════════════════════════════════════
_dora_template() {
    [[ ! -f "${EVENTS_FILE}" ]] && echo "" && return

    local recent_events total failures cfr
    recent_events=$(tail -500 "${EVENTS_FILE}" \
        | grep '"type":"pipeline.completed"' 2>/dev/null \
        | tail -10 || true)
    total=$(echo "$recent_events" | grep -c '.' 2>/dev/null || true)
    total="${total:-0}"

    [[ "$total" -lt 3 ]] && echo "" && return

    failures=$(echo "$recent_events" | grep -c '"result":"failure"' 2>/dev/null || true)
    failures="${failures:-0}"
    cfr=$(( failures * 100 / total ))

    if [[ "$cfr" -gt 40 ]]; then
        echo "enterprise"; return
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 3: Quality memory override (safety gate)
# ════════════════════════════════════════════════════════════════════════════
_quality_template() {
    local repo_hash="${1:-}"
    [[ -z "$repo_hash" ]] && echo "" && return
    if ! db_available 2>/dev/null; then echo "" && return; fi

    local critical_count
    critical_count=$(_db_query "SELECT COUNT(*) FROM memory_failures
        WHERE repo_hash='${repo_hash}' AND failure_class='critical'
        AND created_at >= datetime('now','-7 days');" 2>/dev/null || echo "0")
    critical_count="${critical_count:-0}"
    critical_count=$(echo "$critical_count" | tr -d '[:space:]')

    if [[ "${critical_count:-0}" -ge 3 ]]; then
        echo "enterprise"; return
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 4: Thompson sampling from historical pipeline_outcomes
# Returns: "template|confidence_0_to_1|sample_size"
# ════════════════════════════════════════════════════════════════════════════
_thompson_template_with_confidence() {
    local complexity="${1:-medium}"
    if ! db_available 2>/dev/null; then echo "standard|0.3|0"; return; fi

    local outcomes
    outcomes=$(_db_query "SELECT template,
        SUM(CASE WHEN success=1 THEN 1 ELSE 0 END) as wins,
        SUM(CASE WHEN success=0 THEN 1 ELSE 0 END) as losses,
        COUNT(*) as total
        FROM pipeline_outcomes
        WHERE complexity='$complexity' AND template IS NOT NULL AND template != ''
        GROUP BY template;" 2>/dev/null || echo "")

    [[ -z "$outcomes" ]] && echo "standard|0.3|0" && return

    local best_template="standard"
    local best_score=0
    local best_wins=1
    local best_total=2
    local grand_total=0

    while IFS='|' read -r template wins losses total; do
        [[ -z "$template" ]] && continue
        template=$(echo "$template" | xargs)
        wins="${wins:-0}"; losses="${losses:-0}"; total="${total:-0}"
        grand_total=$(( grand_total + total ))
        local alpha=$(( wins + 1 ))
        local beta_param=$(( losses + 1 ))
        local t=$(( alpha + beta_param ))
        local mean_x1000=$(( (alpha * 1000) / t ))
        local noise=$(( (RANDOM % 200) - 100 ))
        local variance_factor=$(( 1000 / (t + 1) ))
        local score=$(( mean_x1000 + (noise * variance_factor / 100) ))
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_template="$template"
            best_wins=$wins
            best_total=$total
        fi
    done <<< "$outcomes"

    # Compute confidence tier from sample size
    local confidence
    if [[ "$grand_total" -ge 50 ]]; then
        confidence="0.85"
    elif [[ "$grand_total" -ge 10 ]]; then
        confidence="0.65"
    elif [[ "$grand_total" -ge 1 ]]; then
        confidence="0.45"
    else
        confidence="0.30"
    fi

    echo "${best_template}|${confidence}|${grand_total}"
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 5: Learned template weights (from sw-self-optimize.sh)
# ════════════════════════════════════════════════════════════════════════════
_weights_template() {
    local complexity="${1:-medium}"
    [[ ! -f "$WEIGHTS_FILE" ]] && echo "" && return

    local best_template
    best_template=$(jq -r --arg c "$complexity" '
        .[$c] // .medium // {} |
        to_entries | max_by(.value) | .key // ""
    ' "$WEIGHTS_FILE" 2>/dev/null || echo "")
    echo "${best_template:-}"
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 6: Intelligence analysis (from intelligence cache)
# ════════════════════════════════════════════════════════════════════════════
_intelligence_template() {
    local cache_file="${REPO_DIR}/.claude/intelligence-cache.json"
    [[ ! -f "$cache_file" ]] && echo "" && return

    local recommended
    recommended=$(jq -r '.recommended_template // ""' "$cache_file" 2>/dev/null || echo "")
    echo "${recommended:-}"
}

# ════════════════════════════════════════════════════════════════════════════
# Signal 7: Repo heuristics (language, framework, test setup)
# ════════════════════════════════════════════════════════════════════════════
_repo_type() {
    local repo_dir="${1:-$REPO_DIR}"
    if [[ -f "$repo_dir/package.json" ]]; then
        echo "node"
    elif [[ -f "$repo_dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$repo_dir/pyproject.toml" || -f "$repo_dir/setup.py" || -f "$repo_dir/requirements.txt" ]]; then
        echo "python"
    elif [[ -f "$repo_dir/Gemfile" ]]; then
        echo "ruby"
    elif [[ -f "$repo_dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$repo_dir/pom.xml" || -f "$repo_dir/build.gradle" ]]; then
        echo "java"
    elif [[ -f "$repo_dir/Package.swift" ]]; then
        echo "swift"
    else
        echo "unknown"
    fi
}

_heuristic_complexity() {
    local repo_dir="${1:-$REPO_DIR}"
    local goal="${2:-}"
    local labels_csv="${3:-}"

    # Goal keyword signals
    if echo "$goal $labels_csv" | grep -qiE '(security|auth|payment|migration|database|schema|refactor|breaking)'; then
        echo "high"; return
    fi
    if echo "$goal $labels_csv" | grep -qiE '(fix|bug|typo|docs|readme|comment|minor|patch)'; then
        echo "low"; return
    fi

    # Repo size signal
    local file_count=0
    if [[ -d "$repo_dir" ]]; then
        file_count=$(find "$repo_dir" -maxdepth 3 -name "*.js" -o -name "*.ts" -o -name "*.go" \
            -o -name "*.py" -o -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [[ "${file_count:-0}" -gt 100 ]]; then
        echo "high"
    elif [[ "${file_count:-0}" -gt 20 ]]; then
        echo "medium"
    else
        echo "low"
    fi
}

_heuristic_template() {
    local complexity="${1:-medium}"
    local repo_type="${2:-unknown}"

    case "$complexity" in
        low)  echo "fast" ;;
        high) echo "full" ;;
        *)
            # Node.js repos with medium complexity → standard
            case "$repo_type" in
                node|python|ruby) echo "standard" ;;
                go|rust)          echo "standard" ;;
                *)                echo "standard" ;;
            esac
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════
# Core: recommend_template() — combine all signals into one recommendation
# Outputs JSON: {template, confidence, confidence_label, reasoning, factors, alternatives}
# ════════════════════════════════════════════════════════════════════════════
recommend_template() {
    local issue_json="${1:-{}}"
    local repo_dir="${2:-$REPO_DIR}"
    local job_id="${3:-$$}"

    # Extract fields from issue JSON
    local goal labels_csv
    goal=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    labels_csv=$(echo "$issue_json" | jq -r '[.labels[]?.name // .labels[]? // ""] | join(",")' 2>/dev/null || echo "")

    # Repo context
    local repo_type
    repo_type=$(_repo_type "$repo_dir")
    local repo_hash=""
    if command -v git >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        repo_hash=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null | md5sum 2>/dev/null | cut -c1-8 \
            || git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null | shasum 2>/dev/null | cut -c1-8 \
            || echo "unknown")
    fi

    # Complexity estimate
    local complexity
    complexity=$(_heuristic_complexity "$repo_dir" "$goal" "$labels_csv")

    local final_template="" final_confidence="0.3"
    local reasoning="" signal_used="fallback"
    local sample_size=0

    # ── Signal 1: Label overrides (hard rules) ──
    local label_tmpl
    label_tmpl=$(_labels_template "$labels_csv")
    if [[ -n "$label_tmpl" ]]; then
        final_template="$label_tmpl"
        final_confidence="0.95"
        signal_used="label_override"
        reasoning="Label override: '$labels_csv' maps to $label_tmpl template"
    fi

    # ── Signal 2: DORA escalation (safety override) ──
    if [[ -z "$final_template" ]]; then
        local dora_tmpl
        dora_tmpl=$(_dora_template)
        if [[ -n "$dora_tmpl" ]]; then
            final_template="$dora_tmpl"
            final_confidence="0.90"
            signal_used="dora_escalation"
            reasoning="DORA escalation: high change failure rate detected, using $dora_tmpl for safety"
        fi
    fi

    # ── Signal 3: Quality memory override ──
    if [[ -z "$final_template" ]]; then
        local quality_tmpl
        quality_tmpl=$(_quality_template "$repo_hash")
        if [[ -n "$quality_tmpl" ]]; then
            final_template="$quality_tmpl"
            final_confidence="0.85"
            signal_used="quality_memory"
            reasoning="Quality memory: 3+ critical failures in last 7 days, escalating to $quality_tmpl"
        fi
    fi

    # ── Signal 4: Thompson sampling from historical outcomes ──
    local thompson_result thompson_tmpl thompson_conf
    thompson_result=$(_thompson_template_with_confidence "$complexity")
    thompson_tmpl=$(echo "$thompson_result" | cut -d'|' -f1)
    thompson_conf=$(echo "$thompson_result" | cut -d'|' -f2)
    sample_size=$(echo "$thompson_result" | cut -d'|' -f3)

    if [[ -z "$final_template" && "$sample_size" -ge 5 ]]; then
        final_template="$thompson_tmpl"
        final_confidence="$thompson_conf"
        signal_used="thompson_sampling"
        reasoning="Thompson sampling: ${thompson_tmpl} has highest success rate for $complexity complexity (${sample_size} historical runs)"
    fi

    # ── Signal 5: Template weights ──
    if [[ -z "$final_template" ]]; then
        local weights_tmpl
        weights_tmpl=$(_weights_template "$complexity")
        if [[ -n "$weights_tmpl" ]]; then
            final_template="$weights_tmpl"
            final_confidence="0.60"
            signal_used="template_weights"
            reasoning="Learned weights: $weights_tmpl performs best for $complexity complexity in this repo"
        fi
    fi

    # ── Signal 6: Intelligence analysis ──
    if [[ -z "$final_template" ]]; then
        local intel_tmpl
        intel_tmpl=$(_intelligence_template)
        if [[ -n "$intel_tmpl" ]]; then
            final_template="$intel_tmpl"
            final_confidence="0.55"
            signal_used="intelligence_analysis"
            reasoning="Intelligence analysis recommends $intel_tmpl based on codebase characteristics"
        fi
    fi

    # ── Signal 7: Repo heuristics ──
    if [[ -z "$final_template" ]]; then
        final_template=$(_heuristic_template "$complexity" "$repo_type")
        final_confidence="0.40"
        signal_used="repo_heuristics"
        reasoning="Repo heuristics: $repo_type repo with $complexity complexity → $final_template"
    fi

    # ── Signal 8: Fallback ──
    if [[ -z "$final_template" ]]; then
        final_template="standard"
        final_confidence="0.30"
        signal_used="fallback"
        reasoning="No signal data available — defaulting to standard template"
    fi

    # Validate template name
    local valid=false
    for t in $VALID_TEMPLATES; do
        [[ "$final_template" == "$t" ]] && valid=true && break
    done
    if [[ "$valid" != "true" ]]; then
        final_template="standard"
        final_confidence="0.30"
        reasoning="Invalid template detected — defaulting to standard"
    fi

    # Confidence label
    local conf_label
    local conf_int
    conf_int=$(echo "$final_confidence" | awk '{printf "%d", $1 * 100}')
    if [[ "$conf_int" -ge 80 ]]; then
        conf_label="high"
    elif [[ "$conf_int" -ge 50 ]]; then
        conf_label="medium"
    else
        conf_label="low"
    fi

    # Build alternatives (other templates from Thompson or heuristics)
    local alternatives="[]"
    if [[ "$signal_used" == "thompson_sampling" ]] && db_available 2>/dev/null; then
        local alt_data
        alt_data=$(_db_query "SELECT template,
            ROUND(CAST(SUM(CASE WHEN success=1 THEN 1 ELSE 0 END) AS REAL) / MAX(COUNT(*),1), 2) as rate,
            COUNT(*) as n
            FROM pipeline_outcomes
            WHERE complexity='$complexity' AND template != '$final_template'
            GROUP BY template ORDER BY rate DESC LIMIT 2;" 2>/dev/null || echo "")
        if [[ -n "$alt_data" ]]; then
            alternatives="["
            local first=true
            while IFS='|' read -r alt_tmpl rate n; do
                [[ -z "$alt_tmpl" ]] && continue
                alt_tmpl=$(echo "$alt_tmpl" | xargs)
                [[ "$first" != "true" ]] && alternatives="${alternatives},"
                alternatives="${alternatives}{\"template\":\"$alt_tmpl\",\"confidence\":$rate,\"reason\":\"${rate:-0} success rate over $n runs\"}"
                first=false
            done <<< "$alt_data"
            alternatives="${alternatives}]"
        fi
    fi

    # Factors JSON
    local factors
    factors=$(jq -n \
        --arg repo_type "$repo_type" \
        --arg complexity "$complexity" \
        --arg labels "$labels_csv" \
        --arg signal "$signal_used" \
        --argjson sample_size "$sample_size" \
        '{
            repo_type: $repo_type,
            complexity: $complexity,
            labels: $labels,
            signal_used: $signal,
            sample_size: $sample_size
        }' 2>/dev/null || echo "{}")

    # Output JSON
    jq -n \
        --arg template "$final_template" \
        --argjson confidence "$final_confidence" \
        --arg confidence_label "$conf_label" \
        --arg reasoning "$reasoning" \
        --argjson factors "$factors" \
        --argjson alternatives "$alternatives" \
        --arg signal "$signal_used" \
        --argjson sample_size "$sample_size" \
        '{
            template: $template,
            confidence: $confidence,
            confidence_label: $confidence_label,
            reasoning: $reasoning,
            factors: $factors,
            alternatives: $alternatives,
            signal_used: $signal,
            sample_size: $sample_size
        }' 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# Display: show_recommendation() — formatted boxed output
# ════════════════════════════════════════════════════════════════════════════
show_recommendation() {
    local rec_json="$1"

    local template confidence conf_label reasoning sample_size
    template=$(echo "$rec_json" | jq -r '.template // "standard"' 2>/dev/null)
    confidence=$(echo "$rec_json" | jq -r '.confidence // 0.5' 2>/dev/null)
    conf_label=$(echo "$rec_json" | jq -r '.confidence_label // "medium"' 2>/dev/null)
    reasoning=$(echo "$rec_json" | jq -r '.reasoning // ""' 2>/dev/null)
    sample_size=$(echo "$rec_json" | jq -r '.sample_size // 0' 2>/dev/null)

    # Confidence percentage
    local conf_pct
    conf_pct=$(echo "$confidence" | awk '{printf "%d", $1 * 100}')

    # Color based on confidence label
    local CYAN="\033[38;2;0;212;255m"
    local GREEN="\033[38;2;74;222;128m"
    local YELLOW="\033[38;2;250;204;21m"
    local DIM="\033[2m"
    local BOLD="\033[1m"
    local RESET="\033[0m"

    local conf_color
    case "$conf_label" in
        high)   conf_color="$GREEN" ;;
        medium) conf_color="$CYAN" ;;
        *)      conf_color="$YELLOW" ;;
    esac

    echo -e ""
    echo -e "  ${DIM}╭─────────────────────────────────────────────╮${RESET}"
    echo -e "  ${DIM}│${RESET}  ${BOLD}Template Recommendation${RESET}                      ${DIM}│${RESET}"
    echo -e "  ${DIM}│${RESET}                                             ${DIM}│${RESET}"
    echo -e "  ${DIM}│${RESET}  ${CYAN}${BOLD}✦ ${template}${RESET} ${conf_color}(${conf_pct}% confidence — ${conf_label})${RESET}     ${DIM}│${RESET}"

    if [[ -n "$reasoning" ]]; then
        # Truncate long reasoning for display (max 43 chars)
        local short_reason="${reasoning:0:43}"
        [[ "${#reasoning}" -gt 43 ]] && short_reason="${short_reason}…"
        echo -e "  ${DIM}│${RESET}    ${DIM}${short_reason}${RESET}  ${DIM}│${RESET}"
    fi

    if [[ "${sample_size:-0}" -gt 0 ]]; then
        echo -e "  ${DIM}│${RESET}    ${DIM}Based on ${sample_size} historical runs${RESET}         ${DIM}│${RESET}"
    fi

    echo -e "  ${DIM}│${RESET}                                             ${DIM}│${RESET}"
    echo -e "  ${DIM}│${RESET}  ${DIM}Override: --template <name>${RESET}                ${DIM}│${RESET}"
    echo -e "  ${DIM}╰─────────────────────────────────────────────╯${RESET}"
    echo -e ""
}

# ════════════════════════════════════════════════════════════════════════════
# Stats: show_stats() — acceptance rate + success rate report
# ════════════════════════════════════════════════════════════════════════════
show_stats() {
    local days="${1:-30}"

    if ! db_available 2>/dev/null; then
        info "No recommendation data yet (last ${days} days)"
        echo "  Database not available — run 'shipwright db migrate' to initialize."
        return 0
    fi

    local stats
    stats=$(db_query_recommendation_stats "$days" 2>/dev/null || echo "[]")

    if [[ -z "$stats" || "$stats" == "[]" || "$stats" == "null" ]]; then
        info "No recommendation data yet (last ${days} days)"
        echo "  Run pipelines without --template to start collecting data."
        return 0
    fi

    local CYAN="\033[38;2;0;212;255m"
    local GREEN="\033[38;2;74;222;128m"
    local BOLD="\033[1m"
    local DIM="\033[2m"
    local RESET="\033[0m"

    echo -e ""
    echo -e "  ${BOLD}Template Recommendation Stats (last ${days} days)${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────${RESET}"

    # Aggregate totals
    local total accepted overridden accepted_success overridden_success
    total=$(echo "$stats" | jq '[.[].total] | add // 0' 2>/dev/null || echo "0")
    accepted=$(echo "$stats" | jq '[.[].accepted] | add // 0' 2>/dev/null || echo "0")
    overridden=$(echo "$stats" | jq '[.[].overridden] | add // 0' 2>/dev/null || echo "0")
    accepted_success=$(echo "$stats" | jq '[.[].accepted_success] | add // 0' 2>/dev/null || echo "0")
    overridden_success=$(echo "$stats" | jq '[.[].overridden_success] | add // 0' 2>/dev/null || echo "0")

    local accept_rate=0 accept_success_rate=0 override_success_rate=0
    [[ "${total:-0}" -gt 0 ]] && accept_rate=$(( accepted * 100 / total ))
    [[ "${accepted:-0}" -gt 0 ]] && accept_success_rate=$(( accepted_success * 100 / accepted ))
    [[ "${overridden:-0}" -gt 0 ]] && override_success_rate=$(( overridden_success * 100 / overridden ))

    echo -e "  Acceptance rate:         ${CYAN}${BOLD}${accept_rate}%${RESET} (${accepted}/${total} recommendations accepted)"
    echo -e "  Success when accepted:   ${GREEN}${accept_success_rate}%${RESET} (${accepted_success}/${accepted})"
    echo -e "  Success when overridden: ${accept_success_rate}%  (${overridden_success}/${overridden})"
    echo -e ""
    echo -e "  ${BOLD}Per-template accuracy:${RESET}"

    echo "$stats" | jq -r '.[] | "\(.template)|\(.accepted_success)|\(.total)|\(.avg_confidence)"' 2>/dev/null \
    | while IFS='|' read -r tmpl tmpl_success tmpl_total tmpl_conf; do
        [[ -z "$tmpl" ]] && continue
        local pct=0
        [[ "${tmpl_total:-0}" -gt 0 ]] && pct=$(( ${tmpl_success%%.*} * 100 / ${tmpl_total%%.*} ))
        local conf_pct
        conf_pct=$(echo "$tmpl_conf" | awk '{printf "%d", $1 * 100}')
        printf "    %-14s %s%%  (%s runs, %s%% confidence avg)\n" \
            "$tmpl" "$pct" "$tmpl_total" "$conf_pct"
    done

    echo -e ""
}

# ════════════════════════════════════════════════════════════════════════════
# CLI subcommands
# ════════════════════════════════════════════════════════════════════════════
cmd_recommend() {
    local issue="" goal="" json_mode=false
    local repo="${REPO_DIR}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)   issue="$2"; shift 2 ;;
            --goal)    goal="$2"; shift 2 ;;
            --repo)    repo="$2"; shift 2 ;;
            --json)    json_mode=true; shift ;;
            *)         shift ;;
        esac
    done

    local issue_json="{}"
    if [[ -n "$issue" ]]; then
        issue_json=$(gh issue view "$issue" --json number,title,body,labels 2>/dev/null \
            || jq -n --arg n "$issue" '{number: ($n|tonumber), title: "", body: "", labels: []}')
    elif [[ -n "$goal" ]]; then
        issue_json=$(jq -n --arg t "$goal" '{title: $t, body: "", labels: []}')
    fi

    local rec
    rec=$(recommend_template "$issue_json" "$repo")

    if [[ "$json_mode" == "true" ]]; then
        echo "$rec"
    else
        show_recommendation "$rec"
        if [[ -n "$issue" || -n "$goal" ]]; then
            local tmpl conf
            tmpl=$(echo "$rec" | jq -r '.template')
            conf=$(echo "$rec" | jq -r '.confidence_label')
            success "Recommended: ${tmpl} (${conf} confidence)"
        fi
    fi
}

cmd_stats() {
    local days=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    show_stats "$days"
}

# ════════════════════════════════════════════════════════════════════════════
# Usage
# ════════════════════════════════════════════════════════════════════════════
usage() {
    cat <<EOF
${BOLD}shipwright recommend${RESET} — intelligent template auto-recommendation engine

${BOLD}Usage:${RESET}
  sw recommend [--issue N] [--goal "..."] [--json]
  sw recommend stats [--days N]

${BOLD}Subcommands:${RESET}
  ${CYAN}(default)${RESET}          Recommend a pipeline template with confidence + reasoning
  ${CYAN}stats${RESET}              Show acceptance rate and per-template success rates

${BOLD}Options:${RESET}
  --issue N          Fetch issue from GitHub for analysis
  --goal "text"      Analyze a goal string
  --repo DIR         Override repository directory (default: cwd)
  --json             Output JSON instead of formatted display
  --days N           Stats window in days (default: 30)

${BOLD}Signal hierarchy:${RESET}
  1. Label overrides (hotfix, security → hard rules)
  2. DORA escalation (high CFR → enterprise)
  3. Quality memory (critical failures → enterprise)
  4. Thompson sampling (historical success rates)
  5. Learned template weights
  6. Intelligence analysis (cache)
  7. Repo heuristics (language, complexity)
  8. Fallback (standard, 30% confidence)

${BOLD}Examples:${RESET}
  sw recommend --issue 42
  sw recommend --goal "Fix login timeout" --json
  sw recommend stats --days 60
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local subcmd="${1:-}"
    case "$subcmd" in
        stats)        shift; cmd_stats "$@" ;;
        --help|-h)    usage ;;
        --version|-v) echo "sw-recommend $VERSION" ;;
        *)            cmd_recommend "$@" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
