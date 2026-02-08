#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright init — One-command tmux setup + optional deploy configuration      ║
# ║                                                                          ║
# ║  Installs tmux config, overlay, and templates. No interactive prompts,  ║
# ║  no hooks, no Claude Code settings — just tmux config.                  ║
# ║                                                                          ║
# ║  --deploy  Detect platform and generate deployed.json template          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
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

# ─── Flag parsing ───────────────────────────────────────────────────────────
DEPLOY_SETUP=false
DEPLOY_PLATFORM=""
SKIP_CLAUDE_MD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)
            DEPLOY_SETUP=true
            shift
            ;;
        --platform)
            DEPLOY_PLATFORM="${2:-}"
            [[ -z "$DEPLOY_PLATFORM" ]] && { error "Missing value for --platform"; exit 1; }
            shift 2
            ;;
        --no-claude-md)
            SKIP_CLAUDE_MD=true
            shift
            ;;
        --help|-h)
            echo "Usage: shipwright init [--deploy] [--platform vercel|fly|railway|docker] [--no-claude-md]"
            echo ""
            echo "Options:"
            echo "  --deploy             Detect deploy platform and generate deployed.json"
            echo "  --platform PLATFORM  Skip detection, use specified platform"
            echo "  --no-claude-md       Skip creating .claude/CLAUDE.md"
            echo "  --help, -h           Show this help"
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            shift
            ;;
    esac
done

echo ""
echo -e "${CYAN}${BOLD}shipwright init${RESET} — Quick tmux setup"
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

# ─── CLAUDE.md — Agent instructions ──────────────────────────────────────────
CLAUDE_MD_SRC="$REPO_DIR/claude-code/CLAUDE.md.shipwright"
CLAUDE_MD_DST=".claude/CLAUDE.md"

if [[ "$SKIP_CLAUDE_MD" == "false" && -f "$CLAUDE_MD_SRC" ]]; then
    if [[ -f "$CLAUDE_MD_DST" ]]; then
        # Check if it already contains Shipwright instructions
        if grep -q "Shipwright" "$CLAUDE_MD_DST" 2>/dev/null; then
            info "CLAUDE.md already contains Shipwright instructions — skipping"
        else
            # Append Shipwright section to existing CLAUDE.md
            {
                echo ""
                echo "---"
                echo ""
                cat "$CLAUDE_MD_SRC"
            } >> "$CLAUDE_MD_DST"
            success "Appended Shipwright instructions to ${CLAUDE_MD_DST}"
        fi
    else
        mkdir -p ".claude"
        cp "$CLAUDE_MD_SRC" "$CLAUDE_MD_DST"
        success "Created ${CLAUDE_MD_DST} with Shipwright agent instructions"
    fi
fi

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
    echo -e "  ${DIM}2.${RESET} shipwright session my-feature --template feature-dev"
else
    echo -e "  ${DIM}1.${RESET} shipwright session my-feature --template feature-dev"
fi
echo ""
echo -e "${BOLD}Layout keybindings:${RESET}"
echo -e "  ${CYAN}prefix + M-1${RESET}  main-horizontal (leader 65% left)"
echo -e "  ${CYAN}prefix + M-2${RESET}  main-vertical (leader 60% top)"
echo -e "  ${CYAN}prefix + M-3${RESET}  tiled (equal sizes)"
echo ""

# ─── Deploy setup (--deploy) ─────────────────────────────────────────────────
[[ "$DEPLOY_SETUP" == "false" ]] && exit 0

echo -e "${CYAN}${BOLD}Deploy Setup${RESET}"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# Platform detection
detect_deploy_platform() {
    local detected=""

    for adapter_file in "$ADAPTERS_DIR"/*-deploy.sh; do
        [[ -f "$adapter_file" ]] || continue
        # Source the adapter in a subshell to get detection
        if ( source "$adapter_file" && detect_platform ); then
            local name
            name=$(basename "$adapter_file" | sed 's/-deploy\.sh$//')
            if [[ -n "$detected" ]]; then
                detected="$detected $name"
            else
                detected="$name"
            fi
        fi
    done

    echo "$detected"
}

if [[ -n "$DEPLOY_PLATFORM" ]]; then
    # User specified --platform, validate it
    if [[ ! -f "$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh" ]]; then
        error "Unknown platform: $DEPLOY_PLATFORM"
        echo -e "  Available: vercel, fly, railway, docker"
        exit 1
    fi
    info "Using specified platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
else
    info "Detecting deploy platform..."
    detected=$(detect_deploy_platform)

    if [[ -z "$detected" ]]; then
        warn "No platform detected in current directory"
        echo ""
        echo -e "  Supported platforms:"
        echo -e "    ${CYAN}vercel${RESET}   — vercel.json or .vercel/"
        echo -e "    ${CYAN}fly${RESET}      — fly.toml"
        echo -e "    ${CYAN}railway${RESET}  — railway.toml or .railway/"
        echo -e "    ${CYAN}docker${RESET}   — Dockerfile or docker-compose.yml"
        echo ""
        echo -e "  Specify manually: ${DIM}shipwright init --deploy --platform vercel${RESET}"
        exit 1
    fi

    # If multiple platforms detected, use the first and warn
    platform_count=$(echo "$detected" | wc -w | tr -d ' ')
    DEPLOY_PLATFORM=$(echo "$detected" | awk '{print $1}')

    if [[ "$platform_count" -gt 1 ]]; then
        warn "Multiple platforms detected: ${BOLD}${detected}${RESET}"
        info "Using: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
        echo -e "  ${DIM}Override with: shipwright init --deploy --platform <name>${RESET}"
        echo ""
    else
        success "Detected platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
    fi

    # Confirm with user
    read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Configure deploy for ${BOLD}${DEPLOY_PLATFORM}${RESET}? [Y/n] ")" confirm
    if [[ "${confirm,,}" == "n" ]]; then
        info "Aborted. Use --platform to specify manually."
        exit 0
    fi
fi

# Source the adapter to get command values
ADAPTER_FILE="$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh"
source "$ADAPTER_FILE"

staging_cmd=$(get_staging_cmd)
production_cmd=$(get_production_cmd)
rollback_cmd=$(get_rollback_cmd)
health_url=$(get_health_url)
smoke_cmd=$(get_smoke_cmd)

# Generate deployed.json from template
TEMPLATE_SRC="$REPO_DIR/templates/pipelines/deployed.json"
TEMPLATE_DST=".claude/pipeline-templates/deployed.json"

if [[ ! -f "$TEMPLATE_SRC" ]]; then
    error "Template not found: $TEMPLATE_SRC"
    exit 1
fi

mkdir -p ".claude/pipeline-templates"

# Use jq to properly fill in the template values
jq --arg staging "$staging_cmd" \
   --arg production "$production_cmd" \
   --arg rollback "$rollback_cmd" \
   --arg health "$health_url" \
   --arg smoke "$smoke_cmd" \
   --arg platform "$DEPLOY_PLATFORM" \
   '
   .name = "deployed-" + $platform |
   .description = "Autonomous pipeline with " + $platform + " deploy — generated by shipwright init --deploy" |
   (.stages[] | select(.id == "deploy") | .config) |= {
       staging_cmd: $staging,
       production_cmd: $production,
       rollback_cmd: $rollback
   } |
   (.stages[] | select(.id == "validate") | .config) |= {
       smoke_cmd: $smoke,
       health_url: $health,
       close_issue: true
   } |
   (.stages[] | select(.id == "monitor") | .config) |= (
       .health_url = $health |
       .rollback_cmd = $rollback
   )
   ' "$TEMPLATE_SRC" > "$TEMPLATE_DST"

success "Generated ${BOLD}${TEMPLATE_DST}${RESET}"

echo ""
echo -e "${BOLD}Deploy configured for ${DEPLOY_PLATFORM}!${RESET}"
echo ""
echo -e "${BOLD}Commands configured:${RESET}"
echo -e "  ${DIM}staging:${RESET}    $staging_cmd"
echo -e "  ${DIM}production:${RESET} $production_cmd"
echo -e "  ${DIM}rollback:${RESET}   $rollback_cmd"
if [[ -n "$health_url" ]]; then
    echo -e "  ${DIM}health:${RESET}     $health_url"
fi
echo ""
echo -e "${BOLD}Usage:${RESET}"
echo -e "  ${DIM}shipwright pipeline start --issue 42 --template .claude/pipeline-templates/deployed.json${RESET}"
echo ""
echo -e "${DIM}Edit ${TEMPLATE_DST} to customize deploy commands, gates, or thresholds.${RESET}"
echo ""
