#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet — Multi-Repo Daemon Orchestrator                            ║
# ║  Spawns daemons across repos · Fleet dashboard · Aggregate metrics     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

epoch_to_iso() {
    local epoch="$1"
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "1970-01-01T00:00:00Z"
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

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.claude-teams/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.claude-teams"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Defaults ───────────────────────────────────────────────────────────────
FLEET_DIR="$HOME/.claude-teams"
FLEET_STATE="$FLEET_DIR/fleet-state.json"
CONFIG_PATH=""

# ─── CLI Argument Parsing ──────────────────────────────────────────────────
SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="${2:-}"
            shift 2
            ;;
        --config=*)
            CONFIG_PATH="${1#--config=}"
            shift
            ;;
        --help|-h)
            SUBCOMMAND="help"
            shift
            ;;
        --period)
            METRICS_PERIOD="${2:-7}"
            shift 2
            ;;
        --period=*)
            METRICS_PERIOD="${1#--period=}"
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

METRICS_PERIOD="${METRICS_PERIOD:-7}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} ━━━${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright fleet${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}                              Start daemons for all configured repos"
    echo -e "  ${CYAN}stop${RESET}                               Stop all fleet daemons"
    echo -e "  ${CYAN}status${RESET}                             Show fleet dashboard"
    echo -e "  ${CYAN}metrics${RESET}  [--period N] [--json]     Aggregate DORA metrics across repos"
    echo -e "  ${CYAN}init${RESET}                               Generate fleet-config.json"
    echo -e "  ${CYAN}help${RESET}                               Show this help"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--config${RESET} <path>   Path to fleet-config.json ${DIM}(default: .claude/fleet-config.json)${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright fleet init${RESET}                           # Generate config"
    echo -e "  ${DIM}shipwright fleet start${RESET}                          # Start all daemons"
    echo -e "  ${DIM}shipwright fleet start --config my-fleet.json${RESET}   # Custom config"
    echo -e "  ${DIM}shipwright fleet status${RESET}                         # Fleet dashboard"
    echo -e "  ${DIM}shipwright fleet metrics --period 30${RESET}            # 30-day aggregate"
    echo -e "  ${DIM}shipwright fleet stop${RESET}                           # Stop everything"
    echo ""
    echo -e "${BOLD}CONFIG FILE${RESET}  ${DIM}(.claude/fleet-config.json)${RESET}"
    echo -e '  {
    "repos": [
      { "path": "/path/to/api", "template": "autonomous", "max_parallel": 2 },
      { "path": "/path/to/web", "template": "standard" }
    ],
    "defaults": {
      "watch_label": "ready-to-build",
      "pipeline_template": "autonomous",
      "max_parallel": 2,
      "model": "opus"
    },
    "shared_events": true
  }'
    echo ""
}

# ─── Config Loading ─────────────────────────────────────────────────────────

load_fleet_config() {
    local config_file="${CONFIG_PATH:-.claude/fleet-config.json}"

    if [[ ! -f "$config_file" ]]; then
        error "Fleet config not found: $config_file"
        info "Run ${CYAN}shipwright fleet init${RESET} to generate one"
        exit 1
    fi

    info "Loading fleet config: ${DIM}${config_file}${RESET}"

    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        error "Invalid JSON in $config_file"
        exit 1
    fi

    # Check repos array exists
    local repo_count
    repo_count=$(jq '.repos | length' "$config_file")
    if [[ "$repo_count" -eq 0 ]]; then
        error "No repos configured in $config_file"
        exit 1
    fi

    echo "$config_file"
}

# ─── Session Name ───────────────────────────────────────────────────────────

session_name_for_repo() {
    local repo_path="$1"
    local basename
    basename=$(basename "$repo_path")
    echo "shipwright-fleet-${basename}"
}

# ─── Fleet Start ────────────────────────────────────────────────────────────

fleet_start() {
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — start ━━━${RESET}"
    echo ""

    if ! command -v tmux &>/dev/null; then
        error "tmux is required for fleet mode"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required. Install: brew install jq"
        exit 1
    fi

    local config_file
    config_file=$(load_fleet_config)

    local repo_count
    repo_count=$(jq '.repos | length' "$config_file")

    # Read defaults
    local default_label default_template default_max_parallel default_model
    default_label=$(jq -r '.defaults.watch_label // "ready-to-build"' "$config_file")
    default_template=$(jq -r '.defaults.pipeline_template // "autonomous"' "$config_file")
    default_max_parallel=$(jq -r '.defaults.max_parallel // 2' "$config_file")
    default_model=$(jq -r '.defaults.model // "opus"' "$config_file")
    local shared_events
    shared_events=$(jq -r '.shared_events // true' "$config_file")

    mkdir -p "$FLEET_DIR"

    # Initialize fleet state
    local fleet_state_tmp="${FLEET_STATE}.tmp.$$"
    echo '{"started_at":"'"$(now_iso)"'","repos":{}}' > "$fleet_state_tmp"

    local started=0
    local skipped=0

    for i in $(seq 0 $((repo_count - 1))); do
        local repo_path repo_template repo_max_parallel repo_label repo_model
        repo_path=$(jq -r ".repos[$i].path" "$config_file")
        repo_template=$(jq -r ".repos[$i].template // \"$default_template\"" "$config_file")
        repo_max_parallel=$(jq -r ".repos[$i].max_parallel // $default_max_parallel" "$config_file")
        repo_label=$(jq -r ".repos[$i].watch_label // \"$default_label\"" "$config_file")
        repo_model=$(jq -r ".repos[$i].model // \"$default_model\"" "$config_file")

        local repo_name
        repo_name=$(basename "$repo_path")
        local session_name
        session_name=$(session_name_for_repo "$repo_path")

        # Validate repo path
        if [[ ! -d "$repo_path" ]]; then
            warn "Repo not found: $repo_path — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ ! -d "$repo_path/.git" ]]; then
            warn "Not a git repo: $repo_path — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Check for existing session
        if tmux has-session -t "$session_name" 2>/dev/null; then
            warn "Session already exists: ${session_name} — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Generate per-repo daemon config with overrides
        local repo_config_dir="$repo_path/.claude"
        mkdir -p "$repo_config_dir"
        local repo_daemon_config="$repo_config_dir/daemon-config.json"

        # Only generate if fleet is managing the config (don't overwrite user configs)
        local fleet_managed_config="$repo_config_dir/.fleet-daemon-config.json"
        jq -n \
            --arg label "$repo_label" \
            --argjson poll 60 \
            --argjson max_parallel "$repo_max_parallel" \
            --arg template "$repo_template" \
            --arg model "$repo_model" \
            '{
                watch_label: $label,
                poll_interval: $poll,
                max_parallel: $max_parallel,
                pipeline_template: $template,
                model: $model,
                skip_gates: true,
                on_success: { remove_label: $label, add_label: "pipeline/complete" },
                on_failure: { add_label: "pipeline/failed", comment_log_lines: 50 }
            }' > "$fleet_managed_config"

        # Determine which config the daemon should use
        local daemon_config_flag=""
        if [[ -f "$repo_daemon_config" ]]; then
            # Use existing user config — don't override
            daemon_config_flag="--config $repo_daemon_config"
        else
            daemon_config_flag="--config $fleet_managed_config"
        fi

        # Spawn daemon in detached tmux session
        tmux new-session -d -s "$session_name" \
            "cd '$repo_path' && '$SCRIPT_DIR/cct-daemon.sh' start $daemon_config_flag"

        # Record in fleet state
        local tmp2="${fleet_state_tmp}.2"
        jq --arg repo "$repo_name" \
           --arg path "$repo_path" \
           --arg session "$session_name" \
           --arg template "$repo_template" \
           --argjson max_parallel "$repo_max_parallel" \
           --arg started_at "$(now_iso)" \
           '.repos[$repo] = {
               path: $path,
               session: $session,
               template: $template,
               max_parallel: $max_parallel,
               started_at: $started_at
           }' "$fleet_state_tmp" > "$tmp2" && mv "$tmp2" "$fleet_state_tmp"

        success "Started ${CYAN}${repo_name}${RESET} → tmux session ${DIM}${session_name}${RESET}"
        started=$((started + 1))
    done

    # Atomic write of fleet state
    mv "$fleet_state_tmp" "$FLEET_STATE"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Fleet: ${GREEN}${started} started${RESET}"
    [[ "$skipped" -gt 0 ]] && echo -e "         ${YELLOW}${skipped} skipped${RESET}"
    echo ""
    echo -e "  ${DIM}View dashboard:${RESET}  ${CYAN}shipwright fleet status${RESET}"
    echo -e "  ${DIM}View metrics:${RESET}    ${CYAN}shipwright fleet metrics${RESET}"
    echo -e "  ${DIM}Stop all:${RESET}        ${CYAN}shipwright fleet stop${RESET}"
    echo ""

    emit_event "fleet.started" "repos=$started" "skipped=$skipped"
}

# ─── Fleet Stop ─────────────────────────────────────────────────────────────

fleet_stop() {
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — stop ━━━${RESET}"
    echo ""

    if [[ ! -f "$FLEET_STATE" ]]; then
        error "No fleet state found — is the fleet running?"
        info "Start with: ${CYAN}shipwright fleet start${RESET}"
        exit 1
    fi

    local repo_names
    repo_names=$(jq -r '.repos | keys[]' "$FLEET_STATE" 2>/dev/null || true)

    if [[ -z "$repo_names" ]]; then
        warn "No repos in fleet state"
        rm -f "$FLEET_STATE"
        return 0
    fi

    local stopped=0
    while IFS= read -r repo_name; do
        local session_name
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        local repo_path
        repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE")

        # Try graceful shutdown via the daemon's shutdown flag
        local daemon_dir="$HOME/.claude-teams"
        local shutdown_flag="$daemon_dir/daemon.shutdown"

        # Send shutdown signal to the daemon process inside the tmux session
        if tmux has-session -t "$session_name" 2>/dev/null; then
            # Send Ctrl-C to the tmux session for graceful shutdown
            tmux send-keys -t "$session_name" C-c 2>/dev/null || true
            sleep 1

            # Kill the session if still alive
            if tmux has-session -t "$session_name" 2>/dev/null; then
                tmux kill-session -t "$session_name" 2>/dev/null || true
            fi
            success "Stopped ${CYAN}${repo_name}${RESET}"
            stopped=$((stopped + 1))
        else
            warn "Session not found: ${session_name} — already stopped?"
        fi

        # Clean up fleet-managed config
        local fleet_managed_config="$repo_path/.claude/.fleet-daemon-config.json"
        rm -f "$fleet_managed_config" 2>/dev/null || true

    done <<< "$repo_names"

    rm -f "$FLEET_STATE"

    echo ""
    echo -e "  Fleet: ${GREEN}${stopped} stopped${RESET}"
    echo ""

    emit_event "fleet.stopped" "repos=$stopped"
}

# ─── Fleet Status ───────────────────────────────────────────────────────────

fleet_status() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — dashboard ━━━${RESET}"
    echo -e "  ${DIM}$(now_iso)${RESET}"
    echo ""

    if [[ ! -f "$FLEET_STATE" ]]; then
        warn "No fleet running"
        info "Start with: ${CYAN}shipwright fleet start${RESET}"
        return 0
    fi

    local repo_names
    repo_names=$(jq -r '.repos | keys[]' "$FLEET_STATE" 2>/dev/null || true)

    if [[ -z "$repo_names" ]]; then
        warn "Fleet state is empty"
        return 0
    fi

    # Header
    printf "  ${BOLD}%-20s %-10s %-10s %-10s %-10s %-20s${RESET}\n" \
        "REPO" "STATUS" "ACTIVE" "QUEUED" "DONE" "LAST POLL"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────────────${RESET}"

    while IFS= read -r repo_name; do
        local session_name repo_path
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE")

        # Check tmux session
        local status_icon status_text
        if tmux has-session -t "$session_name" 2>/dev/null; then
            status_icon="${GREEN}●${RESET}"
            status_text="running"
        else
            status_icon="${RED}●${RESET}"
            status_text="stopped"
        fi

        # Try to read daemon state from the repo's daemon state file
        local active="-" queued="-" done="-" last_poll="-"
        local daemon_state="$HOME/.claude-teams/daemon-state.json"
        if [[ -f "$daemon_state" ]]; then
            active=$(jq -r '.active_jobs // 0' "$daemon_state" 2>/dev/null || echo "-")
            queued=$(jq -r '.queued // 0' "$daemon_state" 2>/dev/null || echo "-")
            done=$(jq -r '.completed // 0' "$daemon_state" 2>/dev/null || echo "-")
            last_poll=$(jq -r '.last_poll // "-"' "$daemon_state" 2>/dev/null || echo "-")
            # Shorten timestamp
            if [[ "$last_poll" != "-" && "$last_poll" != "null" ]]; then
                last_poll="${last_poll:11:8}"
            else
                last_poll="-"
            fi
        fi

        printf "  ${status_icon} %-19s %-10s %-10s %-10s %-10s %-20s\n" \
            "$repo_name" "$status_text" "$active" "$queued" "$done" "$last_poll"

    done <<< "$repo_names"

    echo ""

    # Summary
    local total running=0
    total=$(echo "$repo_names" | wc -l | tr -d ' ')
    while IFS= read -r repo_name; do
        local session_name
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        if tmux has-session -t "$session_name" 2>/dev/null; then
            running=$((running + 1))
        fi
    done <<< "$repo_names"

    echo -e "  ${BOLD}Total:${RESET} ${total} repos  ${GREEN}${running} running${RESET}  ${DIM}$((total - running)) stopped${RESET}"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Fleet Metrics ──────────────────────────────────────────────────────────

fleet_metrics() {
    local period_days="$METRICS_PERIOD"
    local json_output="$JSON_OUTPUT"

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events file found at $EVENTS_FILE"
        info "Events are generated when running ${CYAN}shipwright daemon${RESET} or ${CYAN}shipwright pipeline${RESET}"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required. Install: brew install jq"
        exit 1
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (period_days * 86400) ))

    # Filter events within period
    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch)" "$EVENTS_FILE" 2>/dev/null)

    if [[ -z "$period_events" ]]; then
        warn "No events in the last ${period_days} day(s)"
        return 0
    fi

    # Get unique repos from events (fall back to "default" if no repo field)
    local repos
    repos=$(echo "$period_events" | jq -r '.repo // "default"' | sort -u)

    if [[ "$json_output" == "true" ]]; then
        # JSON output: per-repo metrics
        local json_result='{"period":"'"${period_days}d"'","repos":{}}'

        while IFS= read -r repo; do
            local repo_events
            if [[ "$repo" == "default" ]]; then
                repo_events=$(echo "$period_events" | jq -c 'select(.repo == null or .repo == "default")')
            else
                repo_events=$(echo "$period_events" | jq -c --arg r "$repo" 'select(.repo == $r)')
            fi

            [[ -z "$repo_events" ]] && continue

            local completed successes failures
            completed=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
            successes=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
            failures=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

            local deploy_freq="0"
            [[ "$period_days" -gt 0 ]] && deploy_freq=$(echo "$successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')

            local cfr="0"
            [[ "$completed" -gt 0 ]] && cfr=$(echo "$failures $completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

            json_result=$(echo "$json_result" | jq \
                --arg repo "$repo" \
                --argjson completed "$completed" \
                --argjson successes "$successes" \
                --argjson failures "$failures" \
                --argjson deploy_freq "${deploy_freq}" \
                --arg cfr "$cfr" \
                '.repos[$repo] = {
                    completed: $completed,
                    successes: $successes,
                    failures: $failures,
                    deploy_freq_per_week: $deploy_freq,
                    change_failure_rate_pct: ($cfr | tonumber)
                }')
        done <<< "$repos"

        # Aggregate totals
        local total_completed total_successes total_failures
        total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
        total_successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
        total_failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

        json_result=$(echo "$json_result" | jq \
            --argjson total "$total_completed" \
            --argjson successes "$total_successes" \
            --argjson failures "$total_failures" \
            '.aggregate = { completed: $total, successes: $successes, failures: $failures }')

        echo "$json_result" | jq .
        return 0
    fi

    # Dashboard output
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Fleet Metrics ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Period: last ${period_days} day(s)    ${DIM}$(now_iso)${RESET}"
    echo ""

    # Per-repo breakdown
    echo -e "${BOLD}  PER-REPO BREAKDOWN${RESET}"
    printf "  %-20s %8s %8s %8s %12s %8s\n" "REPO" "DONE" "PASS" "FAIL" "FREQ/wk" "CFR"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}"

    local grand_completed=0 grand_successes=0 grand_failures=0

    while IFS= read -r repo; do
        local repo_events
        if [[ "$repo" == "default" ]]; then
            repo_events=$(echo "$period_events" | jq -c 'select(.repo == null or .repo == "default")')
        else
            repo_events=$(echo "$period_events" | jq -c --arg r "$repo" 'select(.repo == $r)')
        fi

        [[ -z "$repo_events" ]] && continue

        local completed successes failures
        completed=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
        successes=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
        failures=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

        local deploy_freq="0"
        [[ "$period_days" -gt 0 ]] && deploy_freq=$(echo "$successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')

        local cfr="0"
        [[ "$completed" -gt 0 ]] && cfr=$(echo "$failures $completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

        printf "  %-20s %8s %8s %8s %12s %7s%%\n" \
            "$repo" "$completed" "${successes}" "${failures}" "$deploy_freq" "$cfr"

        grand_completed=$((grand_completed + completed))
        grand_successes=$((grand_successes + successes))
        grand_failures=$((grand_failures + failures))
    done <<< "$repos"

    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}"

    local grand_freq="0"
    [[ "$period_days" -gt 0 ]] && grand_freq=$(echo "$grand_successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')
    local grand_cfr="0"
    [[ "$grand_completed" -gt 0 ]] && grand_cfr=$(echo "$grand_failures $grand_completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

    printf "  ${BOLD}%-20s %8s %8s %8s %12s %7s%%${RESET}\n" \
        "TOTAL" "$grand_completed" "$grand_successes" "$grand_failures" "$grand_freq" "$grand_cfr"
    echo ""

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Fleet Init ─────────────────────────────────────────────────────────────

fleet_init() {
    local config_dir=".claude"
    local config_file="${config_dir}/fleet-config.json"

    if [[ -f "$config_file" ]]; then
        warn "Config file already exists: $config_file"
        info "Delete it first if you want to regenerate"
        return 0
    fi

    mkdir -p "$config_dir"

    # Scan for sibling git repos
    local parent_dir
    parent_dir=$(dirname "$(pwd)")
    local detected_repos=()

    while IFS= read -r dir; do
        [[ -d "$dir/.git" ]] && detected_repos+=("$dir")
    done < <(find "$parent_dir" -maxdepth 1 -type d ! -name ".*" 2>/dev/null | sort)

    # Build repos array JSON
    local repos_json="[]"
    for repo in "${detected_repos[@]}"; do
        repos_json=$(echo "$repos_json" | jq --arg path "$repo" '. + [{"path": $path}]')
    done

    jq -n --argjson repos "$repos_json" '{
        repos: $repos,
        defaults: {
            watch_label: "ready-to-build",
            pipeline_template: "autonomous",
            max_parallel: 2,
            model: "opus"
        },
        shared_events: true
    }' > "$config_file"

    success "Generated fleet config: ${config_file}"
    echo ""
    echo -e "  Detected ${CYAN}${#detected_repos[@]}${RESET} repo(s) in parent directory"
    echo ""

    if [[ "${#detected_repos[@]}" -gt 0 ]]; then
        for repo in "${detected_repos[@]}"; do
            echo -e "    ${DIM}•${RESET} $(basename "$repo")  ${DIM}$repo${RESET}"
        done
        echo ""
    fi

    echo -e "${DIM}Edit the config to add/remove repos and set overrides, then run:${RESET}"
    echo -e "  ${CYAN}shipwright fleet start${RESET}"
}

# ─── Command Router ─────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)
        fleet_start
        ;;
    stop)
        fleet_stop
        ;;
    status)
        fleet_status
        ;;
    metrics)
        fleet_metrics
        ;;
    init)
        fleet_init
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac
