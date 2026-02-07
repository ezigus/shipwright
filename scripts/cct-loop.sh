#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct loop — Continuous agent loop harness for Claude Code               ║
# ║                                                                         ║
# ║  Runs Claude Code in a headless loop until a goal is achieved.          ║
# ║  Supports single-agent and multi-agent (parallel worktree) modes.       ║
# ║                                                                         ║
# ║  Inspired by Anthropic's autonomous 16-agent C compiler build.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
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

# ─── Defaults ─────────────────────────────────────────────────────────────────
GOAL=""
MAX_ITERATIONS=20
TEST_CMD=""
MODEL="opus"
AGENTS=1
USE_WORKTREE=false
SKIP_PERMISSIONS=false
MAX_TURNS=""
RESUME=false
VERBOSE=false
MAX_ITERATIONS_EXPLICIT=false
VERSION="1.2.0"

# ─── Parse Arguments ──────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}cct${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}cct loop${RESET} \"<goal>\" [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--max-iterations${RESET} N       Max loop iterations (default: 20)"
    echo -e "  ${CYAN}--test-cmd${RESET} \"cmd\"         Test command to run between iterations"
    echo -e "  ${CYAN}--model${RESET} MODEL             Claude model to use (default: opus)"
    echo -e "  ${CYAN}--agents${RESET} N                Number of parallel agents (default: 1)"
    echo -e "  ${CYAN}--worktree${RESET}                Use git worktrees for isolation (auto if agents > 1)"
    echo -e "  ${CYAN}--skip-permissions${RESET}        Pass --dangerously-skip-permissions to Claude"
    echo -e "  ${CYAN}--max-turns${RESET} N             Max API turns per Claude session"
    echo -e "  ${CYAN}--resume${RESET}                  Resume from existing .claude/loop-state.md"
    echo -e "  ${CYAN}--verbose${RESET}                 Show full Claude output (default: summary)"
    echo -e "  ${CYAN}--help${RESET}                    Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}cct loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}cct loop \"Add payment processing\" --test-cmd \"npm test\" --max-iterations 30${RESET}"
    echo -e "  ${DIM}cct loop \"Refactor the database layer\" --agents 3 --model sonnet${RESET}"
    echo -e "  ${DIM}cct loop \"Fix all lint errors\" --skip-permissions --verbose${RESET}"
    echo ""
    echo -e "${BOLD}CIRCUIT BREAKER${RESET}"
    echo -e "  The loop automatically stops if:"
    echo -e "  ${DIM}• 3 consecutive iterations with < 5 lines changed${RESET}"
    echo -e "  ${DIM}• Claude outputs LOOP_COMPLETE${RESET}"
    echo -e "  ${DIM}• Max iterations reached${RESET}"
    echo -e "  ${DIM}• Ctrl-C (graceful shutdown with summary)${RESET}"
    echo ""
    echo -e "${BOLD}STATE & LOGS${RESET}"
    echo -e "  ${DIM}State file:  .claude/loop-state.md${RESET}"
    echo -e "  ${DIM}Logs dir:    .claude/loop-logs/${RESET}"
    echo -e "  ${DIM}Resume:      cct loop --resume${RESET}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-iterations)
            MAX_ITERATIONS="${2:-}"
            MAX_ITERATIONS_EXPLICIT=true
            [[ -z "$MAX_ITERATIONS" ]] && { error "Missing value for --max-iterations"; exit 1; }
            shift 2
            ;;
        --max-iterations=*) MAX_ITERATIONS="${1#--max-iterations=}"; MAX_ITERATIONS_EXPLICIT=true; shift ;;
        --test-cmd)
            TEST_CMD="${2:-}"
            [[ -z "$TEST_CMD" ]] && { error "Missing value for --test-cmd"; exit 1; }
            shift 2
            ;;
        --test-cmd=*) TEST_CMD="${1#--test-cmd=}"; shift ;;
        --model)
            MODEL="${2:-}"
            [[ -z "$MODEL" ]] && { error "Missing value for --model"; exit 1; }
            shift 2
            ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --agents)
            AGENTS="${2:-}"
            [[ -z "$AGENTS" ]] && { error "Missing value for --agents"; exit 1; }
            shift 2
            ;;
        --agents=*) AGENTS="${1#--agents=}"; shift ;;
        --worktree) USE_WORKTREE=true; shift ;;
        --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
        --max-turns)
            MAX_TURNS="${2:-}"
            [[ -z "$MAX_TURNS" ]] && { error "Missing value for --max-turns"; exit 1; }
            shift 2
            ;;
        --max-turns=*) MAX_TURNS="${1#--max-turns=}"; shift ;;
        --resume) RESUME=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
        *)
            # Positional: goal
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Auto-enable worktree for multi-agent
if [[ "$AGENTS" -gt 1 ]]; then
    USE_WORKTREE=true
fi

# ─── Validate Inputs ─────────────────────────────────────────────────────────

if ! $RESUME && [[ -z "$GOAL" ]]; then
    error "Missing goal. Usage: cct loop \"<goal>\" [options]"
    echo ""
    echo -e "  ${DIM}cct loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}cct loop --resume${RESET}"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    error "Claude Code CLI not found. Install it first:"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    exit 1
fi

if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    error "Not inside a git repository. The loop requires git for progress tracking."
    exit 1
fi

if [[ "$AGENTS" -gt 1 ]]; then
    if ! command -v tmux &>/dev/null; then
        error "tmux is required for multi-agent mode."
        echo -e "  ${DIM}brew install tmux${RESET}  (macOS)"
        exit 1
    fi
    if [[ -z "${TMUX:-}" ]]; then
        error "Multi-agent mode requires running inside tmux."
        echo -e "  ${DIM}tmux new -s work${RESET}"
        exit 1
    fi
fi

# ─── Directory Setup ─────────────────────────────────────────────────────────

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$PROJECT_ROOT/.claude"
STATE_FILE="$STATE_DIR/loop-state.md"
LOG_DIR="$STATE_DIR/loop-logs"
WORKTREE_DIR="$PROJECT_ROOT/.worktrees"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ─── Timing Helpers ───────────────────────────────────────────────────────────

now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

format_duration() {
    local secs="$1"
    local mins=$(( secs / 60 ))
    local remaining_secs=$(( secs % 60 ))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

# ─── State Management ────────────────────────────────────────────────────────

ITERATION=0
CONSECUTIVE_FAILURES=0
TOTAL_COMMITS=0
START_EPOCH=""
STATUS="running"
TEST_PASSED=""
TEST_OUTPUT=""
LOG_ENTRIES=""

initialize_state() {
    ITERATION=0
    CONSECUTIVE_FAILURES=0
    TOTAL_COMMITS=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"
    LOG_ENTRIES=""

    write_state
}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No state file found at $STATE_FILE"
        echo -e "  Start a new loop instead: ${DIM}cct loop \"<goal>\"${RESET}"
        exit 1
    fi

    info "Resuming from $STATE_FILE"

    # Save CLI values before parsing state (CLI takes precedence)
    local cli_max_iterations="$MAX_ITERATIONS"

    # Parse YAML front matter
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then
                break
            else
                in_frontmatter=true
                continue
            fi
        fi
        if $in_frontmatter; then
            case "$line" in
                goal:*)          [[ -z "$GOAL" ]] && GOAL="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                iteration:*)     ITERATION="$(echo "${line#iteration:}" | tr -d ' ')" ;;
                max_iterations:*) MAX_ITERATIONS="$(echo "${line#max_iterations:}" | tr -d ' ')" ;;
                status:*)        STATUS="$(echo "${line#status:}" | tr -d ' ')" ;;
                test_cmd:*)      [[ -z "$TEST_CMD" ]] && TEST_CMD="$(echo "${line#test_cmd:}" | sed 's/^ *"//;s/" *$//')" ;;
                model:*)         MODEL="$(echo "${line#model:}" | tr -d ' ')" ;;
                agents:*)        AGENTS="$(echo "${line#agents:}" | tr -d ' ')" ;;
                consecutive_failures:*) CONSECUTIVE_FAILURES="$(echo "${line#consecutive_failures:}" | tr -d ' ')" ;;
                total_commits:*) TOTAL_COMMITS="$(echo "${line#total_commits:}" | tr -d ' ')" ;;
            esac
        fi
    done < "$STATE_FILE"

    # CLI --max-iterations overrides state file
    if $MAX_ITERATIONS_EXPLICIT; then
        MAX_ITERATIONS="$cli_max_iterations"
    fi

    # Extract the log section (everything after ## Log)
    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$STATUS" == "complete" ]]; then
        warn "Previous loop completed. Start a new one or edit the state file."
        exit 0
    fi

    # Reset circuit breaker on resume
    CONSECUTIVE_FAILURES=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"

    # If we hit max iterations before, warn user to extend
    if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]] && ! $MAX_ITERATIONS_EXPLICIT; then
        warn "Previous run stopped at iteration $ITERATION/$MAX_ITERATIONS."
        echo -e "  Extend with: ${DIM}cct loop --resume --max-iterations $(( MAX_ITERATIONS + 10 ))${RESET}"
        exit 0
    fi

    success "Resumed: iteration $ITERATION/$MAX_ITERATIONS"
}

write_state() {
    cat > "$STATE_FILE" <<EOF
---
goal: "$GOAL"
iteration: $ITERATION
max_iterations: $MAX_ITERATIONS
status: $STATUS
test_cmd: "$TEST_CMD"
model: $MODEL
agents: $AGENTS
started_at: $(now_iso)
last_iteration_at: $(now_iso)
consecutive_failures: $CONSECUTIVE_FAILURES
total_commits: $TOTAL_COMMITS
---

## Log
$LOG_ENTRIES
EOF
}

append_log_entry() {
    local entry="$1"
    if [[ -n "$LOG_ENTRIES" ]]; then
        LOG_ENTRIES="${LOG_ENTRIES}
${entry}"
    else
        LOG_ENTRIES="$entry"
    fi
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────

git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

git_diff_stat() {
    git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo ""
}

git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    git -C "$work_dir" add -A 2>/dev/null || true
    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}

# ─── Progress & Circuit Breaker ───────────────────────────────────────────────

check_progress() {
    local changes
    changes="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo "")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${insertions:-0}" -lt 5 ]]; then
        return 1  # No meaningful progress
    fi
    return 0
}

check_completion() {
    local log_file="$1"
    grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null
}

check_circuit_breaker() {
    if [[ "$CONSECUTIVE_FAILURES" -ge 3 ]]; then
        error "Circuit breaker tripped: 3 consecutive iterations with no meaningful progress."
        STATUS="circuit_breaker"
        return 1
    fi
    return 0
}

check_max_iterations() {
    if [[ "$ITERATION" -gt "$MAX_ITERATIONS" ]]; then
        warn "Max iterations ($MAX_ITERATIONS) reached."
        STATUS="max_iterations"
        return 1
    fi
    return 0
}

# ─── Test Gate ────────────────────────────────────────────────────────────────

run_test_gate() {
    if [[ -z "$TEST_CMD" ]]; then
        TEST_PASSED=""
        TEST_OUTPUT=""
        return
    fi

    local test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
    if eval "$TEST_CMD" > "$test_log" 2>&1; then
        TEST_PASSED=true
        TEST_OUTPUT="All tests passed."
    else
        TEST_PASSED=false
        TEST_OUTPUT="$(tail -50 "$test_log")"
    fi
}

# ─── Prompt Composition ──────────────────────────────────────────────────────

compose_prompt() {
    local recent_log
    # Get last 3 iteration summaries from log entries
    recent_log="$(echo "$LOG_ENTRIES" | tail -15)"
    if [[ -z "$recent_log" ]]; then
        recent_log="(first iteration — no previous progress)"
    fi

    local git_log
    git_log="$(git_recent_log)"

    local test_section
    if [[ -z "$TEST_CMD" ]]; then
        test_section="No test command configured."
    elif [[ -z "$TEST_PASSED" ]]; then
        test_section="No test results yet (first iteration). Test command: $TEST_CMD"
    elif $TEST_PASSED; then
        test_section="$TEST_OUTPUT"
    else
        test_section="TESTS FAILED — fix these before proceeding:
$TEST_OUTPUT"
    fi

    cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Current Progress
${recent_log}

## Recent Git Activity
${git_log}

## Test Results (Previous Iteration)
${test_section}

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Run tests if a test command exists: ${TEST_CMD:-"(none)"}
5. Commit your work with a descriptive message
6. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If tests fail, fix them before ending
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
}

compose_worker_prompt() {
    local agent_num="$1"
    local total_agents="$2"

    local base_prompt
    base_prompt="$(compose_prompt)"

    cat <<PROMPT
${base_prompt}

## Agent Identity
You are Agent ${agent_num} of ${total_agents}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.
PROMPT
}

# ─── Claude Execution ────────────────────────────────────────────────────────

build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    echo "${flags[*]}"
}

run_claude_iteration() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local prompt
    prompt="$(compose_prompt)"

    local flags
    flags="$(build_claude_flags)"

    local iter_start
    iter_start="$(now_epoch)"

    echo -e "\n${CYAN}${BOLD}▸${RESET} ${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET} — Starting..."

    # Run Claude headless
    local exit_code=0
    # shellcheck disable=SC2086
    claude -p "$prompt" $flags > "$log_file" 2>&1 || exit_code=$?

    local iter_end
    iter_end="$(now_epoch)"
    local iter_duration=$(( iter_end - iter_start ))

    echo -e "  ${GREEN}✓${RESET} Claude session completed ($(format_duration "$iter_duration"), exit $exit_code)"

    # Show verbose output if requested
    if $VERBOSE; then
        echo -e "  ${DIM}─── Claude Output ───${RESET}"
        sed 's/^/  /' "$log_file" | head -100
        echo -e "  ${DIM}─────────────────────${RESET}"
    fi

    return $exit_code
}

# ─── Iteration Summary Extraction ────────────────────────────────────────────

extract_summary() {
    local log_file="$1"
    # Grab last meaningful lines from Claude output, skipping empty lines
    local summary
    summary="$(grep -v '^$' "$log_file" | tail -5 | head -3 2>/dev/null || echo "(no output)")"
    # Truncate long lines
    echo "$summary" | cut -c1-120
}

# ─── Display Helpers ─────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}cct${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}  $GOAL"
    echo -e "  ${BOLD}Model:${RESET} $MODEL ${DIM}|${RESET} ${BOLD}Max:${RESET} $MAX_ITERATIONS iterations ${DIM}|${RESET} ${BOLD}Test:${RESET} ${TEST_CMD:-"(none)"}"
    if [[ "$AGENTS" -gt 1 ]]; then
        echo -e "  ${BOLD}Agents:${RESET} $AGENTS ${DIM}(parallel worktree mode)${RESET}"
    fi
    if $SKIP_PERMISSIONS; then
        echo -e "  ${YELLOW}${BOLD}⚠${RESET}  ${YELLOW}--dangerously-skip-permissions enabled${RESET}"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

show_summary() {
    local end_epoch
    end_epoch="$(now_epoch)"
    local duration=$(( end_epoch - START_EPOCH ))

    local status_display
    case "$STATUS" in
        complete)        status_display="${GREEN}✓ Complete (LOOP_COMPLETE detected)${RESET}" ;;
        circuit_breaker) status_display="${RED}✗ Circuit breaker tripped${RESET}" ;;
        max_iterations)  status_display="${YELLOW}⚠ Max iterations reached${RESET}" ;;
        interrupted)     status_display="${YELLOW}⚠ Interrupted by user${RESET}" ;;
        error)           status_display="${RED}✗ Error${RESET}" ;;
        *)               status_display="${DIM}$STATUS${RESET}" ;;
    esac

    local test_display
    if [[ -z "$TEST_CMD" ]]; then
        test_display="${DIM}No tests configured${RESET}"
    elif [[ "$TEST_PASSED" == "true" ]]; then
        test_display="${GREEN}All passing${RESET}"
    elif [[ "$TEST_PASSED" == "false" ]]; then
        test_display="${RED}Failing${RESET}"
    else
        test_display="${DIM}Not run${RESET}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    local status_upper
    status_upper="$(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
    echo -e "  ${BOLD}LOOP ${status_upper}${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    echo -e "  ${BOLD}Status:${RESET}      $status_display"
    echo -e "  ${BOLD}Iterations:${RESET}  $ITERATION/$MAX_ITERATIONS"
    echo -e "  ${BOLD}Duration:${RESET}    $(format_duration "$duration")"
    echo -e "  ${BOLD}Commits:${RESET}     $TOTAL_COMMITS"
    echo -e "  ${BOLD}Tests:${RESET}       $test_display"
    echo ""
    echo -e "  ${DIM}State: $STATE_FILE${RESET}"
    echo -e "  ${DIM}Logs:  $LOG_DIR/${RESET}"
    echo ""
}

# ─── Signal Handling ──────────────────────────────────────────────────────────

CHILD_PID=""

cleanup() {
    echo ""
    warn "Loop interrupted at iteration $ITERATION"

    # Kill any running Claude process
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi

    # If multi-agent, kill worker panes
    if [[ "$AGENTS" -gt 1 ]]; then
        cleanup_multi_agent
    fi

    STATUS="interrupted"
    write_state
    show_summary
    exit 130
}

trap cleanup SIGINT SIGTERM

# ─── Multi-Agent: Worktree Setup ─────────────────────────────────────────────

setup_worktrees() {
    local branch_base="loop"
    mkdir -p "$WORKTREE_DIR"

    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        local branch_name="${branch_base}/agent-${i}"

        if [[ -d "$wt_path" ]]; then
            info "Worktree agent-${i} already exists"
            continue
        fi

        # Create branch if it doesn't exist
        if ! git -C "$PROJECT_ROOT" rev-parse --verify "$branch_name" &>/dev/null; then
            git -C "$PROJECT_ROOT" branch "$branch_name" HEAD 2>/dev/null || true
        fi

        git -C "$PROJECT_ROOT" worktree add "$wt_path" "$branch_name" 2>/dev/null || {
            error "Failed to create worktree for agent-${i}"
            return 1
        }

        success "Worktree: agent-${i} → $wt_path"
    done
}

cleanup_worktrees() {
    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        if [[ -d "$wt_path" ]]; then
            git -C "$PROJECT_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        fi
    done
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
}

# ─── Multi-Agent: Worker Loop Script ─────────────────────────────────────────

generate_worker_script() {
    local agent_num="$1"
    local total_agents="$2"
    local wt_path="$WORKTREE_DIR/agent-${agent_num}"
    local worker_script="$LOG_DIR/worker-${agent_num}.sh"

    local claude_flags
    claude_flags="$(build_claude_flags)"

    cat > "$worker_script" <<'WORKEREOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_NUM="__AGENT_NUM__"
TOTAL_AGENTS="__TOTAL_AGENTS__"
WORK_DIR="__WORK_DIR__"
LOG_DIR="__LOG_DIR__"
MAX_ITERATIONS="__MAX_ITERATIONS__"
GOAL="__GOAL__"
TEST_CMD="__TEST_CMD__"
CLAUDE_FLAGS="__CLAUDE_FLAGS__"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

cd "$WORK_DIR"
ITERATION=0
CONSECUTIVE_FAILURES=0

echo -e "${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM}/${TOTAL_AGENTS} starting in ${WORK_DIR}"

while [[ "$ITERATION" -lt "$MAX_ITERATIONS" ]]; do
    ITERATION=$(( ITERATION + 1 ))
    echo -e "\n${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM} — Iteration ${ITERATION}/${MAX_ITERATIONS}"

    # Pull latest from other agents
    git fetch origin main 2>/dev/null && git merge origin/main --no-edit 2>/dev/null || true

    # Build prompt
    GIT_LOG="$(git log --oneline -20 2>/dev/null || echo '(no commits)')"
    TEST_SECTION="No test results yet."
    if [[ -n "$TEST_CMD" ]]; then
        TEST_SECTION="Test command: $TEST_CMD"
    fi

    PROMPT="$(cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Recent Git Activity
${GIT_LOG}

## Test Results
${TEST_SECTION}

## Agent Identity
You are Agent ${AGENT_NUM} of ${TOTAL_AGENTS}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Commit your work with a descriptive message
5. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
)"

    # Run Claude
    LOG_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.log"
    # shellcheck disable=SC2086
    claude -p "$PROMPT" $CLAUDE_FLAGS > "$LOG_FILE" 2>&1 || true

    echo -e "  ${GREEN}✓${RESET} Claude session completed"

    # Check completion
    if grep -q "LOOP_COMPLETE" "$LOG_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE detected!${RESET}"
        # Signal completion
        touch "$LOG_DIR/.agent-${AGENT_NUM}-complete"
        break
    fi

    # Auto-commit
    git add -A 2>/dev/null || true
    if git commit -m "agent-${AGENT_NUM}: iteration ${ITERATION}" --no-verify 2>/dev/null; then
        git push origin "loop/agent-${AGENT_NUM}" 2>/dev/null || true
        echo -e "  ${GREEN}✓${RESET} Committed and pushed"
    fi

    # Circuit breaker: check for progress
    CHANGES="$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo '')"
    INSERTIONS="$(echo "$CHANGES" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${INSERTIONS:-0}" -lt 5 ]]; then
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/3)"
    else
        CONSECUTIVE_FAILURES=0
    fi

    if [[ "$CONSECUTIVE_FAILURES" -ge 3 ]]; then
        echo -e "  ${RED}✗${RESET} Circuit breaker — stopping agent ${AGENT_NUM}"
        break
    fi

    sleep 2
done

echo -e "\n${DIM}Agent ${AGENT_NUM} finished after ${ITERATION} iterations${RESET}"
WORKEREOF

    # Replace placeholders
    sed -i '' "s|__AGENT_NUM__|${agent_num}|g" "$worker_script"
    sed -i '' "s|__TOTAL_AGENTS__|${total_agents}|g" "$worker_script"
    sed -i '' "s|__WORK_DIR__|${wt_path}|g" "$worker_script"
    sed -i '' "s|__LOG_DIR__|${LOG_DIR}|g" "$worker_script"
    sed -i '' "s|__MAX_ITERATIONS__|${MAX_ITERATIONS}|g" "$worker_script"
    sed -i '' "s|__TEST_CMD__|${TEST_CMD}|g" "$worker_script"
    sed -i '' "s|__CLAUDE_FLAGS__|${claude_flags}|g" "$worker_script"
    # Goal needs special handling for sed (may contain special chars)
    python3 -c "
import sys
with open('$worker_script', 'r') as f:
    content = f.read()
content = content.replace('__GOAL__', '''$GOAL''')
with open('$worker_script', 'w') as f:
    f.write(content)
"
    chmod +x "$worker_script"
    echo "$worker_script"
}

# ─── Multi-Agent: Launch ─────────────────────────────────────────────────────

MULTI_WINDOW_NAME=""

launch_multi_agent() {
    info "Setting up multi-agent mode ($AGENTS agents)..."

    # Setup worktrees
    setup_worktrees || { error "Failed to setup worktrees"; exit 1; }

    # Create tmux window for workers
    MULTI_WINDOW_NAME="cct-loop-$(date +%s)"
    tmux new-window -n "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"

    # First pane becomes monitor
    tmux send-keys -t "$MULTI_WINDOW_NAME" "printf '\\033]2;loop-monitor\\033\\\\'" Enter
    sleep 0.2
    tmux send-keys -t "$MULTI_WINDOW_NAME" "clear && echo 'Loop Monitor — watching agent logs...'" Enter

    # Create worker panes
    for i in $(seq 1 "$AGENTS"); do
        local worker_script
        worker_script="$(generate_worker_script "$i" "$AGENTS")"

        tmux split-window -t "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"
        sleep 0.1
        tmux send-keys -t "$MULTI_WINDOW_NAME" "printf '\\033]2;agent-${i}\\033\\\\'" Enter
        sleep 0.1
        tmux send-keys -t "$MULTI_WINDOW_NAME" "bash '$worker_script'" Enter
    done

    # Tile the layout
    tmux select-layout -t "$MULTI_WINDOW_NAME" tiled 2>/dev/null || true

    # In the monitor pane, tail all agent logs
    tmux select-pane -t "$MULTI_WINDOW_NAME.0"
    sleep 0.5
    tmux send-keys -t "$MULTI_WINDOW_NAME.0" "clear && tail -f $LOG_DIR/agent-*-iter-*.log 2>/dev/null || echo 'Waiting for agent logs...'" Enter

    success "Launched $AGENTS worker agents in window: $MULTI_WINDOW_NAME"
    echo ""

    # Wait for completion
    info "Monitoring agents... (Ctrl-C to stop all)"
    wait_for_multi_completion
}

wait_for_multi_completion() {
    while true; do
        # Check if any agent signaled completion
        for i in $(seq 1 "$AGENTS"); do
            if [[ -f "$LOG_DIR/.agent-${i}-complete" ]]; then
                success "Agent $i signaled LOOP_COMPLETE!"
                STATUS="complete"
                write_state
                return 0
            fi
        done

        # Check if all worker panes are still running
        local running=0
        for i in $(seq 1 "$AGENTS"); do
            # Check if the worker log is still being written to
            local latest_log
            latest_log="$(ls -t "$LOG_DIR"/agent-"${i}"-iter-*.log 2>/dev/null | head -1)"
            if [[ -n "$latest_log" ]]; then
                local age
                age=$(( $(now_epoch) - $(stat -f %m "$latest_log" 2>/dev/null || echo 0) ))
                if [[ $age -lt 300 ]]; then  # Active within 5 minutes
                    running=$(( running + 1 ))
                fi
            fi
        done

        if [[ $running -eq 0 ]]; then
            # Check if we have any logs at all (might still be starting)
            local total_logs
            total_logs="$(ls "$LOG_DIR"/agent-*-iter-*.log 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${total_logs:-0}" -gt 0 ]]; then
                warn "All agents appear to have stopped."
                STATUS="complete"
                write_state
                return 0
            fi
        fi

        sleep 5
    done
}

cleanup_multi_agent() {
    if [[ -n "$MULTI_WINDOW_NAME" ]]; then
        # Send Ctrl-C to all panes in the worker window
        local pane_count
        pane_count="$(tmux list-panes -t "$MULTI_WINDOW_NAME" 2>/dev/null | wc -l | tr -d ' ')"
        for i in $(seq 0 $(( pane_count - 1 ))); do
            tmux send-keys -t "$MULTI_WINDOW_NAME.$i" C-c 2>/dev/null || true
        done
        sleep 1
        tmux kill-window -t "$MULTI_WINDOW_NAME" 2>/dev/null || true
    fi

    # Clean up completion markers
    rm -f "$LOG_DIR"/.agent-*-complete 2>/dev/null || true
}

# ─── Main: Single-Agent Loop ─────────────────────────────────────────────────

run_single_agent_loop() {
    if $RESUME; then
        resume_state
    else
        initialize_state
    fi

    show_banner

    while true; do
        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        ITERATION=$(( ITERATION + 1 ))
        check_max_iterations || { ITERATION=$(( ITERATION - 1 )); break; }

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"

        # Check completion
        if check_completion "$log_file"; then
            success "LOOP_COMPLETE detected!"
            STATUS="complete"
            write_state
            show_summary
            return 0
        fi

        # Auto-commit if Claude didn't
        local commits_before
        commits_before="$(git_commit_count)"
        git_auto_commit "$PROJECT_ROOT" || true
        local commits_after
        commits_after="$(git_commit_count)"
        local new_commits=$(( commits_after - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + new_commits ))

        # Git diff stats
        local diff_stat
        diff_stat="$(git_diff_stat)"
        if [[ -n "$diff_stat" ]]; then
            echo -e "  ${GREEN}✓${RESET} Git: $diff_stat"
        fi

        # Test gate
        run_test_gate
        if [[ -n "$TEST_CMD" ]]; then
            if [[ "$TEST_PASSED" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Tests: passed"
            else
                echo -e "  ${RED}✗${RESET} Tests: failed"
            fi
        fi

        # Check progress (circuit breaker)
        if check_progress; then
            CONSECUTIVE_FAILURES=0
            echo -e "  ${GREEN}✓${RESET} Progress detected — continuing"
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/3 before circuit breaker)"
        fi

        # Extract summary and update state
        local summary
        summary="$(extract_summary "$log_file")"
        append_log_entry "### Iteration $ITERATION ($(now_iso))
$summary
"
        write_state

        sleep 2
    done

    # Write final state after loop exits
    write_state
    show_summary
}

# ─── Main: Entry Point ───────────────────────────────────────────────────────

main() {
    if [[ "$AGENTS" -gt 1 ]]; then
        if $RESUME; then
            resume_state
        else
            initialize_state
        fi
        show_banner
        launch_multi_agent
        show_summary
    else
        run_single_agent_loop
    fi
}

main
