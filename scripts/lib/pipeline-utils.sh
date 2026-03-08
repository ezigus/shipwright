#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-utils.sh — Pure utility/formatting functions                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_UTILS_LOADED:-}" ]] && return 0
_PIPELINE_UTILS_LOADED=1

VERSION="3.2.4"

# Parse coverage percentage from test output — multi-framework patterns
# Usage: parse_coverage_from_output <log_file>
# Outputs coverage percentage or empty string
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    local cov=""
    # Jest/Istanbul: "Statements : 85.5%"
    cov=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # Istanbul table: "All files | 85.5"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # pytest-cov: "TOTAL    500    75    85%"
    [[ -z "$cov" ]] && cov=$(grep -oE 'TOTAL\s+[0-9]+\s+[0-9]+\s+[0-9]+%' "$log_file" 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' | tail -1 || true)
    # Vitest: "All files  |  85.5  |"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+\s*\|' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Go coverage: "coverage: 85.5% of statements"
    [[ -z "$cov" ]] && cov=$(grep -oE 'coverage:\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo tarpaulin: "85.50% coverage"
    [[ -z "$cov" ]] && cov=$(grep -oE '[0-9.]+%\s*coverage' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Generic: "Coverage: 85.5%"
    [[ -z "$cov" ]] && cov=$(grep -oiE 'coverage:?\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    echo "$cov"
}

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# Rotate event log if needed (standalone mode — daemon has its own rotation in poll loop)
rotate_event_log_if_needed() {
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local max_lines=10000
    [[ ! -f "$events_file" ]] && return
    local lines
    lines=$(wc -l < "$events_file" 2>/dev/null || true)
    lines="${lines:-0}"
    if [[ "$lines" -gt "$max_lines" ]]; then
        local tmp="${events_file}.rotating"
        if tail -5000 "$events_file" > "$tmp" 2>/dev/null && mv "$tmp" "$events_file" 2>/dev/null; then
            info "Rotated events.jsonl: ${lines} -> 5000 lines"
        fi
    fi
}

# ─── Token / Cost Parsing ─────────────────────────────────────────────────
parse_claude_tokens() {
    local log_file="$1"
    local input_tok output_tok
    input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
    output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${input_tok:-0} ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${output_tok:-0} ))
}

# Estimate pipeline cost using historical averages from completed pipelines.
# Falls back to per-stage estimates when no history exists.
estimate_pipeline_cost() {
    local stages="$1"
    local stage_count
    stage_count=$(echo "$stages" | jq 'length' 2>/dev/null || echo "6")
    [[ ! "$stage_count" =~ ^[0-9]+$ ]] && stage_count=6

    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local avg_input=0 avg_output=0
    if [[ -f "$events_file" ]]; then
        local hist
        hist=$(grep '"type":"pipeline.completed"' "$events_file" 2>/dev/null | tail -10)
        if [[ -n "$hist" ]]; then
            avg_input=$(echo "$hist" | jq -s -r '[.[] | .input_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
            avg_output=$(echo "$hist" | jq -s -r '[.[] | .output_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
        fi
    fi
    [[ ! "$avg_input" =~ ^[0-9]+$ ]] && avg_input=0
    [[ ! "$avg_output" =~ ^[0-9]+$ ]] && avg_output=0

    # Fall back to reasonable per-stage estimates only if no history
    if [[ "$avg_input" -eq 0 ]]; then
        avg_input=$(( stage_count * 8000 ))   # More realistic: ~8K input per stage
        avg_output=$(( stage_count * 4000 ))  # ~4K output per stage
    fi

    echo "{\"input_tokens\":${avg_input},\"output_tokens\":${avg_output}}"
}

# ─── Goal Compaction ─────────────────────────────────────────────────────

_pipeline_compact_goal() {
    local goal="$1"
    local plan_file="${2:-}"
    local design_file="${3:-}"
    local compact="$goal"

    # Include plan summary (first 20 lines only)
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        compact="${compact}

## Plan Summary
$(head -20 "$plan_file" 2>/dev/null || true)
[... full plan in .claude/pipeline-artifacts/plan.md]"
    fi

    # Include design key decisions only (grep for headers)
    if [[ -n "$design_file" && -f "$design_file" ]]; then
        compact="${compact}

## Key Design Decisions
$(grep -E '^#{1,3} ' "$design_file" 2>/dev/null | head -10 || true)
[... full design in .claude/pipeline-artifacts/design.md]"
    fi

    echo "$compact"
}

load_composed_pipeline() {
    local spec_file="$1"
    [[ ! -f "$spec_file" ]] && return 1

    # Read enabled stages from composed spec
    local composed_stages
    composed_stages=$(jq -r '.stages // [] | .[] | .id' "$spec_file" 2>/dev/null) || return 1
    [[ -z "$composed_stages" ]] && return 1

    # Override enabled stages
    COMPOSED_STAGES="$composed_stages"

    # Override per-stage settings
    local build_max
    build_max=$(jq -r '.stages[] | select(.id=="build") | .max_iterations // ""' "$spec_file" 2>/dev/null) || true
    [[ -n "$build_max" && "$build_max" != "null" ]] && COMPOSED_BUILD_ITERATIONS="$build_max"

    emit_event "pipeline.composed_loaded" "stages=$(echo "$composed_stages" | wc -l | tr -d ' ')"
    return 0
}

# ─── Notification Helpers ──────────────────────────────────────────────────

notify() {
    local title="$1" message="$2" level="${3:-info}"
    local emoji
    case "$level" in
        success) emoji="✅" ;;
        error)   emoji="❌" ;;
        warn)    emoji="⚠️" ;;
        *)       emoji="🔔" ;;
    esac

    # Slack webhook
    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        local payload
        payload=$(jq -n \
            --arg text "${emoji} *${title}*\n${message}" \
            '{text: $text}')
        curl -sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10 2>/dev/null || echo 10)" --max-time "$(_config_get_int "network.max_time" 60 2>/dev/null || echo 60)" -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-}"
    if [[ -n "$_webhook_url" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" --arg pipeline "${PIPELINE_NAME:-}" \
            --arg goal "${GOAL:-}" --arg stage "${CURRENT_STAGE_ID:-}" \
            '{title:$title, message:$message, level:$level, pipeline:$pipeline, goal:$goal, stage:$stage}')
        curl -sf --connect-timeout 10 --max-time 30 -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$_webhook_url" >/dev/null 2>&1 || true
    fi
}
