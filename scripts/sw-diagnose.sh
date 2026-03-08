#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-diagnose.sh — Interactive diagnostic mode for failed pipelines      ║
# ║                                                                          ║
# ║  Analyzes failed pipeline artifacts and suggests fixes.                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Colors (Bash 3.2 compatible) ────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
PURPLE='\033[38;2;168;85;247m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'

# ─── Globals ─────────────────────────────────────────────────────────────────
VERBOSE=false
OUTPUT_JSON=false
PIPELINE_DIR="${PIPELINE_DIR:-./.claude/pipeline-artifacts}"
STATE_FILE="${STATE_FILE:-./.claude/pipeline-state.md}"

# Data structures (simple arrays/strings due to Bash 3.2 compat)
declare -a ERRORS=()
declare -a CLASSIFICATIONS=()
declare -a DIAGNOSES=()
declare -a MEMORY_MATCHES=()
PIPELINE_GOAL=""
PIPELINE_STAGE=""
PIPELINE_STATUS="unknown"
ELAPSED=""

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  echo ""
  echo -e "${CYAN}${BOLD}  Shipwright — Diagnose${RESET}"
  echo -e "${DIM}  Interactive diagnostic mode for failed pipelines${RESET}"
  echo ""
  echo -e "${BOLD}USAGE${RESET}"
  echo -e "  ${CYAN}shipwright diagnose${RESET} [options]"
  echo ""
  echo -e "${BOLD}OPTIONS${RESET}"
  echo -e "  ${CYAN}--json${RESET}      Output as JSON (for tooling/automation)"
  echo -e "  ${CYAN}--verbose${RESET}   Include detailed evidence and log excerpts"
  echo -e "  ${CYAN}--help${RESET}      Show this help message"
  echo -e "  ${CYAN}--version${RESET}   Show version"
  echo ""
  echo -e "${BOLD}EXAMPLES${RESET}"
  echo -e "  ${DIM}# Diagnose latest failed pipeline${RESET}"
  echo -e "  ${CYAN}shipwright diagnose${RESET}"
  echo ""
  echo -e "  ${DIM}# Output as machine-readable JSON${RESET}"
  echo -e "  ${CYAN}shipwright diagnose --json${RESET}"
  echo ""
}

# ─── Parse Arguments ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --json)      OUTPUT_JSON=true ;;
    --verbose)   VERBOSE=true ;;
    --version|-V) echo "sw-diagnose $VERSION"; exit 0 ;;
    --help|-h)   show_help; exit 0 ;;
    *)           echo "Unknown option: $arg" >&2; show_help; exit 1 ;;
  esac
done

# ─── YAML Frontmatter Parser (Bash 3.2 compatible) ──────────────────────────
parse_yaml_frontmatter() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1

  # Extract between --- markers, grep the key, extract value
  local line
  line=$(sed -n '/^---$/,/^---$/p' "$file" | grep "^$key:" | head -1)
  [[ -z "$line" ]] && return 1

  # Extract value after ': '
  local value="${line#*: }"
  # Remove quotes if present
  value="${value%\"}"
  value="${value#\"}"
  echo "$value"
}

# ─── Stage 1: Load Pipeline State ────────────────────────────────────────────
load_pipeline_state() {
  [[ ! -f "$STATE_FILE" ]] && return 1

  PIPELINE_GOAL=$(parse_yaml_frontmatter "$STATE_FILE" "goal" || echo "")
  PIPELINE_STAGE=$(parse_yaml_frontmatter "$STATE_FILE" "current_stage" || echo "")
  PIPELINE_STATUS=$(parse_yaml_frontmatter "$STATE_FILE" "status" || echo "unknown")
  ELAPSED=$(parse_yaml_frontmatter "$STATE_FILE" "elapsed" || echo "")

  return 0
}

# ─── Stage 2: Collect Errors from Artifacts ──────────────────────────────────
collect_errors() {
  local error_summary="${PIPELINE_DIR}/error-summary.json"
  local error_log="${PIPELINE_DIR}/error-log.jsonl"
  local line

  # Try error-summary.json first (structured)
  if [[ -f "$error_summary" ]]; then
    if command -v jq >/dev/null 2>&1; then
      # Extract error messages from JSON array (avoid subshell by using while < <())
      while IFS= read -r line; do
        [[ -n "$line" ]] && ERRORS+=("$line")
      done < <(jq -r '.errors[]? | .message // ""' "$error_summary" 2>/dev/null)
    else
      # Fallback: grep for error patterns
      while IFS= read -r line; do
        [[ -n "$line" ]] && ERRORS+=("$line")
      done < <(grep -o '"message":"[^"]*"' "$error_summary" 2>/dev/null | sed 's/"message":"\(.*\)"/\1/')
    fi
  fi

  # Try error-log.jsonl (append log, one JSON object per line)
  if [[ -f "$error_log" ]]; then
    if command -v jq >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && ERRORS+=("$line")
      done < <(jq -r 'select(.level == "error") | .message // .msg // ""' "$error_log" 2>/dev/null)
    else
      while IFS= read -r line; do
        [[ -n "$line" ]] && ERRORS+=("$line")
      done < <(grep -o '"message":"[^"]*"' "$error_log" 2>/dev/null | sed 's/"message":"\(.*\)"/\1/')
    fi
  fi

  return 0
}

# ─── Stage 3: Classify Errors ────────────────────────────────────────────────
classify_errors() {
  local -i idx=0

  for error_msg in "${ERRORS[@]}"; do
    local type="unknown"
    local confidence="low"

    # Syntax/Type errors
    if echo "$error_msg" | grep -qEi "SyntaxError|TypeError|ReferenceError|Unexpected token"; then
      type="syntax"
      confidence="high"
    fi

    # Test failures
    if echo "$error_msg" | grep -qEi "FAIL|assert.*Error|expect.*received|test.*failed"; then
      type="test"
      confidence="high"
    fi

    # Network/connectivity errors
    if echo "$error_msg" | grep -qEi "ECONNREFUSED|ETIMEDOUT|ENOTFOUND|fetch.*failed|Network error|getaddrinfo"; then
      type="network"
      confidence="high"
    fi

    # Resource exhaustion
    if echo "$error_msg" | grep -qEi "ENOMEM|heap out of memory|allocation failed|Maximum call|out of memory"; then
      type="resource"
      confidence="high"
    fi

    # Timeout
    if echo "$error_msg" | grep -qEi "timeout|timed out|TIMEOUT|deadline exceeded"; then
      type="timeout"
      confidence="high"
    fi

    # Permission errors
    if echo "$error_msg" | grep -qEi "EACCES|EPERM|permission denied|Access denied"; then
      type="permission"
      confidence="high"
    fi

    CLASSIFICATIONS+=("$type:$confidence:$error_msg")
    idx=$((idx + 1))
  done
}

# ─── Stage 4: Search Memory for Similar Past Failures ──────────────────────────
search_memory() {
  # Call memory_ranked_search if available
  if [[ -n "${PIPELINE_GOAL:-}" ]] && type memory_ranked_search >/dev/null 2>&1; then
    # Try to search by combined error + goal context
    local query="${PIPELINE_GOAL} failed in ${PIPELINE_STAGE}"
    # memory_ranked_search returns structured results; we capture them
    local mem_result
    mem_result=$(memory_ranked_search "$query" 2>/dev/null || echo "")
    if [[ -n "$mem_result" ]]; then
      # Parse result and add to MEMORY_MATCHES
      echo "$mem_result" | while read -r match; do
        [[ -n "$match" ]] && MEMORY_MATCHES+=("$match")
      done
    fi
  fi
}

# ─── Stage 5: Rank Diagnoses by Confidence ──────────────────────────────────
rank_diagnoses() {
  # Build diagnoses from classifications
  local -i rank=1

  for classification in "${CLASSIFICATIONS[@]}"; do
    local type="${classification%%:*}"
    local rest="${classification#*:}"
    local confidence="${rest%%:*}"
    local message="${rest#*:}"

    # Generate fix suggestions based on type
    local fix_suggestion=""
    case "$type" in
      syntax)
        fix_suggestion="Check the error line in the code and fix the syntax or type error"
        ;;
      test)
        fix_suggestion="Review test expectations vs actual behavior; run the failing test with npm test"
        ;;
      network)
        fix_suggestion="Check network connectivity, API keys, service availability, and firewall rules"
        ;;
      resource)
        fix_suggestion="Increase memory limit or reduce batch size; check for memory leaks"
        ;;
      timeout)
        fix_suggestion="Increase timeout duration, optimize slow operations, or split into smaller tasks"
        ;;
      permission)
        fix_suggestion="Check file permissions and access control; ensure directories are writable"
        ;;
      *)
        fix_suggestion="Review the error message above and investigate the cause"
        ;;
    esac

    DIAGNOSES+=("$rank||$confidence||$type||$message||$fix_suggestion")
    rank=$((rank + 1))
  done

  # Sort by confidence (high > medium > low), then by rank
  # Due to Bash 3.2 compat, simple bubble sort
  local -i i j n=${#DIAGNOSES[@]}
  for ((i = 0; i < n - 1; i++)); do
    for ((j = 0; j < n - i - 1; j++)); do
      local conf1="${DIAGNOSES[$j]#*||}"
      conf1="${conf1%%||*}"
      local conf2="${DIAGNOSES[$((j + 1))]#*||}"
      conf2="${conf2%%||*}"

      # Convert confidence to number (high=2, medium=1, low=0)
      local num1=0 num2=0
      [[ "$conf1" == "high" ]] && num1=2
      [[ "$conf1" == "medium" ]] && num1=1
      [[ "$conf2" == "high" ]] && num2=2
      [[ "$conf2" == "medium" ]] && num2=1

      if [[ $num1 -lt $num2 ]]; then
        # Swap
        local tmp="${DIAGNOSES[$j]}"
        DIAGNOSES[$j]="${DIAGNOSES[$((j + 1))]}"
        DIAGNOSES[$((j + 1))]="$tmp"
      fi
    done
  done
}

# ─── Stage 6a: Render Text Report ───────────────────────────────────────────
render_report() {
  echo ""
  echo -e "${CYAN}${BOLD}  Shipwright — Diagnostic Report${RESET}"
  echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
  echo ""

  # Pipeline context
  echo -e "${PURPLE}${BOLD}  PIPELINE CONTEXT${RESET}"
  echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
  echo -e "  Goal:    ${PIPELINE_GOAL:-<unknown>}"
  echo -e "  Stage:   ${PIPELINE_STAGE:-<unknown>}"
  echo -e "  Status:  ${PIPELINE_STATUS}"
  echo -e "  Elapsed: ${ELAPSED:-<unknown>}"
  echo ""

  # Diagnoses
  if [[ ${#DIAGNOSES[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ✓ No errors found${RESET}"
    echo -e "${DIM}  Pipeline artifacts show no failures${RESET}"
    echo ""
    return 0
  fi

  echo -e "${PURPLE}${BOLD}  LIKELY ROOT CAUSES${RESET}"
  echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

  local -i count=0
  for diagnosis in "${DIAGNOSES[@]}"; do
    local rank="${diagnosis%%||*}"
    local rest="${diagnosis#*||}"
    local confidence="${rest%%||*}"
    local rest="${rest#*||}"
    local type="${rest%%||*}"
    local rest="${rest#*||}"
    local message="${rest%%||*}"
    local fix="${rest#*||}"

    count=$((count + 1))
    [[ $count -gt 3 && ! $VERBOSE ]] && break  # Limit to 3 unless verbose

    echo ""
    local conf_color="${GREEN}"
    [[ "$confidence" == "medium" ]] && conf_color="${YELLOW}"
    [[ "$confidence" == "low" ]] && conf_color="${DIM}"

    echo -e "  ${BOLD}#$rank${RESET}  ${conf_color}[${confidence}]${RESET}  ${type^^}"
    echo -e "  Message:  $message"
    echo -e "  Fix:      $fix"
  done

  if [[ ${#DIAGNOSES[@]} -gt 3 && ! $VERBOSE ]]; then
    echo ""
    echo -e "  ${DIM}(${#DIAGNOSES[@]} total causes found; run with --verbose for all)${RESET}"
  fi

  echo ""

  # Memory matches
  if [[ ${#MEMORY_MATCHES[@]} -gt 0 ]]; then
    echo -e "${PURPLE}${BOLD}  SIMILAR PAST FAILURES${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    count=0
    for match in "${MEMORY_MATCHES[@]}"; do
      count=$((count + 1))
      [[ $count -gt 3 && ! $VERBOSE ]] && break
      echo -e "  • $match"
    done
    echo ""
  fi

  # Files to investigate
  local files_to_check=()
  [[ -f "$PIPELINE_DIR/error-summary.json" ]] && files_to_check+=(".claude/pipeline-artifacts/error-summary.json")
  [[ -f "$PIPELINE_DIR/error-log.jsonl" ]] && files_to_check+=(".claude/pipeline-artifacts/error-log.jsonl")
  [[ -f "$STATE_FILE" ]] && files_to_check+=(".claude/pipeline-state.md")

  if [[ ${#files_to_check[@]} -gt 0 ]]; then
    echo -e "${PURPLE}${BOLD}  FILES TO INVESTIGATE${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    for file in "${files_to_check[@]}"; do
      echo -e "  • ${DIM}${file}${RESET}"
    done
    echo ""
  fi

  echo -e "${DIM}  Run: shipwright diagnose --verbose  for more details${RESET}"
  echo ""
}

# ─── Stage 6b: Render JSON Output ───────────────────────────────────────────
render_json() {
  # Build JSON manually (no jq required for output)
  local json_errors="[]"
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    json_errors="["
    local first=true
    for err in "${ERRORS[@]}"; do
      [[ "$first" == true ]] && first=false || json_errors="${json_errors},"
      # Escape quotes and newlines
      err="${err//\\/\\\\}"
      err="${err//\"/\\\"}"
      json_errors="${json_errors}{\"message\":\"${err}\"}"
    done
    json_errors="${json_errors}]"
  fi

  local json_diagnoses="[]"
  if [[ ${#DIAGNOSES[@]} -gt 0 ]]; then
    json_diagnoses="["
    local first=true
    for diag in "${DIAGNOSES[@]}"; do
      [[ "$first" == true ]] && first=false || json_diagnoses="${json_diagnoses},"
      local rank="${diag%%||*}"
      local rest="${diag#*||}"
      local confidence="${rest%%||*}"
      local rest="${rest#*||}"
      local type="${rest%%||*}"
      local rest="${rest#*||}"
      local message="${rest%%||*}"
      local fix="${rest#*||}"

      # Escape JSON strings
      message="${message//\\/\\\\}"
      message="${message//\"/\\\"}"
      fix="${fix//\\/\\\\}"
      fix="${fix//\"/\\\"}"

      json_diagnoses="${json_diagnoses}{\"rank\":${rank},\"type\":\"${type}\",\"confidence\":\"${confidence}\",\"message\":\"${message}\",\"fix\":\"${fix}\"}"
    done
    json_diagnoses="${json_diagnoses}]"
  fi

  # Build final JSON object
  echo "{"
  echo "  \"status\": \"$PIPELINE_STATUS\","
  echo "  \"pipeline\": {"
  echo "    \"goal\": \"${PIPELINE_GOAL//\"/\\\"}\","
  echo "    \"stage\": \"${PIPELINE_STAGE}\","
  echo "    \"elapsed\": \"${ELAPSED}\""
  echo "  },"
  echo "  \"errors\": $json_errors,"
  echo "  \"diagnoses\": $json_diagnoses"
  echo "}"
}

# ─── Main Execution ──────────────────────────────────────────────────────────
main() {
  emit_event "diagnose.started"

  # Load pipeline state
  if ! load_pipeline_state; then
    if [[ "$OUTPUT_JSON" == true ]]; then
      echo '{"status":"clean","errors":[],"diagnoses":[]}'
    else
      warn "No pipeline state found"
      echo ""
      echo -e "  ${DIM}Run a pipeline first:${RESET}"
      echo -e "  ${DIM}  shipwright pipeline start --issue <N>${RESET}"
      echo ""
    fi
    emit_event "diagnose.completed" "status=clean"
    return 0
  fi

  # Collect and analyze errors
  collect_errors
  classify_errors
  search_memory
  rank_diagnoses

  # Render output
  if [[ "$OUTPUT_JSON" == true ]]; then
    render_json
  else
    render_report
  fi

  emit_event "diagnose.completed" "status=$PIPELINE_STATUS" "diagnoses=${#DIAGNOSES[@]}"

  # Exit code: always 0 (diagnosis complete, whether failures found or not)
  return 0
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
