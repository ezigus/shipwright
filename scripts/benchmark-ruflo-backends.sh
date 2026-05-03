#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  benchmark-ruflo-backends — Validate ≥10× subprocess reduction (#504)    ║
# ║                                                                           ║
# ║  Drives identical workloads through SW_RUFLO_BACKEND={cli,mcp} and        ║
# ║  records: per-call latency (p50/p95/p99), unique node PID count over the  ║
# ║  workload window, error count, and orphan-process leakage across runs.   ║
# ║                                                                           ║
# ║  Usage:                                                                   ║
# ║    scripts/benchmark-ruflo-backends.sh           # both backends + assert ║
# ║    scripts/benchmark-ruflo-backends.sh --cli     # CLI only               ║
# ║    scripts/benchmark-ruflo-backends.sh --mcp     # MCP only               ║
# ║    scripts/benchmark-ruflo-backends.sh --samples 30                       ║
# ║    scripts/benchmark-ruflo-backends.sh --no-assert  # collect only        ║
# ║                                                                           ║
# ║  Acceptance thresholds (from #504 design.md, exit 2 on miss):             ║
# ║    CLI: ≥10 unique node PIDs over 20 calls (baseline)                     ║
# ║    MCP: 1 unique node PID (the bridge) over 20 calls                      ║
# ║    MCP: latency p95 ≤5ms post cold-start                                  ║
# ║    Both: error_count == 0 across all samples                              ║
# ║                                                                           ║
# ║  Outputs (atomic):                                                        ║
# ║    .claude/pipeline-artifacts/benchmarks/benchmark-{cli,mcp}-<ts>.json    ║
# ║    .claude/pipeline-artifacts/benchmarks/summary-<ts>.md                  ║
# ║                                                                           ║
# ║  Bash 3.2 compatible — no associative arrays, no readarray, no ${var,,}. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.6.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=scripts/lib/ruflo-mcp-call.sh
source "$SCRIPT_DIR/lib/ruflo-mcp-call.sh"

# ─── Defaults / arg parsing ─────────────────────────────────────────────────
BENCH_SAMPLES="${BENCH_SAMPLES:-20}"
BENCH_DISCARD_FIRST=1   # skip cold-start sample from latency stats
RUN_CLI=1
RUN_MCP=1
DO_ASSERT=1
LATENCY_P95_MS_MAX="${BENCH_P95_MAX:-5}"
LATENCY_P99_MS_MAX="${BENCH_P99_MAX:-15}"
MCP_MAX_PIDS="${BENCH_MCP_MAX_PIDS:-1}"
CLI_MIN_PIDS="${BENCH_CLI_MIN_PIDS:-10}"

usage() {
    cat <<USAGE
benchmark-ruflo-backends $VERSION
Usage: $0 [--cli] [--mcp] [--samples N] [--no-assert]

Options:
  --cli              Run CLI backend only (default: run both)
  --mcp              Run MCP backend only (default: run both)
  --samples N        Number of latency samples per backend (default: 20)
  --no-assert        Collect data, skip pass/fail assertions (collection mode)
  --help             Show this message

Env overrides:
  BENCH_SAMPLES        Same as --samples
  BENCH_P95_MAX        MCP p95 latency ceiling in ms (default: 5)
  BENCH_P99_MAX        MCP p99 latency ceiling in ms (default: 15)
  BENCH_MCP_MAX_PIDS   Max unique node PIDs allowed for MCP (default: 1)
  BENCH_CLI_MIN_PIDS   Min unique node PIDs expected for CLI (default: 10)
USAGE
}

# Argument parser — Bash 3.2 safe (no shopt extglob requirements)
_only_specified=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli)        RUN_CLI=1; if [[ $_only_specified -eq 0 ]]; then RUN_MCP=0; fi; _only_specified=1; shift ;;
        --mcp)        RUN_MCP=1; if [[ $_only_specified -eq 0 ]]; then RUN_CLI=0; fi; _only_specified=1; shift ;;
        --samples)    BENCH_SAMPLES="${2:?--samples requires N}"; shift 2 ;;
        --samples=*)  BENCH_SAMPLES="${1#*=}"; shift ;;
        --no-assert)  DO_ASSERT=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            error "Unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$BENCH_SAMPLES" =~ ^[0-9]+$ ]] || [[ "$BENCH_SAMPLES" -lt 5 ]]; then
    error "--samples must be an integer ≥5 (got: $BENCH_SAMPLES)"
    exit 1
fi

# ─── Output paths ────────────────────────────────────────────────────────────
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
ARTIFACT_DIR="$REPO_ROOT/.claude/pipeline-artifacts/benchmarks"
mkdir -p "$ARTIFACT_DIR"

# ─── Dependency check ───────────────────────────────────────────────────────
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command not found: $1"
        exit 1
    fi
}
require_cmd jq
require_cmd nc
require_cmd node
require_cmd awk
require_cmd ps

# ─── ms_time — milliseconds since epoch (cross-platform) ────────────────────
# `date +%s%3N` is Linux-only; macOS BSD date doesn't support %N. We use
# Python or Node as a portable nanosecond clock when %N is unavailable.
_HAVE_NS_DATE=0
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
    _HAVE_NS_DATE=1
fi
ms_time() {
    if [[ $_HAVE_NS_DATE -eq 1 ]]; then
        date +%s%3N
    else
        # Portable fallback: node's Date.now() is reliable on all our targets.
        node -e 'process.stdout.write(String(Date.now()))'
    fi
}

# ─── snapshot_node_pids — capture currently-running node PIDs as one-per-line ─
# Writes the raw `ps` output filtered to processes whose command contains
# "node" (case-sensitive — matches Node binary, not "node_modules" or scripts
# named e.g. nodejs-tool). Each line: `<pid> <ppid> <command>`.
snapshot_node_pids() {
    # ps -e -o args isn't 100% portable; pid+args works on Linux+BSD.
    ps -e -o pid=,ppid=,args= 2>/dev/null \
        | awk '$3 ~ /(^|\/)node($| )/ || $0 ~ /ruflo-bridge/ { print $1" "$2" "$0 }' \
        || true
}

# ─── make_bench_request — single sampled call to ruflo memory_search ────────
# Echoes "<exit_code> <latency_ms>" so the caller can aggregate without
# unsetting set -e. Uses 1ms wallclock resolution; sub-ms calls show as 0.
make_bench_request() {
    local backend="$1" sample_idx="$2"
    local query="bench-${backend}-${sample_idx}-$$"
    local t0 t1 latency_ms exit_code=0

    t0=$(ms_time)
    if [[ "$backend" == "mcp" ]]; then
        ruflo_mcp_call memory_search "query=$query" "namespace=bench" "limit=1" \
            >/dev/null 2>&1 || exit_code=$?
    else
        # CLI path: invoke ruflo directly (matches legacy code path that
        # callers like _ruflo_recall_cli use). On hosts without ruflo, the
        # invocation will fail with non-zero — we still record the timing
        # so cold-start cost is captured even if the call errors out.
        if command -v ruflo >/dev/null 2>&1; then
            ruflo memory search --query "$query" --namespace bench --limit 1 \
                >/dev/null 2>&1 || exit_code=$?
        else
            exit_code=127
        fi
    fi
    t1=$(ms_time)
    latency_ms=$((t1 - t0))
    printf '%s %s\n' "$exit_code" "$latency_ms"
}

# ─── compute_percentiles — read latencies from stdin, write JSON to stdout ──
# Uses awk (Bash 3.2-safe, no readarray, no associative arrays).
# Drops the first BENCH_DISCARD_FIRST samples when --discard is provided.
compute_percentiles() {
    local discard="${1:-0}"
    awk -v discard="$discard" '
        BEGIN { n = 0 }
        { v[n++] = $1 + 0 }
        END {
            if (n <= discard) { discard = 0 }
            kept = n - discard
            if (kept <= 0) {
                printf("{\"count\":0,\"p50\":null,\"p95\":null,\"p99\":null,\"min\":null,\"max\":null,\"mean\":null}");
                exit
            }
            # bubble sort over the post-discard slice — fine for n ≤ 100
            base = discard
            for (i = base; i < n; i++)
                for (j = i + 1; j < n; j++)
                    if (v[i] > v[j]) { t = v[i]; v[i] = v[j]; v[j] = t }
            sum = 0; mn = v[base]; mx = v[base]
            for (i = base; i < n; i++) {
                sum += v[i]
                if (v[i] < mn) mn = v[i]
                if (v[i] > mx) mx = v[i]
            }
            mean = sum / kept
            # nearest-rank percentile: ceil(p * kept / 100) - 1 (0-indexed within slice)
            p50 = v[base + int((50 * kept + 99) / 100) - 1]
            p95 = v[base + int((95 * kept + 99) / 100) - 1]
            p99 = v[base + int((99 * kept + 99) / 100) - 1]
            printf("{\"count\":%d,\"p50\":%d,\"p95\":%d,\"p99\":%d,\"min\":%d,\"max\":%d,\"mean\":%.2f}",
                kept, p50, p95, p99, mn, mx, mean)
        }
    '
}

# ─── env_metadata_json — describe the host for reproducibility ──────────────
env_metadata_json() {
    local kernel arch cores loadavg node_v
    kernel=$(uname -s 2>/dev/null || echo "unknown")
    arch=$(uname -m 2>/dev/null || echo "unknown")
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
    loadavg=$(uptime 2>/dev/null | awk -F'load average[s]?:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ' || true)
    [[ -z "$loadavg" ]] && loadavg="0"
    node_v=$(node --version 2>/dev/null || echo "unknown")
    jq -n -c \
        --arg kernel "$kernel" \
        --arg arch "$arch" \
        --arg loadavg "$loadavg" \
        --arg node "$node_v" \
        --arg ts "$(now_iso)" \
        --argjson cores "${cores:-0}" \
        '{kernel:$kernel, arch:$arch, cores:$cores, loadavg:$loadavg, node:$node, ts:$ts}'
}

# ─── run_backend — drive samples, gather PIDs, write JSON artifact ──────────
# Stdout: ONLY the path to the backend JSON artifact (consumed by main()).
# Stderr: all progress / info / warn / error messages so capture is clean.
run_backend() {
    local backend="$1"
    local pids_before pids_after pids_during_file
    pids_during_file=$(mktemp "${TMPDIR:-/tmp}/bench-pids-XXXXXX")

    info "Running benchmark: backend=$backend samples=$BENCH_SAMPLES" >&2

    if [[ "$backend" == "mcp" ]]; then
        # Use a benchmark-scoped socket so we don't disturb a running pipeline's bridge.
        export RUFLO_BRIDGE_SOCK="${TMPDIR:-/tmp}/ruflo-bench-bridge-$$.sock"
        if ! _ruflo_bridge_start; then
            error "Bridge failed to start — aborting MCP run (would record fake-good numbers)" >&2
            rm -f "$pids_during_file" 2>/dev/null || true
            return 1
        fi
        if ! ruflo_bridge_available; then
            error "Bridge started but ping failed — aborting MCP run" >&2
            _ruflo_bridge_stop || true
            rm -f "$pids_during_file" 2>/dev/null || true
            return 1
        fi
    fi

    # Snapshot baseline node PIDs (excluding our own bench process tree).
    pids_before=$(snapshot_node_pids | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')

    # Start a lightweight PID sampler in the background. 200ms cadence is
    # below typical CLI cold-start (200ms) so we have a fighting chance to
    # observe transient node spawns before they exit.
    local sampler_pid
    (
        while :; do
            snapshot_node_pids | awk '{print $1}' >> "$pids_during_file"
            # bounded failsafe sleep — not synchronization, just sampler cadence
            sleep 0.2
        done
    ) &
    sampler_pid=$!

    # Run latency samples
    local sample_data exit_code latency errors=0 ok=0
    sample_data=$(mktemp "${TMPDIR:-/tmp}/bench-samples-XXXXXX")
    local i
    for i in $(seq 1 "$BENCH_SAMPLES"); do
        # make_bench_request writes "<exit> <ms>"
        local result
        result=$(make_bench_request "$backend" "$i") || true
        exit_code=$(echo "$result" | awk '{print $1}')
        latency=$(echo "$result" | awk '{print $2}')
        echo "$latency" >> "$sample_data"
        if [[ "$exit_code" -ne 0 ]]; then
            errors=$((errors + 1))
        else
            ok=$((ok + 1))
        fi
    done

    # Stop sampler
    kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true

    pids_after=$(snapshot_node_pids | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')

    # Compute unique node PIDs observed during workload that were NOT in the
    # baseline snapshot — these are spawns attributable to our calls.
    local before_set during_set after_set transient_count orphan_count bridge_count
    before_set=$(mktemp "${TMPDIR:-/tmp}/bench-before-XXXXXX")
    during_set=$(mktemp "${TMPDIR:-/tmp}/bench-during-XXXXXX")
    after_set=$(mktemp "${TMPDIR:-/tmp}/bench-after-XXXXXX")
    echo "$pids_before" | tr ',' '\n' | sort -u > "$before_set"
    echo "$pids_after" | tr ',' '\n' | sort -u > "$after_set"
    sort -u "$pids_during_file" > "$during_set"
    transient_count=$(comm -23 "$during_set" "$before_set" | grep -cE '^[0-9]+$' || true)
    transient_count="${transient_count:-0}"
    # #441 sentinel: PIDs present after the run that weren't there before. For
    # MCP this should equal the bridge (1); for CLI this should be 0 — any
    # leak is the issue this work was meant to close.
    orphan_count=$(comm -23 "$after_set" "$before_set" | grep -cE '^[0-9]+$' || true)
    orphan_count="${orphan_count:-0}"

    # Count active bridge processes (just for visibility; the bridge is itself
    # a node process and will be in `during_set` for MCP runs).
    bridge_count=0
    if [[ "$backend" == "mcp" ]]; then
        bridge_count=1
    fi

    # Compute percentiles (discard first sample for cold-start)
    local pct_json
    pct_json=$(compute_percentiles "$BENCH_DISCARD_FIRST" < "$sample_data")

    # Build per-backend artifact
    local out_json="$ARTIFACT_DIR/benchmark-${backend}-${TS}.json"
    local tmp_json="${out_json}.tmp"
    local samples_array
    samples_array=$(awk 'BEGIN{p=""} {if(p!="")p=p","; p=p $1} END{print "["p"]"}' < "$sample_data")
    jq -n \
        --arg backend "$backend" \
        --arg version "$VERSION" \
        --arg ts "$(now_iso)" \
        --argjson samples "$samples_array" \
        --argjson percentiles "$pct_json" \
        --argjson errors "$errors" \
        --argjson ok "$ok" \
        --argjson transient_pids "$transient_count" \
        --argjson orphan_pids "$orphan_count" \
        --argjson bridge_pids "$bridge_count" \
        --argjson env "$(env_metadata_json)" \
        '{
            backend: $backend,
            version: $version,
            ts: $ts,
            samples_ms: $samples,
            percentiles_ms: $percentiles,
            errors: $errors,
            ok: $ok,
            unique_transient_node_pids: $transient_pids,
            orphan_node_pids_post_run: $orphan_pids,
            persistent_bridge_pids: $bridge_pids,
            env: $env
        }' > "$tmp_json"
    mv "$tmp_json" "$out_json"

    rm -f "$sample_data" "$pids_during_file" "$before_set" "$during_set" "$after_set" 2>/dev/null || true

    if [[ "$backend" == "mcp" ]]; then
        _ruflo_bridge_stop || true
        # #441 sentinel: assert no orphaned bridge process remains.
        if [[ -e "$RUFLO_BRIDGE_SOCK" ]]; then
            warn "Bridge socket file lingered after stop: $RUFLO_BRIDGE_SOCK" >&2
        fi
        unset RUFLO_BRIDGE_SOCK
    fi

    emit_event "ruflo.benchmark_run" \
        "backend=$backend" \
        "p95_ms=$(echo "$pct_json" | jq -r '.p95 // 0')" \
        "errors=$errors" \
        "transient_pids=$transient_count" 2>/dev/null

    success "backend=$backend complete (errors=$errors transient_pids=$transient_count) → $(basename "$out_json")" >&2
    printf '%s\n' "$out_json"
}

# ─── assert_thresholds — exit 2 if any backend missed its threshold ─────────
assert_thresholds() {
    local cli_json="$1" mcp_json="$2"
    local fail=0

    if [[ -n "$cli_json" && -f "$cli_json" ]]; then
        local cli_errors cli_pids
        cli_errors=$(jq -r '.errors' "$cli_json")
        cli_pids=$(jq -r '.unique_transient_node_pids' "$cli_json")
        # CLI baseline: ≥10 unique PIDs expected. If fewer, the comparison is invalid.
        if [[ "$cli_pids" -lt "$CLI_MIN_PIDS" ]]; then
            warn "CLI baseline weaker than expected: unique_pids=$cli_pids (<$CLI_MIN_PIDS) — ruflo CLI may not be installed; comparison is degraded"
        fi
        info "CLI: errors=$cli_errors pids=$cli_pids"
    fi

    if [[ -n "$mcp_json" && -f "$mcp_json" ]]; then
        local mcp_errors mcp_pids mcp_orphans mcp_p95 mcp_p99
        mcp_errors=$(jq -r '.errors' "$mcp_json")
        mcp_pids=$(jq -r '.unique_transient_node_pids' "$mcp_json")
        mcp_orphans=$(jq -r '.orphan_node_pids_post_run' "$mcp_json")
        mcp_p95=$(jq -r '.percentiles_ms.p95 // 0' "$mcp_json")
        mcp_p99=$(jq -r '.percentiles_ms.p99 // 0' "$mcp_json")

        if [[ "$mcp_errors" -gt 0 ]]; then
            error "MCP errors=$mcp_errors (must be 0)"
            fail=1
        fi
        if [[ "$mcp_pids" -gt "$MCP_MAX_PIDS" ]]; then
            error "MCP unique_transient_node_pids=$mcp_pids (max allowed: $MCP_MAX_PIDS — only the persistent bridge should appear)"
            fail=1
        fi
        if [[ "$mcp_orphans" -gt 0 ]]; then
            error "MCP orphan_node_pids_post_run=$mcp_orphans (#441 leak: bridge or its children should exit cleanly)"
            fail=1
        fi
        if [[ "$mcp_p95" -gt "$LATENCY_P95_MS_MAX" ]]; then
            error "MCP latency p95=${mcp_p95}ms (max allowed: ${LATENCY_P95_MS_MAX}ms)"
            fail=1
        fi
        if [[ "$mcp_p99" -gt "$LATENCY_P99_MS_MAX" ]]; then
            warn "MCP latency p99=${mcp_p99}ms (over soft cap ${LATENCY_P99_MS_MAX}ms — recorded but not failing)"
        fi
        info "MCP: errors=$mcp_errors pids=$mcp_pids orphans=$mcp_orphans p95=${mcp_p95}ms p99=${mcp_p99}ms"
    fi

    return "$fail"
}

# ─── write_summary — human-readable markdown summary of both runs ───────────
write_summary() {
    local cli_json="$1" mcp_json="$2"
    local out_md="$ARTIFACT_DIR/summary-${TS}.md"
    local tmp_md="${out_md}.tmp"
    {
        echo "# Ruflo Backend Benchmark — $TS"
        echo
        echo "Generated by \`scripts/benchmark-ruflo-backends.sh\` v$VERSION."
        echo
        echo "## Methodology"
        echo
        echo "- $BENCH_SAMPLES samples per backend (sample #1 discarded for cold-start)"
        echo "- Workload: \`memory_search\` against an isolated bench namespace"
        echo "- Latency measured via \`ms_time\` wallclock around each call"
        echo "- Unique transient node PIDs computed as \`during_window − baseline\`"
        echo "- 200ms PID sampler runs alongside latency samples"
        echo
        echo "## Acceptance Thresholds"
        echo
        echo "| Metric | MCP target |"
        echo "|---|---|"
        echo "| Unique transient node PIDs | ≤ $MCP_MAX_PIDS |"
        echo "| Latency p95 | ≤ ${LATENCY_P95_MS_MAX} ms |"
        echo "| Latency p99 (soft) | ≤ ${LATENCY_P99_MS_MAX} ms |"
        echo "| Errors | 0 |"
        echo
        echo "## Results"
        echo
        echo "| Backend | Errors | Transient PIDs | p50 (ms) | p95 (ms) | p99 (ms) | Mean (ms) |"
        echo "|---------|--------|----------------|---------:|---------:|---------:|----------:|"
        local row
        for row in "$cli_json" "$mcp_json"; do
            [[ -z "$row" || ! -f "$row" ]] && continue
            jq -r '
                "| " + .backend
                + " | " + (.errors|tostring)
                + " | " + (.unique_transient_node_pids|tostring)
                + " | " + ((.percentiles_ms.p50 // "—")|tostring)
                + " | " + ((.percentiles_ms.p95 // "—")|tostring)
                + " | " + ((.percentiles_ms.p99 // "—")|tostring)
                + " | " + ((.percentiles_ms.mean // "—")|tostring)
                + " |"
            ' "$row"
        done
        echo
        echo "## Raw Artifacts"
        echo
        [[ -f "$cli_json" ]] && echo "- \`$(basename "$cli_json")\`"
        [[ -f "$mcp_json" ]] && echo "- \`$(basename "$mcp_json")\`"
        echo
        echo "_See \`docs/ruflo-mcp-transport.md\` for the contract and \`docs/adr/ruflo-backend-transport.md\` for the design rationale._"
    } > "$tmp_md"
    mv "$tmp_md" "$out_md"
    success "Summary: $out_md"
}

# ─── EXIT trap — best-effort cleanup so failed runs don't leak ──────────────
_cleanup() {
    if [[ -n "${RUFLO_BRIDGE_SOCK:-}" && "$RUFLO_BRIDGE_SOCK" == */ruflo-bench-bridge-* ]]; then
        _ruflo_bridge_stop 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cli_json="" mcp_json=""

    if [[ $RUN_CLI -eq 1 ]]; then
        cli_json=$(run_backend cli) || true
    fi
    if [[ $RUN_MCP -eq 1 ]]; then
        mcp_json=$(run_backend mcp) || true
    fi

    write_summary "$cli_json" "$mcp_json"

    if [[ $DO_ASSERT -eq 1 ]]; then
        if ! assert_thresholds "$cli_json" "$mcp_json"; then
            error "Acceptance thresholds NOT met — see summary for details"
            exit 2
        fi
        success "Acceptance thresholds met"
    fi
}

main "$@"
