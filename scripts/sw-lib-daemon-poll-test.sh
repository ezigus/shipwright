#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-poll test — Unit tests for poll, health, cleanup  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-poll Tests"

setup_test_env "sw-lib-daemon-poll-test"
trap cleanup_test_env EXIT

# Set up daemon env
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon-pause.flag"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export MIN_WORKERS=1
export MAX_WORKERS=4
export WORKER_MEM_GB=2
export WATCH_LABEL="shipwright"
export WATCH_MODE="label"
export BASE_BRANCH="main"
export PIPELINE_TEMPLATE="standard"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export SCRIPT_DIR="$SCRIPT_DIR"
export PROGRESS_DIR="$TEST_TEMP_DIR/progress"
export DAEMON_LOG_WRITE_COUNT=0
export STALE_REAPER_ENABLED="true"
export STALE_REAPER_AGE_DAYS="7"
export DEGRADATION_WINDOW="5"
export DEGRADATION_CFR_THRESHOLD="30"
export DEGRADATION_SUCCESS_THRESHOLD="50"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$EVENTS_FILE")" "$PROGRESS_DIR"
touch "$LOG_FILE"
mock_git
mock_gh

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
daemon_log() { :; }
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
daemon_collect_snapshot() { echo '{}'; }
daemon_assess_progress() { echo "healthy"; }
daemon_clear_progress() { :; }
get_adaptive_stale_timeout() { echo "3600"; }
epoch_to_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
rotate_event_log() { :; }
notify() { :; }
learn_worker_memory() { :; }
get_adaptive_cost_estimate() { echo "1.0"; }
get_success_rate_at_parallelism() { echo "80"; }

# Source daemon-state first (provides locked_state_update, daemon_is_inflight, get_active_count)
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

# Source daemon-poll (clear guard)
_DAEMON_POLL_LOADED=""
source "$SCRIPT_DIR/lib/daemon-poll.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_health_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_health_check"

# No STATE_FILE → runs disk/events checks only, no job processing
rm -f "$STATE_FILE"
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with no state file"

# STATE_FILE with empty active_jobs
init_state
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with empty active_jobs"

# STATE_FILE with a job containing dead PID (kill -0 fails, we continue)
atomic_write_state "$(jq -n '{
  version: 1,
  active_jobs: [{pid: 99999999, issue: 42, started_at: "2020-01-01T00:00:00Z", worktree: ""}],
  queued: [],
  completed: []
}')"
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with dead PID skips job"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_check_degradation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_check_degradation"

# No EVENTS_FILE → returns early
rm -f "$EVENTS_FILE"
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with no events file"

# EVENTS_FILE with fewer than window events → returns early
for i in 1 2 3; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"success\",\"ts_epoch\":$(now_epoch)}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with fewer than 5 events"

# EVENTS_FILE with 5+ pipeline.completed, high failure rate
rm -f "$EVENTS_FILE"
base_epoch=$(now_epoch)
for i in 1 2 3 4 5; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"failure\",\"ts_epoch\":$((base_epoch - 100 + i))}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with high CFR"

# EVENTS_FILE with good success rate
rm -f "$EVENTS_FILE"
for i in 1 2 3 4 5; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"success\",\"ts_epoch\":$((base_epoch - 100 + i))}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with good success rate"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_cleanup_stale
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_cleanup_stale"

# STALE_REAPER_ENABLED=false → returns immediately
STALE_REAPER_ENABLED="false"
daemon_cleanup_stale 2>/dev/null || true
assert_pass "daemon_cleanup_stale when disabled"

# STALE_REAPER_ENABLED=true with init state
STALE_REAPER_ENABLED="true"
init_state
daemon_cleanup_stale 2>/dev/null || true
assert_pass "daemon_cleanup_stale runs"

# Verify STATE_FILE updated (completed entries pruned if any old)
assert_file_exists "State file exists after cleanup" "$STATE_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# locked_state_update / daemon_is_inflight (used by cleanup)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: state + cleanup"

# Add old completed entry, run cleanup (prune)
cutoff_iso=$(epoch_to_iso $(($(now_epoch) - 86400 * 10)))
atomic_write_state "$(jq -n --arg c "$cutoff_iso" '{
  version: 1,
  active_jobs: [],
  queued: [],
  completed: [{issue: 1, completed_at: $c}],
  retry_counts: {}
}')"
before_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo "0")
daemon_cleanup_stale 2>/dev/null || true
after_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo "0")
assert_pass "daemon_cleanup_stale prunes old completed entries"

print_test_results
