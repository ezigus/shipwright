#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-session.sh — Launch a Claude Code team session in a new tmux window║
# ║                                                                          ║
# ║  Uses new-window (NOT split-window) to avoid the tmux send-keys race    ║
# ║  condition that affects 4+ agents. See KNOWN-ISSUES.md for details.     ║
# ║                                                                          ║
# ║  Supports --template to scaffold from a team template and --terminal    ║
# ║  to select a terminal adapter (tmux, iterm2, wezterm).                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Parse Arguments ────────────────────────────────────────────────────────

TEAM_NAME=""
TEMPLATE_NAME=""
TERMINAL_ADAPTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template|-t)
            TEMPLATE_NAME="${2:-}"
            [[ -z "$TEMPLATE_NAME" ]] && { error "Missing template name after --template"; exit 1; }
            shift 2
            ;;
        --terminal)
            TERMINAL_ADAPTER="${2:-}"
            [[ -z "$TERMINAL_ADAPTER" ]] && { error "Missing adapter name after --terminal"; exit 1; }
            shift 2
            ;;
        --help|-h)
            echo -e "${CYAN}${BOLD}cct session${RESET} — Create a new team session"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  cct session [name] [--template <name>] [--terminal <adapter>]"
            echo ""
            echo -e "${BOLD}OPTIONS${RESET}"
            echo -e "  ${CYAN}--template, -t${RESET} <name>   Use a team template (see: cct templates list)"
            echo -e "  ${CYAN}--terminal${RESET} <adapter>    Terminal adapter: tmux (default), iterm2, wezterm"
            echo ""
            echo -e "${BOLD}EXAMPLES${RESET}"
            echo -e "  ${DIM}cct session refactor${RESET}"
            echo -e "  ${DIM}cct session my-feature --template feature-dev${RESET}"
            echo -e "  ${DIM}cct session my-feature --terminal iterm2${RESET}"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            # Positional: team name
            [[ -z "$TEAM_NAME" ]] && TEAM_NAME="$1" || { error "Unexpected argument: $1"; exit 1; }
            shift
            ;;
    esac
done

TEAM_NAME="${TEAM_NAME:-team-$(date +%s)}"
WINDOW_NAME="claude-${TEAM_NAME}"

# ─── Template Loading ───────────────────────────────────────────────────────

TEMPLATE_FILE=""
TEMPLATE_LAYOUT=""
TEMPLATE_DESC=""
TEMPLATE_AGENTS=()  # Populated as "name|role|focus" entries

if [[ -n "$TEMPLATE_NAME" ]]; then
    # Search for template: user dir first, then repo dir
    USER_TEMPLATES_DIR="${HOME}/.claude-teams/templates"
    REPO_TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../tmux/templates" 2>/dev/null && pwd)" || REPO_TEMPLATES_DIR=""

    TEMPLATE_NAME="${TEMPLATE_NAME%.json}"

    if [[ -f "$USER_TEMPLATES_DIR/${TEMPLATE_NAME}.json" ]]; then
        TEMPLATE_FILE="$USER_TEMPLATES_DIR/${TEMPLATE_NAME}.json"
    elif [[ -n "$REPO_TEMPLATES_DIR" && -f "$REPO_TEMPLATES_DIR/${TEMPLATE_NAME}.json" ]]; then
        TEMPLATE_FILE="$REPO_TEMPLATES_DIR/${TEMPLATE_NAME}.json"
    else
        error "Template '${TEMPLATE_NAME}' not found."
        echo -e "  Run ${DIM}cct templates list${RESET} to see available templates."
        exit 1
    fi

    info "Loading template: ${PURPLE}${BOLD}${TEMPLATE_NAME}${RESET}"

    # Parse template with python3 (available on macOS)
    if command -v python3 &>/dev/null; then
        TEMPLATE_DESC="$(python3 -c "
import json
with open('$TEMPLATE_FILE') as f:
    data = json.load(f)
print(data.get('description', ''))
")"
        TEMPLATE_LAYOUT="$(python3 -c "
import json
with open('$TEMPLATE_FILE') as f:
    data = json.load(f)
print(data.get('layout', 'tiled'))
")"
        while IFS= read -r line; do
            [[ -n "$line" ]] && TEMPLATE_AGENTS+=("$line")
        done < <(python3 -c "
import json
with open('$TEMPLATE_FILE') as f:
    data = json.load(f)
for a in data.get('agents', []):
    print(a['name'] + '|' + a.get('role','') + '|' + a.get('focus',''))
")
    else
        error "python3 is required for template parsing."
        exit 1
    fi

    echo -e "  ${DIM}${TEMPLATE_DESC}${RESET}"
    echo -e "  ${DIM}Agents: ${#TEMPLATE_AGENTS[@]}  Layout: ${TEMPLATE_LAYOUT}${RESET}"
fi

# ─── Resolve Terminal Adapter ───────────────────────────────────────────────

# Auto-detect if not specified
if [[ -z "$TERMINAL_ADAPTER" ]]; then
    TERMINAL_ADAPTER="tmux"
fi

ADAPTER_FILE="$SCRIPT_DIR/adapters/${TERMINAL_ADAPTER}-adapter.sh"
if [[ -f "$ADAPTER_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ADAPTER_FILE"
else
    # Default to inline tmux behavior (backwards compatible)
    if [[ "$TERMINAL_ADAPTER" != "tmux" ]]; then
        error "Terminal adapter '${TERMINAL_ADAPTER}' not found."
        echo -e "  Available: tmux (default), iterm2, wezterm"
        echo -e "  Adapter dir: ${DIM}${SCRIPT_DIR}/adapters/${RESET}"
        exit 1
    fi
fi

# ─── Create Session (tmux default path) ─────────────────────────────────────

if [[ "$TERMINAL_ADAPTER" == "tmux" && ! -f "$ADAPTER_FILE" ]]; then
    # Inline tmux path — original behavior (adapter not required for tmux)

    # Check if a window with this name already exists
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        warn "Window '${WINDOW_NAME}' already exists. Switching to it."
        tmux select-window -t "$WINDOW_NAME"
        exit 0
    fi

    info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET}"

    # Create a new window (not split-window — avoids race condition #23615)
    tmux new-window -n "$WINDOW_NAME" -c "#{pane_current_path}"

    # Set the pane title so the overlay shows the team name
    tmux send-keys -t "$WINDOW_NAME" "printf '\\033]2;${TEAM_NAME}-lead\\033\\\\'" Enter

    sleep 0.2
    tmux send-keys -t "$WINDOW_NAME" "clear" Enter

    # ─── Template: Create Agent Panes ────────────────────────────────────────
    if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
        info "Scaffolding ${#TEMPLATE_AGENTS[@]} agent panes..."

        for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
            IFS='|' read -r aname arole afocus <<< "$agent_entry"

            # Split the window to create a new pane
            tmux split-window -t "$WINDOW_NAME" -c "#{pane_current_path}"
            sleep 0.1

            # Set the pane title to the agent name
            tmux send-keys -t "$WINDOW_NAME" "printf '\\033]2;${TEAM_NAME}-${aname}\\033\\\\'" Enter
            sleep 0.1
            tmux send-keys -t "$WINDOW_NAME" "clear" Enter
        done

        # Apply the layout from the template
        tmux select-layout -t "$WINDOW_NAME" "${TEMPLATE_LAYOUT:-tiled}" 2>/dev/null || true

        # Select the first pane (leader)
        tmux select-pane -t "$WINDOW_NAME.0"
    fi

else
    # ─── Adapter-based session creation ──────────────────────────────────────

    if type -t spawn_agent &>/dev/null; then
        info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET} ${DIM}(${TERMINAL_ADAPTER})${RESET}"

        # Spawn leader
        spawn_agent "${TEAM_NAME}-lead" "#{pane_current_path}" ""

        # Spawn template agents if provided
        if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
            info "Scaffolding ${#TEMPLATE_AGENTS[@]} agents..."
            for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
                IFS='|' read -r aname arole afocus <<< "$agent_entry"
                spawn_agent "${TEAM_NAME}-${aname}" "#{pane_current_path}" ""
            done
        fi
    else
        error "Adapter '${TERMINAL_ADAPTER}' loaded but spawn_agent() not found."
        exit 1
    fi
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
success "Team session ${CYAN}${BOLD}${TEAM_NAME}${RESET} ready!"

if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}Team from template ${PURPLE}${TEMPLATE_NAME}${RESET}${BOLD}:${RESET}"
    echo -e "  ${CYAN}${BOLD}lead${RESET}  ${DIM}— Team coordinator${RESET}"
    for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
        IFS='|' read -r aname arole afocus <<< "$agent_entry"
        echo -e "  ${PURPLE}${BOLD}${aname}${RESET}  ${DIM}— ${arole}${RESET}"
    done
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Switch to window ${DIM}${WINDOW_NAME}${RESET}"
    echo -e "  ${CYAN}2.${RESET} Start ${DIM}claude${RESET} in the lead pane (top-left)"
    echo -e "  ${CYAN}3.${RESET} Ask Claude to use the team — agents are ready in their panes"
else
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Switch to window ${DIM}${WINDOW_NAME}${RESET}  ${DIM}(prefix + $(tmux list-windows -F '#I #W' | grep "$WINDOW_NAME" | cut -d' ' -f1))${RESET}"
    echo -e "  ${CYAN}2.${RESET} Start Claude Code:"
    echo -e "     ${DIM}claude${RESET}"
    echo -e "  ${CYAN}3.${RESET} Ask Claude to create a team:"
    echo -e "     ${DIM}\"Create a team with 2 agents to refactor the auth module\"${RESET}"
fi

echo ""
echo -e "${PURPLE}${BOLD}Tip:${RESET} For file isolation between agents, use git worktrees:"
echo -e "  ${DIM}git worktree add ../project-${TEAM_NAME} -b ${TEAM_NAME}${RESET}"
echo -e "  Then launch Claude inside the worktree directory."
echo ""
echo -e "${DIM}Settings: ~/.claude/settings.json (see settings.json.template)${RESET}"
echo -e "${DIM}Keybinding: prefix + T re-runs this command${RESET}"
