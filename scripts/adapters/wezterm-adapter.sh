#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  wezterm-adapter.sh — Terminal adapter for WezTerm pane management      ║
# ║                                                                          ║
# ║  Uses `wezterm cli` to spawn panes/tabs with named titles and working   ║
# ║  directories. Cross-platform.                                            ║
# ║  Sourced by cct-session.sh — exports: spawn_agent, list_agents,         ║
# ║  kill_agent, focus_agent.                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Verify wezterm CLI is available
if ! command -v wezterm &>/dev/null; then
    echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m wezterm CLI not found. Install WezTerm first." >&2
    exit 1
fi

# Track spawned pane IDs for agent management
declare -A _WEZTERM_AGENT_PANES

spawn_agent() {
    local name="$1"
    local working_dir="${2:-$PWD}"
    local command="${3:-}"

    # Resolve working_dir — tmux format won't work here
    if [[ "$working_dir" == *"pane_current_path"* || "$working_dir" == "." ]]; then
        working_dir="$PWD"
    fi

    local pane_id

    # Spawn a new pane in the current tab (split right by default)
    if [[ ${#_WEZTERM_AGENT_PANES[@]} -eq 0 ]]; then
        # First agent: create a new tab
        pane_id=$(wezterm cli spawn --cwd "$working_dir" 2>/dev/null)
    else
        # Subsequent agents: split from the first pane
        local first_pane="${_WEZTERM_AGENT_PANES[${!_WEZTERM_AGENT_PANES[*]}]}"
        pane_id=$(wezterm cli split-pane --cwd "$working_dir" --right --pane-id "${first_pane:-0}" 2>/dev/null) || \
        pane_id=$(wezterm cli split-pane --cwd "$working_dir" --bottom 2>/dev/null)
    fi

    if [[ -z "$pane_id" ]]; then
        echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m Failed to spawn WezTerm pane for '${name}'." >&2
        return 1
    fi

    # Store mapping
    _WEZTERM_AGENT_PANES["$name"]="$pane_id"

    # Set the pane title
    wezterm cli set-tab-title --pane-id "$pane_id" "$name" 2>/dev/null || true

    # Clear the pane
    wezterm cli send-text --pane-id "$pane_id" -- "clear" 2>/dev/null
    wezterm cli send-text --pane-id "$pane_id" --no-paste $'\n' 2>/dev/null || true

    # Run the command if provided
    if [[ -n "$command" ]]; then
        sleep 0.2
        wezterm cli send-text --pane-id "$pane_id" -- "$command" 2>/dev/null
        wezterm cli send-text --pane-id "$pane_id" --no-paste $'\n' 2>/dev/null || true
    fi
}

list_agents() {
    # List panes via wezterm CLI
    wezterm cli list 2>/dev/null | while IFS=$'\t' read -r pane_id title workspace rest; do
        echo "${pane_id}: ${title}"
    done

    # Also show our tracked agents
    if [[ ${#_WEZTERM_AGENT_PANES[@]} -gt 0 ]]; then
        echo ""
        echo "Tracked agents:"
        for name in "${!_WEZTERM_AGENT_PANES[@]}"; do
            echo "  ${name} → pane ${_WEZTERM_AGENT_PANES[$name]}"
        done
    fi
}

kill_agent() {
    local name="$1"
    local pane_id="${_WEZTERM_AGENT_PANES[$name]:-}"

    if [[ -z "$pane_id" ]]; then
        return 1
    fi

    wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null
    unset '_WEZTERM_AGENT_PANES[$name]'
}

focus_agent() {
    local name="$1"
    local pane_id="${_WEZTERM_AGENT_PANES[$name]:-}"

    if [[ -z "$pane_id" ]]; then
        return 1
    fi

    wezterm cli activate-pane --pane-id "$pane_id" 2>/dev/null
}
