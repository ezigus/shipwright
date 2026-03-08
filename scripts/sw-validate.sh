#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-validate.sh — Pipeline pre-flight validation                        ║
# ║                                                                          ║
# ║  Validates pipeline configuration before execution to catch errors      ║
# ║  early. Usable standalone (shipwright validate) or from preflight.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Source libraries with fallback ──────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks when helpers not loaded (e.g. test env)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# Color fallbacks
[[ -n "${CYAN:-}" ]]   || CYAN='\033[38;2;0;212;255m'
[[ -n "${GREEN:-}" ]]  || GREEN='\033[38;2;74;222;128m'
[[ -n "${RED:-}" ]]    || RED='\033[38;2;248;113;113m'
[[ -n "${YELLOW:-}" ]] || YELLOW='\033[38;2;250;204;21m'
[[ -n "${PURPLE:-}" ]] || PURPLE='\033[38;2;124;58;237m'
[[ -n "${DIM:-}" ]]    || DIM='\033[2m'
[[ -n "${BOLD:-}" ]]   || BOLD='\033[1m'
[[ -n "${RESET:-}" ]]  || RESET='\033[0m'

# ─── Counters ───────────────────────────────────────────────────────────
ERRORS=0
WARNINGS=0
CHECKS=0

# ─── Parse flags ────────────────────────────────────────────────────────
PIPELINE_NAME=""
PROJECT_ROOT=""
NO_GITHUB="${NO_GITHUB:-false}"
QUIET=false
JSON_OUTPUT=false

for _arg in "$@"; do
    case "$_arg" in
        --pipeline)   _next_is_pipeline=true ;;
        --project-root) _next_is_root=true ;;
        --no-github)  NO_GITHUB=true ;;
        --quiet)      QUIET=true ;;
        --json)       JSON_OUTPUT=true ;;
        --version|-V) echo "sw-validate $VERSION"; exit 0 ;;
        --help|-h)
            echo "Usage: shipwright validate [--pipeline <name>] [--project-root PATH] [--no-github] [--json] [--quiet]"
            echo ""
            echo "Validates pipeline configuration before execution."
            echo ""
            echo "Options:"
            echo "  --pipeline <name>    Pipeline template to validate (default: standard)"
            echo "  --project-root PATH  Project root directory (default: git root)"
            echo "  --no-github          Skip GitHub connectivity checks"
            echo "  --json               Output results as JSON"
            echo "  --quiet              Suppress banner and decorative output"
            exit 0
            ;;
        *)
            if [[ "${_next_is_pipeline:-}" == "true" ]]; then
                PIPELINE_NAME="$_arg"
                _next_is_pipeline=false
            elif [[ "${_next_is_root:-}" == "true" ]]; then
                PROJECT_ROOT="$_arg"
                _next_is_root=false
            fi
            ;;
    esac
done

# Defaults
PIPELINE_NAME="${PIPELINE_NAME:-standard}"
if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$REPO_DIR")"
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$REPO_DIR/templates/pipelines}"
DEFAULTS_FILE="${DEFAULTS_FILE:-$REPO_DIR/config/defaults.json}"

# ─── Output helpers ─────────────────────────────────────────────────────
check_error() {
    local msg="$1"
    local fix="${2:-}"
    ERRORS=$((ERRORS + 1))
    CHECKS=$((CHECKS + 1))
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "  ${RED}✗${RESET} $msg"
        [[ -n "$fix" ]] && echo -e "    ${DIM}Fix: $fix${RESET}"
    fi
}

check_warn() {
    local msg="$1"
    local fix="${2:-}"
    WARNINGS=$((WARNINGS + 1))
    CHECKS=$((CHECKS + 1))
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $msg"
        [[ -n "$fix" ]] && echo -e "    ${DIM}Fix: $fix${RESET}"
    fi
}

check_pass() {
    CHECKS=$((CHECKS + 1))
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "  ${GREEN}✓${RESET} $1"
    fi
}

# ─── Canonical stage list ───────────────────────────────────────────────
get_valid_stages() {
    if [[ -f "$DEFAULTS_FILE" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.pipeline.stage_order[]' "$DEFAULTS_FILE" 2>/dev/null
    else
        # Hardcoded fallback
        echo "intake plan design build test review compound_quality pr merge deploy validate monitor" | tr ' ' '\n'
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# VALIDATORS
# ═══════════════════════════════════════════════════════════════════════════

# ─── 1. Template Validation ─────────────────────────────────────────────
validate_template() {
    local template_file="${TEMPLATES_DIR}/${PIPELINE_NAME}.json"

    if [[ ! -f "$template_file" ]]; then
        local available=""
        available=$(ls "$TEMPLATES_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json | tr '\n' ', ' | sed 's/,$//')
        check_error "Template not found: ${PIPELINE_NAME}" "Available templates: ${available:-none}"
        return
    fi

    # JSON syntax
    if ! jq empty "$template_file" 2>/dev/null; then
        check_error "Template '${PIPELINE_NAME}' has invalid JSON syntax" "Run: jq . $template_file"
        return
    fi
    check_pass "Template '${PIPELINE_NAME}' is valid JSON"

    # Required fields
    local has_name has_stages
    has_name=$(jq -r '.name // empty' "$template_file" 2>/dev/null)
    has_stages=$(jq -r '.stages // empty' "$template_file" 2>/dev/null)

    if [[ -z "$has_name" ]]; then
        check_error "Template missing required field: name"
    fi
    if [[ -z "$has_stages" ]]; then
        check_error "Template missing required field: stages" "Template must have a 'stages' array"
        return
    fi

    # Validate stage IDs against canonical list
    local valid_stages
    valid_stages=$(get_valid_stages)
    local stage_ids
    stage_ids=$(jq -r '.stages[].id' "$template_file" 2>/dev/null)

    local invalid_found=false
    while IFS= read -r stage_id; do
        [[ -z "$stage_id" ]] && continue
        if ! echo "$valid_stages" | grep -qx "$stage_id"; then
            check_error "Unknown stage ID: '${stage_id}'" "Valid stages: $(echo "$valid_stages" | tr '\n' ', ' | sed 's/,$//')"
            invalid_found=true
        fi
    done <<< "$stage_ids"

    if [[ "$invalid_found" != "true" ]]; then
        check_pass "All stage IDs are valid"
    fi

    # Validate gate values
    local gate_values
    gate_values=$(jq -r '.stages[].gate' "$template_file" 2>/dev/null)
    local invalid_gates=false
    while IFS= read -r gate; do
        [[ -z "$gate" ]] && continue
        if [[ "$gate" != "auto" && "$gate" != "approve" ]]; then
            check_error "Invalid gate value: '${gate}'" "Gate must be 'auto' or 'approve'"
            invalid_gates=true
        fi
    done <<< "$gate_values"

    if [[ "$invalid_gates" != "true" ]]; then
        check_pass "All gate values are valid"
    fi

    # Check for duplicate stage IDs
    local unique_count total_count
    total_count=$(jq '.stages | length' "$template_file" 2>/dev/null)
    unique_count=$(jq '[.stages[].id] | unique | length' "$template_file" 2>/dev/null)
    if [[ "$total_count" != "$unique_count" ]]; then
        check_error "Duplicate stage IDs detected" "Each stage ID must be unique"
    else
        check_pass "No duplicate stage IDs"
    fi
}

# ─── 2. Environment Validation ──────────────────────────────────────────
validate_environment() {
    # AI provider readiness
    local ai_provider ai_cmd
    ai_provider="${SHIPWRIGHT_AI_PROVIDER:-claude}"
    if [[ "$(type -t ai_provider_resolve 2>/dev/null)" == "function" ]]; then
        ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
    fi
    ai_cmd="$ai_provider"
    if [[ "$(type -t ai_provider_command 2>/dev/null)" == "function" ]]; then
        ai_cmd="$(ai_provider_command "$ai_provider" 2>/dev/null || echo "$ai_provider")"
    fi

    if command -v "$ai_cmd" >/dev/null 2>&1; then
        if [[ "$(type -t ai_provider_check_ready 2>/dev/null)" == "function" ]]; then
            if ai_provider_check_ready "$ai_provider" >/dev/null 2>&1; then
                check_pass "AI provider ready (${ai_provider}: ${ai_cmd})"
            else
                check_error "AI provider not ready (${ai_provider}: ${ai_cmd})" "Check authentication for ${ai_cmd}"
            fi
        else
            check_pass "AI provider command found: ${ai_cmd}"
        fi
    else
        check_error "AI provider command not found: ${ai_cmd}" "Install ${ai_cmd} or set SHIPWRIGHT_AI_PROVIDER"
    fi
}

# ─── 3. GitHub Validation ───────────────────────────────────────────────
validate_github() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        check_pass "GitHub checks skipped (--no-github)"
        return
    fi

    if ! command -v gh >/dev/null 2>&1; then
        check_warn "GitHub CLI (gh) not installed" "Install: https://cli.github.com/"
        return
    fi

    # Auth check
    if gh auth status >/dev/null 2>&1; then
        check_pass "GitHub authenticated"
    else
        check_warn "GitHub not authenticated" "Run: gh auth login"
        return
    fi

    # API connectivity with timeout
    local rate_info
    if rate_info=$(timeout 5 gh api rate_limit --jq '.rate.remaining' 2>/dev/null); then
        if [[ -n "$rate_info" ]] && [[ "$rate_info" -lt 100 ]] 2>/dev/null; then
            check_warn "GitHub API rate limit low: ${rate_info} remaining"
        else
            check_pass "GitHub API accessible (${rate_info} requests remaining)"
        fi
    else
        check_warn "GitHub API connectivity check timed out" "Pipeline will retry GitHub operations as needed"
    fi
}

# ─── 4. System Validation ───────────────────────────────────────────────
validate_system() {
    # Disk space
    local free_space_kb
    free_space_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]]; then
        if [[ "$free_space_kb" -lt 524288 ]] 2>/dev/null; then
            check_error "Critical: only $(( free_space_kb / 1024 ))MB disk space free" "Free up disk space (minimum 500MB recommended)"
        elif [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
            check_warn "Low disk space: $(( free_space_kb / 1024 ))MB free" "Recommend at least 1GB free"
        else
            check_pass "Disk space: $(( free_space_kb / 1024 ))MB free"
        fi
    fi

    # /tmp writable
    local tmp_test
    tmp_test="${TMPDIR:-/tmp}/sw-validate-test.$$"
    if echo "test" > "$tmp_test" 2>/dev/null && rm -f "$tmp_test"; then
        check_pass "Temp directory writable"
    else
        check_error "Temp directory not writable: ${TMPDIR:-/tmp}" "Check permissions on temp directory"
    fi

    # File descriptor limit
    local fd_limit
    fd_limit=$(ulimit -n 2>/dev/null || echo "0")
    if [[ "$fd_limit" -lt 256 ]] 2>/dev/null; then
        check_warn "Low file descriptor limit: ${fd_limit}" "Run: ulimit -n 1024"
    else
        check_pass "File descriptor limit: ${fd_limit}"
    fi
}

# ─── 5. Dependencies Validation ─────────────────────────────────────────
validate_dependencies() {
    # Required tools
    local required=("git" "jq")
    for tool in "${required[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "${tool} available"
        else
            check_error "${tool} not found (required)" "Install ${tool}"
        fi
    done

    # Optional tools
    local optional=("gh" "bc" "curl")
    for tool in "${optional[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "${tool} available"
        else
            check_warn "${tool} not found (optional)" "Some features may be limited without ${tool}"
        fi
    done

    # sw-loop.sh
    if [[ -x "$SCRIPT_DIR/sw-loop.sh" ]]; then
        check_pass "sw-loop.sh available"
    else
        check_error "sw-loop.sh not found or not executable" "Ensure Shipwright is properly installed"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    # Header
    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${CYAN}${BOLD}  Shipwright — Validate${RESET}"
        echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
        echo ""
    fi

    # Run all validators
    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${PURPLE}${BOLD}  TEMPLATE${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    fi
    validate_template

    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  ENVIRONMENT${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    fi
    validate_environment

    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  GITHUB${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    fi
    validate_github

    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  SYSTEM${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    fi
    validate_system

    if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  DEPENDENCIES${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    fi
    validate_dependencies

    # JSON output mode
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        jq -cn \
            --argjson errors "$ERRORS" \
            --argjson warnings "$WARNINGS" \
            --argjson checks "$CHECKS" \
            --arg pipeline "$PIPELINE_NAME" \
            --arg status "$(if [[ "$ERRORS" -gt 0 ]]; then echo "fail"; else echo "pass"; fi)" \
            '{pipeline: $pipeline, status: $status, errors: $errors, warnings: $warnings, checks: $checks}'
        if [[ "$ERRORS" -gt 0 ]]; then
            return 1
        fi
        return 0
    fi

    # Summary footer
    if [[ "$QUIET" != "true" ]]; then
        echo ""
        echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
        echo ""
        local passed=$((CHECKS - ERRORS - WARNINGS))
        echo -e "  ${GREEN}${BOLD}${passed}${RESET} passed  ${YELLOW}${BOLD}${WARNINGS}${RESET} warnings  ${RED}${BOLD}${ERRORS}${RESET} errors  ${DIM}(${CHECKS} checks)${RESET}"
        echo ""
    fi

    if [[ "$ERRORS" -gt 0 ]]; then
        if [[ "$QUIET" != "true" ]]; then
            error "Validation failed: ${ERRORS} error(s) found"
        fi
        emit_event "validate" "status=fail" "errors=$ERRORS" "warnings=$WARNINGS" "pipeline=$PIPELINE_NAME" 2>/dev/null || true
        return 1
    fi

    if [[ "$QUIET" != "true" ]]; then
        success "Validation passed"
    fi
    emit_event "validate" "status=pass" "errors=0" "warnings=$WARNINGS" "pipeline=$PIPELINE_NAME" 2>/dev/null || true
    return 0
}

main
