#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright task-classifier — Score task complexity for model routing    ║
# ║  Analyzes file count, change size, error context, and keywords          ║
# ║  Returns 0-100 complexity score used by sw-model-router.sh              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Default Weights ──────────────────────────────────────────────────────
WEIGHT_FILE_COUNT="30"
WEIGHT_LINE_CHANGES="30"
WEIGHT_ERROR_COMPLEXITY="20"
WEIGHT_KEYWORDS="20"

# ─── Load Classifier Weights from policy.json ────────────────────────────
_load_classifier_weights() {
    local policy_file="${REPO_DIR}/config/policy.json"
    if [[ -f "$policy_file" ]] && command -v jq >/dev/null 2>&1; then
        local w
        w=$(jq -r '.modelRouting.classifier_weights.file_count // empty' "$policy_file" 2>/dev/null || true)
        if [[ -n "$w" ]]; then
            # Convert decimal weight (0.3) to integer percentage (30)
            WEIGHT_FILE_COUNT=$(awk "BEGIN {printf \"%d\", $w * 100}" 2>/dev/null || echo "30")
        fi
        w=$(jq -r '.modelRouting.classifier_weights.line_changes // empty' "$policy_file" 2>/dev/null || true)
        if [[ -n "$w" ]]; then
            WEIGHT_LINE_CHANGES=$(awk "BEGIN {printf \"%d\", $w * 100}" 2>/dev/null || echo "30")
        fi
        w=$(jq -r '.modelRouting.classifier_weights.error_complexity // empty' "$policy_file" 2>/dev/null || true)
        if [[ -n "$w" ]]; then
            WEIGHT_ERROR_COMPLEXITY=$(awk "BEGIN {printf \"%d\", $w * 100}" 2>/dev/null || echo "20")
        fi
        w=$(jq -r '.modelRouting.classifier_weights.keywords // empty' "$policy_file" 2>/dev/null || true)
        if [[ -n "$w" ]]; then
            WEIGHT_KEYWORDS=$(awk "BEGIN {printf \"%d\", $w * 100}" 2>/dev/null || echo "20")
        fi
    fi
}

# ─── Score File Count (0-100) ──────────────────────────────────────────────
_score_file_count() {
    local file_list="$1"
    if [[ -z "$file_list" ]]; then
        echo "50"
        return
    fi

    local count=0
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<< "$file_list"

    if [[ "$count" -le 2 ]]; then
        echo "10"
    elif [[ "$count" -le 5 ]]; then
        echo "40"
    elif [[ "$count" -le 10 ]]; then
        echo "70"
    else
        echo "90"
    fi
}

# ─── Score Change Size (0-100) ─────────────────────────────────────────────
_score_change_size() {
    local line_count="${1:-0}"

    if ! [[ "$line_count" =~ ^[0-9]+$ ]]; then
        echo "50"
        return
    fi

    if [[ "$line_count" -lt 50 ]]; then
        echo "10"
    elif [[ "$line_count" -lt 200 ]]; then
        echo "40"
    elif [[ "$line_count" -lt 500 ]]; then
        echo "70"
    else
        echo "90"
    fi
}

# ─── Score Error Complexity (0-100) ─────────────────────────────────────────
_score_error_complexity() {
    local error_context="$1"
    if [[ -z "$error_context" ]]; then
        echo "10"
        return
    fi

    # Check for systemic/multi-file errors (highest complexity)
    local lower_ctx
    lower_ctx=$(echo "$error_context" | tr '[:upper:]' '[:lower:]')

    if echo "$lower_ctx" | grep -qE "systemic|across modules|multi.?file|architecture|cascade|circular"; then
        echo "80"
        return
    fi

    # Check for logic errors
    if echo "$lower_ctx" | grep -qE "logic error|race condition|deadlock|memory leak|infinite|stack overflow|regression"; then
        echo "50"
        return
    fi

    # Check for syntax/simple errors
    if echo "$lower_ctx" | grep -qE "syntax|typo|missing import|undefined variable|not found|cannot find"; then
        echo "20"
        return
    fi

    # Generic error — moderate complexity
    echo "35"
}

# ─── Score Keywords (0-100) ─────────────────────────────────────────────────
_score_keywords() {
    local issue_body="$1"
    if [[ -z "$issue_body" ]]; then
        echo "50"
        return
    fi

    local lower_body
    lower_body=$(echo "$issue_body" | tr '[:upper:]' '[:lower:]')

    # Check for high-complexity keywords first
    if echo "$lower_body" | grep -qE "architect|redesign|rewrite|overhaul|migration|breaking change"; then
        echo "90"
        return
    fi

    if echo "$lower_body" | grep -qE "refactor|restructure|rework|consolidat"; then
        echo "60"
        return
    fi

    if echo "$lower_body" | grep -qE "feature|implement|add|create|build|endpoint|integration"; then
        echo "40"
        return
    fi

    if echo "$lower_body" | grep -qE "fix|bug|patch|repair|resolve|correct"; then
        echo "30"
        return
    fi

    if echo "$lower_body" | grep -qE "doc|readme|comment|typo|chore|cleanup|format|lint|style"; then
        echo "10"
        return
    fi

    # Default: medium
    echo "40"
}

# ─── Main Classifier ───────────────────────────────────────────────────────
# classify_task <issue_body> [file_list] [error_context] [line_count]
# Returns: integer 0-100 via stdout
classify_task() {
    local issue_body="${1:-}"
    local file_list="${2:-}"
    local error_context="${3:-}"
    local line_count="${4:-0}"

    # Load configurable weights
    _load_classifier_weights

    # Score each signal
    local file_score change_score error_score keyword_score
    file_score=$(_score_file_count "$file_list")
    change_score=$(_score_change_size "$line_count")
    error_score=$(_score_error_complexity "$error_context")
    keyword_score=$(_score_keywords "$issue_body")

    # Weighted sum: weights are percentages (30 = 0.3), scores are 0-100
    # Formula: (file_score * 30 + change_score * 30 + error_score * 20 + keyword_score * 20) / 100
    local weighted_sum
    weighted_sum=$(( (file_score * WEIGHT_FILE_COUNT + change_score * WEIGHT_LINE_CHANGES + error_score * WEIGHT_ERROR_COMPLEXITY + keyword_score * WEIGHT_KEYWORDS) / 100 ))

    # Clamp to 0-100
    if [[ "$weighted_sum" -lt 0 ]]; then
        weighted_sum=0
    elif [[ "$weighted_sum" -gt 100 ]]; then
        weighted_sum=100
    fi

    echo "$weighted_sum"
}

# ─── Classify from Git Diff ────────────────────────────────────────────────
# Convenience: classify based on current working tree changes
classify_task_from_git() {
    local issue_body="${1:-}"
    local error_context="${2:-}"

    local file_list=""
    local line_count="0"

    if command -v git >/dev/null 2>&1; then
        file_list=$(git diff --name-only HEAD 2>/dev/null || true)
        if [[ -z "$file_list" ]]; then
            file_list=$(git diff --name-only --cached 2>/dev/null || true)
        fi

        local additions deletions
        additions=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo "0")
        deletions=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$2} END {print s+0}' || echo "0")
        line_count=$((additions + deletions))
    fi

    classify_task "$issue_body" "$file_list" "$error_context" "$line_count"
}

# ─── Complexity to Tier ────────────────────────────────────────────────────
# Maps a complexity score to a model tier name
complexity_to_tier() {
    local score="${1:-50}"
    local low_threshold="${2:-30}"
    local high_threshold="${3:-80}"

    # Load thresholds from policy.json if available
    local policy_file="${REPO_DIR}/config/policy.json"
    if [[ "$low_threshold" == "30" && "$high_threshold" == "80" ]] && [[ -f "$policy_file" ]] && command -v jq >/dev/null 2>&1; then
        local lt ht
        lt=$(jq -r '.modelRouting.complexity_thresholds.low // empty' "$policy_file" 2>/dev/null || true)
        ht=$(jq -r '.modelRouting.complexity_thresholds.high // empty' "$policy_file" 2>/dev/null || true)
        [[ -n "$lt" ]] && low_threshold="$lt"
        [[ -n "$ht" ]] && high_threshold="$ht"
    fi

    if [[ "$score" -lt "$low_threshold" ]]; then
        echo "haiku"
    elif [[ "$score" -ge "$high_threshold" ]]; then
        echo "opus"
    else
        echo "sonnet"
    fi
}

# ─── Help Text ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD:-}shipwright classify${RESET:-} — Task Complexity Classifier"
    echo ""
    echo -e "${BOLD:-}USAGE${RESET:-}"
    echo "  shipwright classify <issue_body> [file_list] [error_context] [line_count]"
    echo "  shipwright classify --git [issue_body] [error_context]"
    echo ""
    echo -e "${BOLD:-}SCORING${RESET:-}"
    echo "  File count (×0.3):  1-2→10, 3-5→40, 6-10→70, 10+→90"
    echo "  Line changes (×0.3): <50→10, 50-200→40, 200-500→70, 500+→90"
    echo "  Error context (×0.2): none→10, syntax→20, logic→50, systemic→80"
    echo "  Keywords (×0.2):    docs→10, fix→30, feature→40, refactor→60, architecture→90"
    echo ""
    echo -e "${BOLD:-}TIERS${RESET:-}"
    echo "  0-29 → haiku  |  30-79 → sonnet  |  80-100 → opus"
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local subcommand="${1:-help}"

    case "$subcommand" in
        classify)
            shift
            classify_task "$@"
            ;;
        --git|classify-git)
            shift 2>/dev/null || true
            classify_task_from_git "$@"
            ;;
        tier)
            shift
            local score
            score=$(classify_task "$@")
            complexity_to_tier "$score"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            # If called with just arguments (no subcommand), treat as classify
            classify_task "$@"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
