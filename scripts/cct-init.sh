#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct init — One-command tmux setup (no prompts)                        ║
# ║                                                                          ║
# ║  Installs tmux config, overlay, and templates. No interactive prompts,  ║
# ║  no hooks, no Claude Code settings — just tmux config.                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }

echo ""
echo -e "${CYAN}${BOLD}cct init${RESET} — Quick tmux setup"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# ─── tmux.conf ────────────────────────────────────────────────────────────────
if [[ -f "$HOME/.tmux.conf" ]]; then
    cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
    warn "Backed up existing ~/.tmux.conf → ~/.tmux.conf.bak"
fi
cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
success "Installed ~/.tmux.conf"

# ─── Overlay ──────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.tmux"
cp "$REPO_DIR/tmux/claude-teams-overlay.conf" "$HOME/.tmux/claude-teams-overlay.conf"
success "Installed ~/.tmux/claude-teams-overlay.conf"

# ─── Templates ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.claude-teams/templates"
for tpl in "$REPO_DIR"/tmux/templates/*.json; do
    [[ -f "$tpl" ]] || continue
    cp "$tpl" "$HOME/.claude-teams/templates/$(basename "$tpl")"
done
success "Installed templates → ~/.claude-teams/templates/"

# ─── Reload tmux if inside a session ──────────────────────────────────────────
if [[ -n "${TMUX:-}" ]]; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null && \
        success "Reloaded tmux config" || \
        warn "Could not reload tmux config (reload manually with prefix + r)"
fi

# ─── Quick-start instructions ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Done!${RESET} tmux is configured for Claude Code Teams."
echo ""
echo -e "${BOLD}Quick start:${RESET}"
if [[ -z "${TMUX:-}" ]]; then
    echo -e "  ${DIM}1.${RESET} tmux new -s dev"
    echo -e "  ${DIM}2.${RESET} cct session my-feature --template feature-dev"
else
    echo -e "  ${DIM}1.${RESET} cct session my-feature --template feature-dev"
fi
echo ""
echo -e "${BOLD}Layout keybindings:${RESET}"
echo -e "  ${CYAN}prefix + M-1${RESET}  main-horizontal (leader 65% left)"
echo -e "  ${CYAN}prefix + M-2${RESET}  main-vertical (leader 60% top)"
echo -e "  ${CYAN}prefix + M-3${RESET}  tiled (equal sizes)"
echo ""
