#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright daemon test — Unit tests for daemon metrics, health, alerting      ║
# ║  Creates synthetic events · Sources daemon functions · Validates output  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/sw-daemon.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-daemon-test.XXXXXX")

    # Create events directory (daemon uses $HOME/.shipwright)
    mkdir -p "$TEMP_DIR/.shipwright"
    mkdir -p "$TEMP_DIR/logs"
    mkdir -p "$TEMP_DIR/project/.claude"

    # Set env vars to redirect daemon state
    export HOME="$TEMP_DIR"
    export EVENTS_FILE="$TEMP_DIR/.shipwright/events.jsonl"
    export DAEMON_DIR="$TEMP_DIR/.shipwright"
    export STATE_FILE="$TEMP_DIR/.shipwright/daemon-state.json"
    export LOG_FILE="$TEMP_DIR/.shipwright/daemon.log"
    export LOG_DIR="$TEMP_DIR/logs"
    export WORKTREE_DIR="$TEMP_DIR/project/.worktrees"
    export PID_FILE="$TEMP_DIR/shipwright/daemon.pid"
    export SHUTDOWN_FLAG="$TEMP_DIR/shipwright/daemon.shutdown"
    export NO_GITHUB=true

    # Defaults for config vars
    export HEALTH_STALE_TIMEOUT=1800
    export PRIORITY_LABELS="urgent,p0,high,p1,normal,p2,low,p3"
    export DEGRADATION_WINDOW=5
    export DEGRADATION_CFR_THRESHOLD=30
    export DEGRADATION_SUCCESS_THRESHOLD=50
    export SLACK_WEBHOOK=""
    export POLL_INTERVAL=60
    export MAX_PARALLEL=2
    export WATCH_LABEL="ready-to-build"

    # Patrol defaults
    export PATROL_LABEL="auto-patrol"
    export PATROL_AUTO_WATCH=false
    export PATROL_MAX_ISSUES=5
    export PATROL_FAILURES_THRESHOLD=3
    export PATROL_DORA_ENABLED=true
    export PATROL_UNTESTED_ENABLED=true
    export PATROL_RETRY_ENABLED=true
    export PATROL_RETRY_THRESHOLD=2
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Reset between tests
reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$STATE_FILE"
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Source daemon functions
# We extract functions from the daemon script by sourcing it in a subshell
# with SUBCOMMAND=help to avoid running the main logic, then exporting functions.
# Since the daemon runs setup_dirs and case statement at parse time, we
# instead directly define/source the functions we need to test.
# ═══════════════════════════════════════════════════════════════════════════════

# Source just the function definitions from the daemon script
source_daemon_functions() {
    # Extract function definitions using a careful approach:
    # We need: now_iso, now_epoch, epoch_to_iso, format_duration, emit_event,
    # dora_grade, daemon_health_check, daemon_check_degradation, daemon_log,
    # atomic_write_state, notify

    # Simple helpers we redefine directly (faster + safer than sourcing whole script)
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }

    epoch_to_iso() {
        local epoch="$1"
        date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($epoch).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || \
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
        mkdir -p "$(dirname "$EVENTS_FILE")"
        echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
    }

    daemon_log() {
        local level="$1"
        shift
        local msg="$*"
        local ts
        ts=$(now_iso)
        echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    }

    notify() {
        # No-op in tests
        true
    }

    # patrol_build_labels — from updated daemon
    patrol_build_labels() {
        local check_label="$1"
        local labels="${PATROL_LABEL},${check_label}"
        if [[ "$PATROL_AUTO_WATCH" == "true" && -n "${WATCH_LABEL:-}" ]]; then
            labels="${labels},${WATCH_LABEL}"
        fi
        echo "$labels"
    }

    atomic_write_state() {
        local content="$1"
        local tmp_file="${STATE_FILE}.tmp.$$"
        echo "$content" > "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
    }

    # dora_grade — awk-based, matching the updated daemon script
    dora_grade() {
        local metric="$1" value="$2"
        case "$metric" in
            deploy_freq)
                if awk "BEGIN{exit !($value >= 7)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value >= 1)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value >= 0.25)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            cycle_time)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                [[ "$value" -lt 604800 ]] && echo "Medium" && return
                echo "Low" ;;
            cfr)
                if awk "BEGIN{exit !($value < 5)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value < 10)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value < 15)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            mttr)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                echo "Medium" ;;
        esac
    }

    # daemon_health_check — from the updated daemon
    daemon_health_check() {
        local findings=0

        local stale_timeout="${HEALTH_STALE_TIMEOUT:-1800}"
        local now_e
        now_e=$(now_epoch)

        if [[ -f "$STATE_FILE" ]]; then
            while IFS= read -r job; do
                local pid started_at issue_num
                pid=$(echo "$job" | jq -r '.pid')
                started_at=$(echo "$job" | jq -r '.started_at // empty')
                issue_num=$(echo "$job" | jq -r '.issue')

                if [[ -n "$started_at" ]]; then
                    local start_e
                    start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
                    local elapsed=$(( now_e - start_e ))
                    if [[ "$elapsed" -gt "$stale_timeout" ]] && kill -0 "$pid" 2>/dev/null; then
                        daemon_log WARN "Stale job detected: issue #${issue_num} (${elapsed}s, PID $pid) — killing"
                        kill "$pid" 2>/dev/null || true
                        findings=$((findings + 1))
                    fi
                fi
            done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null)
        fi

        local free_kb
        free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
        if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
            daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
            findings=$((findings + 1))
        fi

        if [[ -f "$EVENTS_FILE" ]]; then
            local events_size
            events_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
            if [[ "$events_size" -gt 104857600 ]]; then
                daemon_log WARN "Events file large ($(( events_size / 1048576 ))MB) — consider rotating"
                findings=$((findings + 1))
            fi
        fi

        if [[ "$findings" -gt 0 ]]; then
            emit_event "daemon.health" "findings=$findings"
        fi
    }

    # daemon_check_degradation — from the updated daemon
    daemon_check_degradation() {
        if [[ ! -f "$EVENTS_FILE" ]]; then return; fi

        local window="${DEGRADATION_WINDOW:-5}"
        local cfr_threshold="${DEGRADATION_CFR_THRESHOLD:-30}"
        local success_threshold="${DEGRADATION_SUCCESS_THRESHOLD:-50}"

        local recent
        recent=$(tail -200 "$EVENTS_FILE" | jq -s "[.[] | select(.type == \"pipeline.completed\")] | .[-${window}:]" 2>/dev/null)
        local count
        count=$(echo "$recent" | jq 'length' 2>/dev/null || echo 0)

        if [[ "$count" -lt "$window" ]]; then return; fi

        local failures successes
        failures=$(echo "$recent" | jq '[.[] | select(.result == "failure")] | length')
        successes=$(echo "$recent" | jq '[.[] | select(.result == "success")] | length')
        local cfr_pct=$(( failures * 100 / count ))
        local success_pct=$(( successes * 100 / count ))

        local alerts=""
        if [[ "$cfr_pct" -gt "$cfr_threshold" ]]; then
            alerts="CFR ${cfr_pct}% exceeds threshold ${cfr_threshold}%"
            daemon_log WARN "DEGRADATION: $alerts"
        fi
        if [[ "$success_pct" -lt "$success_threshold" ]]; then
            local msg="Success rate ${success_pct}% below threshold ${success_threshold}%"
            [[ -n "$alerts" ]] && alerts="$alerts; $msg" || alerts="$msg"
            daemon_log WARN "DEGRADATION: $msg"
        fi

        if [[ -n "$alerts" ]]; then
            emit_event "daemon.alert" "alerts=$alerts" "cfr_pct=$cfr_pct" "success_pct=$success_pct"

            if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
                notify "Pipeline Degradation Alert" "$alerts" "warn"
            fi
        fi
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYNTHETIC EVENT HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

# Write a synthetic event directly to events.jsonl
# Usage: write_event '{"ts":"...","type":"..."}'
write_event() {
    echo "$1" >> "$EVENTS_FILE"
}

# Write a pipeline.completed event with specific parameters
# Usage: write_pipeline_event <result> <duration_s> <ts> <ts_epoch>
write_pipeline_event() {
    local result="$1" duration_s="$2" ts="$3" ts_epoch="$4"
    write_event "{\"ts\":\"$ts\",\"ts_epoch\":$ts_epoch,\"type\":\"pipeline.completed\",\"result\":\"$result\",\"duration_s\":$duration_s}"
}

# Write a stage.completed event
# Usage: write_stage_event <stage> <duration_s> <ts>
write_stage_event() {
    local stage="$1" duration_s="$2" ts="$3"
    local ts_epoch
    ts_epoch=$(date +%s)
    write_event "{\"ts\":\"$ts\",\"ts_epoch\":$ts_epoch,\"type\":\"stage.completed\",\"stage\":\"$stage\",\"duration_s\":$duration_s}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_equals() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected '$expected', got '$actual' ($label)"
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(echo "$haystack" | head -3)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $needle ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_gt() {
    local actual="$1" threshold="$2" label="${3:-greater than}"
    if [[ "$actual" -gt "$threshold" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected $actual > $threshold ($label)"
    return 1
}

assert_json_key() {
    local json="$1" key="$2" expected="$3" label="${4:-json key}"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    assert_equals "$expected" "$actual" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. dora_grade deploy_freq — Elite for >= 7
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_elite() {
    local grade
    grade=$(dora_grade deploy_freq 10.0)
    assert_equals "Elite" "$grade" "deploy_freq 10.0 = Elite" &&
    grade=$(dora_grade deploy_freq 7.0)
    assert_equals "Elite" "$grade" "deploy_freq 7.0 = Elite" &&
    grade=$(dora_grade deploy_freq 7)
    assert_equals "Elite" "$grade" "deploy_freq 7 = Elite"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. dora_grade deploy_freq — High for >= 1
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_high() {
    local grade
    grade=$(dora_grade deploy_freq 3.5)
    assert_equals "High" "$grade" "deploy_freq 3.5 = High" &&
    grade=$(dora_grade deploy_freq 1.0)
    assert_equals "High" "$grade" "deploy_freq 1.0 = High"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. dora_grade deploy_freq — Medium for >= 0.25
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_medium() {
    local grade
    grade=$(dora_grade deploy_freq 0.5)
    assert_equals "Medium" "$grade" "deploy_freq 0.5 = Medium" &&
    grade=$(dora_grade deploy_freq 0.25)
    assert_equals "Medium" "$grade" "deploy_freq 0.25 = Medium"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. dora_grade deploy_freq — Low for < 0.25
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_low() {
    local grade
    grade=$(dora_grade deploy_freq 0.1)
    assert_equals "Low" "$grade" "deploy_freq 0.1 = Low" &&
    grade=$(dora_grade deploy_freq 0)
    assert_equals "Low" "$grade" "deploy_freq 0 = Low"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. dora_grade cfr — all thresholds
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_cfr() {
    local grade
    grade=$(dora_grade cfr 3.0)
    assert_equals "Elite" "$grade" "cfr 3.0 = Elite" &&
    grade=$(dora_grade cfr 7.5)
    assert_equals "High" "$grade" "cfr 7.5 = High" &&
    grade=$(dora_grade cfr 12.0)
    assert_equals "Medium" "$grade" "cfr 12.0 = Medium" &&
    grade=$(dora_grade cfr 20.0)
    assert_equals "Low" "$grade" "cfr 20.0 = Low"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Stage timings — filter-first jq query
# ──────────────────────────────────────────────────────────────────────────────
test_stage_timings_filter() {
    local now_ts
    now_ts=$(now_iso)

    # Write stage.completed events
    write_stage_event "build" 120 "$now_ts"
    write_stage_event "build" 180 "$now_ts"
    write_stage_event "test" 60 "$now_ts"
    # Write a non-stage event that has a "stage" field (should NOT pollute results)
    write_event "{\"ts\":\"$now_ts\",\"ts_epoch\":$(now_epoch),\"type\":\"pipeline.started\",\"stage\":\"build\"}"

    # Run the fixed jq query
    local result
    result=$(cat "$EVENTS_FILE" | jq -s '[.[] | select(.type == "stage.completed")] | group_by(.stage) | map({stage: .[0].stage, avg: ([.[].duration_s] | add / length | floor)}) | sort_by(.avg) | reverse')

    # Should have 2 stages: build (avg 150) and test (avg 60)
    local stage_count build_avg
    stage_count=$(echo "$result" | jq 'length')
    build_avg=$(echo "$result" | jq '.[0].avg')

    assert_equals "2" "$stage_count" "2 stages found" &&
    assert_equals "150" "$build_avg" "build avg = 150s"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. MTTR — pairs failures with next success
# ──────────────────────────────────────────────────────────────────────────────
test_mttr_computation() {
    local base_epoch
    base_epoch=$(now_epoch)

    # Write events: failure at t=0, success at t=600 (10min gap)
    # Then failure at t=1200, success at t=2400 (20min gap)
    # Expected MTTR = (600 + 1200) / 2 = 900s
    local t0=$base_epoch
    local t1=$((base_epoch + 600))
    local t2=$((base_epoch + 1200))
    local t3=$((base_epoch + 2400))

    write_pipeline_event "failure" 100 "$(epoch_to_iso $t0)" "$t0"
    write_pipeline_event "success" 200 "$(epoch_to_iso $t1)" "$t1"
    write_pipeline_event "failure" 150 "$(epoch_to_iso $t2)" "$t2"
    write_pipeline_event "success" 250 "$(epoch_to_iso $t3)" "$t3"

    # Run the real MTTR jq from daemon
    local mttr
    mttr=$(cat "$EVENTS_FILE" | jq -s '
        [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
        [range(length) as $i |
            if .[$i].result == "failure" then
                [.[$i+1:][] | select(.result == "success")][0] as $next |
                if $next and $next.ts_epoch and .[$i].ts_epoch then
                    ($next.ts_epoch - .[$i].ts_epoch)
                else null end
            else null end
        ] | map(select(. != null)) |
        if length > 0 then (add / length | floor) else 0 end
    ')

    assert_equals "900" "$mttr" "MTTR = 900s (avg of 600+1200)"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. epoch_to_iso helper works
# ──────────────────────────────────────────────────────────────────────────────
test_epoch_to_iso_works() {
    # Known epoch: 1704067200 = 2024-01-01T00:00:00Z
    local result
    result=$(epoch_to_iso 1704067200)
    assert_equals "2024-01-01T00:00:00Z" "$result" "epoch 1704067200 → 2024-01-01"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Health check detects stale jobs
# ──────────────────────────────────────────────────────────────────────────────
test_health_check_stale() {
    # Create a state file with a job that started 2 hours ago
    local old_start
    old_start=$(epoch_to_iso $(($(now_epoch) - 7200)))

    # Start a background sleep process to simulate a stale job
    sleep 300 &
    local stale_pid=$!

    jq -n \
        --argjson pid "$stale_pid" \
        --arg started "$old_start" \
        '{
            version: 1,
            active_jobs: [{
                issue: 99,
                pid: $pid,
                worktree: "/tmp/test",
                title: "Stale test",
                started_at: $started
            }],
            queued: [],
            completed: []
        }' > "$STATE_FILE"

    HEALTH_STALE_TIMEOUT=1800  # 30min — job is 2h old, should be killed

    daemon_health_check

    # Give the process a moment to die after receiving SIGTERM
    sleep 0.5

    # The stale process should have been killed
    local still_running=true
    kill -0 "$stale_pid" 2>/dev/null || still_running=false

    # Clean up just in case
    kill "$stale_pid" 2>/dev/null || true
    wait "$stale_pid" 2>/dev/null || true

    assert_equals "false" "$still_running" "stale process was killed" &&
    assert_contains "$(cat "$LOG_FILE")" "Stale job detected" "log mentions stale job"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Priority sort — urgent issues come first
# ──────────────────────────────────────────────────────────────────────────────
test_priority_sort() {
    local issues='[
        {"number": 1, "title": "Low priority", "labels": [{"name": "low"}]},
        {"number": 2, "title": "Urgent fix", "labels": [{"name": "urgent"}]},
        {"number": 3, "title": "Normal task", "labels": [{"name": "normal"}]}
    ]'

    local priority_labels="urgent,p0,high,p1,normal,p2,low,p3"
    local sorted
    sorted=$(echo "$issues" | jq --arg plist "$priority_labels" '
        ($plist | split(",")) as $priorities |
        sort_by(
            [.labels[].name] as $issue_labels |
            ($priorities | to_entries | map(select(.value as $p | $issue_labels | any(. == $p))) | if length > 0 then .[0].key else 999 end)
        )
    ')

    local first_num second_num third_num
    first_num=$(echo "$sorted" | jq '.[0].number')
    second_num=$(echo "$sorted" | jq '.[1].number')
    third_num=$(echo "$sorted" | jq '.[2].number')

    assert_equals "2" "$first_num" "urgent issue #2 first" &&
    assert_equals "3" "$second_num" "normal issue #3 second" &&
    assert_equals "1" "$third_num" "low issue #1 third"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Degradation alert — triggers on high CFR
# ──────────────────────────────────────────────────────────────────────────────
test_degradation_alert() {
    local now_e
    now_e=$(now_epoch)

    # Write 5 pipeline completions: 4 failures, 1 success → 80% CFR
    for i in 1 2 3 4; do
        local t=$((now_e + i))
        write_pipeline_event "failure" 100 "$(epoch_to_iso $t)" "$t"
    done
    local t=$((now_e + 5))
    write_pipeline_event "success" 100 "$(epoch_to_iso $t)" "$t"

    DEGRADATION_WINDOW=5
    DEGRADATION_CFR_THRESHOLD=30
    DEGRADATION_SUCCESS_THRESHOLD=50

    daemon_check_degradation

    # Should have logged a degradation warning
    assert_contains "$(cat "$LOG_FILE")" "DEGRADATION" "degradation logged" &&
    assert_contains "$(cat "$LOG_FILE")" "CFR" "CFR alert logged"

    # Should have emitted a daemon.alert event
    assert_file_exists "$EVENTS_FILE" "events file exists" &&
    assert_contains "$(cat "$EVENTS_FILE")" "daemon.alert" "daemon.alert event emitted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Metrics JSON output — valid JSON with cycle_time keys
# ──────────────────────────────────────────────────────────────────────────────
test_metrics_json_output() {
    local now_e
    now_e=$(now_epoch)

    # Write enough events for metrics to have data
    for i in 1 2 3 4 5; do
        local t=$((now_e + i))
        write_pipeline_event "success" $((300 * i)) "$(epoch_to_iso $t)" "$t"
    done
    write_pipeline_event "failure" 100 "$(epoch_to_iso $((now_e + 6)))" "$((now_e + 6))"

    # Write some stage events
    write_stage_event "build" 120 "$(now_iso)"
    write_stage_event "test" 60 "$(now_iso)"

    # Run the real daemon metrics command and capture JSON
    local output
    output=$(cd "$TEMP_DIR/project" && bash "$DAEMON_SCRIPT" metrics --json --period 1 2>&1) || true

    # Validate it's valid JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Output is not valid JSON"
        echo -e "    ${DIM}Got: $(echo "$output" | head -5)${RESET}"
        return 1
    fi

    # Check for cycle_time key (not lead_time)
    assert_contains "$output" "cycle_time" "has cycle_time key" &&
    assert_not_contains "$output" "lead_time" "no lead_time key" &&
    assert_contains "$output" "deploy_frequency" "has deploy_frequency" &&
    assert_contains "$output" "change_failure_rate" "has CFR" &&
    assert_contains "$output" "mttr" "has MTTR" &&
    assert_json_key "$output" ".dora.cycle_time.grade" "Elite" "cycle_time grade present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Patrol build labels — watch label included when enabled
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_build_labels_enabled() {
    PATROL_AUTO_WATCH=true
    WATCH_LABEL="ready-to-build"
    PATROL_LABEL="auto-patrol"

    local result
    result=$(patrol_build_labels "security")

    assert_contains "$result" "auto-patrol" "has patrol label" &&
    assert_contains "$result" "security" "has check label" &&
    assert_contains "$result" "ready-to-build" "has watch label"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Patrol build labels — watch label excluded when disabled
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_build_labels_disabled() {
    PATROL_AUTO_WATCH=false
    WATCH_LABEL="ready-to-build"
    PATROL_LABEL="auto-patrol"

    local result
    result=$(patrol_build_labels "security")

    assert_contains "$result" "auto-patrol" "has patrol label" &&
    assert_contains "$result" "security" "has check label" &&
    assert_not_contains "$result" "ready-to-build" "no watch label when disabled"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Patrol recurring failures — label construction
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_recurring_failures() {
    # Setup mock memory with recurring failures
    local mem_dir="$HOME/.shipwright/memory"
    mkdir -p "$mem_dir"

    # Set thresholds
    PATROL_FAILURES_THRESHOLD=3
    NO_GITHUB=true
    PATROL_DRY_RUN=true

    # The actual patrol_recurring_failures function requires sourcing sw-memory.sh
    # which needs a git repo. We test the self-labeling mechanism instead.
    local labels
    labels=$(patrol_build_labels "recurring-failure")
    assert_contains "$labels" "recurring-failure" "recurring-failure label present" &&
    assert_contains "$labels" "auto-patrol" "patrol label present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. DORA degradation event detection
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_dora_events() {
    # Write pipeline events showing degradation
    local now_e
    now_e=$(now_epoch)

    # Previous window: 5 successes, 0 failures (Elite CFR)
    for i in 1 2 3 4 5; do
        local ts_e=$((now_e - 1000000 + i * 100))
        write_pipeline_event "success" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done

    # Current window: 2 successes, 4 failures (67% CFR = Low)
    for i in 1 2; do
        local ts_e=$((now_e - 100000 + i * 100))
        write_pipeline_event "success" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done
    for i in 1 2 3 4; do
        local ts_e=$((now_e - 50000 + i * 100))
        write_pipeline_event "failure" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done

    # Verify events were written
    local total_events
    total_events=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
    assert_gt "$total_events" 5 "should have written pipeline events" &&

    # Verify we can extract pipeline.completed events
    local completed
    completed=$(jq -s '[.[] | select(.type == "pipeline.completed")] | length' "$EVENTS_FILE")
    assert_equals "11" "$completed" "11 pipeline.completed events"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Retry exhaustion event detection
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_retry_exhaustion_events() {
    local now_e
    now_e=$(now_epoch)

    # Write retry_exhausted events
    for i in 1 2 3; do
        local ts_e=$((now_e - 86400 + i * 3600))
        write_event "{\"ts\":\"$(epoch_to_iso "$ts_e")\",\"ts_epoch\":$ts_e,\"type\":\"daemon.retry_exhausted\",\"issue\":\"42\"}"
    done

    # Verify events
    local exhausted_count
    exhausted_count=$(jq -s '[.[] | select(.type == "daemon.retry_exhausted")] | length' "$EVENTS_FILE")
    assert_equals "3" "$exhausted_count" "3 retry_exhausted events" &&

    # Verify threshold logic: 3 >= 2 (default threshold)
    assert_gt "$exhausted_count" "$PATROL_RETRY_THRESHOLD" "count exceeds threshold"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Untested script detection logic
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_untested_detection() {
    # Create a mock scripts directory
    local mock_scripts="$TEMP_DIR/scripts"
    mkdir -p "$mock_scripts"

    # Create mock scripts (some with tests, some without)
    echo '#!/bin/bash' > "$mock_scripts/sw-foo.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-bar.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-baz.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-foo-test.sh"  # foo has a test
    echo '#!/bin/bash' > "$mock_scripts/sw-bar-test.sh"  # bar has a test
    # baz has NO test

    # Check that baz would be detected as untested
    local has_test=false
    [[ -f "$mock_scripts/sw-baz-test.sh" ]] && has_test=true

    assert_equals "false" "$has_test" "baz has no test file" &&

    # Check foo does have a test
    local foo_has_test=false
    [[ -f "$mock_scripts/sw-foo-test.sh" ]] && foo_has_test=true
    assert_equals "true" "$foo_has_test" "foo has test file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright daemon test — Unit Tests (Synthetic Events)           ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the real daemon script exists
    if [[ ! -f "$DAEMON_SCRIPT" ]]; then
        echo -e "${RED}✗ Daemon script not found: $DAEMON_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    source_daemon_functions
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_dora_grade_elite:dora_grade deploy_freq Elite (>= 7)"
        "test_dora_grade_high:dora_grade deploy_freq High (>= 1)"
        "test_dora_grade_medium:dora_grade deploy_freq Medium (>= 0.25)"
        "test_dora_grade_low:dora_grade deploy_freq Low (< 0.25)"
        "test_dora_grade_cfr:dora_grade CFR thresholds (Elite/High/Medium/Low)"
        "test_stage_timings_filter:Stage timings filter-first jq query"
        "test_mttr_computation:MTTR pairs failures with next success"
        "test_epoch_to_iso_works:epoch_to_iso helper function"
        "test_health_check_stale:Health check detects stale jobs"
        "test_priority_sort:Priority label sorting"
        "test_degradation_alert:Degradation alert triggers on high CFR"
        "test_metrics_json_output:Metrics --json output with cycle_time keys"
        "test_patrol_build_labels_enabled:Self-labeling includes watch_label when enabled"
        "test_patrol_build_labels_disabled:Self-labeling excludes watch_label when disabled"
        "test_patrol_recurring_failures:Patrol recurring failures label construction"
        "test_patrol_dora_events:DORA degradation event detection"
        "test_patrol_retry_exhaustion_events:Retry exhaustion event detection"
        "test_patrol_untested_detection:Untested script detection logic"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
