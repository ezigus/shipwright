#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  ruflo-adapter — Ruflo MCP detection, lifecycle, and circuit-breaker     ║
# ║                                                                           ║
# ║  Provides optional ruflo MCP integration for the Shipwright pipeline.    ║
# ║  All functions are fail-open: never blocks the pipeline when ruflo is    ║
# ║  absent or fails. Uses circuit-breaker on timeout to disable ruflo for   ║
# ║  the remainder of the pipeline run.                                       ║
# ║                                                                           ║
# ║  Usage:                                                                   ║
# ║    [[ -f "$SCRIPT_DIR/lib/ruflo-adapter.sh" ]] \                         ║
# ║      && source "$SCRIPT_DIR/lib/ruflo-adapter.sh" 2>/dev/null || true    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

VERSION="3.3.0"

# ─── Double-source guard ──────────────────────────────────────────────────────
[[ -n "${_RUFLO_ADAPTER_LOADED:-}" ]] && return 0
_RUFLO_ADAPTER_LOADED=1

# ─── State ───────────────────────────────────────────────────────────────────
RUFLO_AVAILABLE=false
RUFLO_MCP_PID=""
RUFLO_USE_NPX=false  # true when ruflo is only available via npx (not a local binary)

# ─── Fallback helpers (no-op when helpers.sh is already sourced) ─────────────
# Use declare -f (not type) to check for shell functions only — type matches
# external binaries too, and /usr/bin/info exists on Linux.
if ! declare -f info >/dev/null 2>&1; then
    info()    { echo "▸ $*"; }
fi
if ! declare -f warn >/dev/null 2>&1; then
    warn()    { echo "⚠ $*" >&2; }
fi
if ! declare -f emit_event >/dev/null 2>&1; then
    emit_event() { :; }
fi

# ─── _ruflo_run — invoke ruflo using the runtime detected at startup ──────────
# Uses local binary when available; falls back to npx -y ruflo@latest.
# This ensures the same runtime is used for detection and lifecycle operations.
_ruflo_run() {
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        npx -y ruflo@latest "$@"
    else
        ruflo "$@"
    fi
}

# ─── _ruflo_run_quiet — invoke ruflo, suppressing only the binary's stderr ────
# Unlike adding 2>/dev/null to ruflo_with_timeout, this preserves the
# circuit-breaker's own warn() output for observability.
_ruflo_run_quiet() {
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        npx -y ruflo@latest "$@" 2>/dev/null
    else
        ruflo "$@" 2>/dev/null
    fi
}

# ─── ruflo_detect — detect ruflo availability ────────────────────────────────
# Fast path: check for local binary first, then fall back to npx.
# Sets RUFLO_AVAILABLE=true|false and RUFLO_USE_NPX=true|false.
# Returns 0 if available, 1 if not.
ruflo_detect() {
    # Fast path: local binary (~1ms)
    if command -v ruflo >/dev/null 2>&1; then
        RUFLO_AVAILABLE=true
        RUFLO_USE_NPX=false
        return 0
    fi

    # Fallback: npx (~5-10s — only runs when no local binary is found)
    # Note: -y auto-installs ruflo@latest; consider setting RUFLO_NPX_FALLBACK=0
    # to disable this path in security-sensitive or air-gapped environments.
    if command -v npx >/dev/null 2>&1; then
        if npx -y ruflo@latest mcp status &>/dev/null; then
            RUFLO_AVAILABLE=true
            RUFLO_USE_NPX=true
            return 0
        fi
    fi

    RUFLO_AVAILABLE=false
    RUFLO_USE_NPX=false
    return 1
}

# ─── ruflo_available — boolean check ─────────────────────────────────────────
# Returns 0 (true) if ruflo is available, 1 (false) otherwise.
ruflo_available() {
    [[ "${RUFLO_AVAILABLE:-false}" == "true" ]]
}

# ─── ruflo_init — initialize ruflo at pipeline start ─────────────────────────
# Detects ruflo, starts MCP server in background, imports memory (stub).
# No-op if ruflo is unavailable. Always returns 0.
ruflo_init() {
    ruflo_detect || return 0

    info "Ruflo detected — starting MCP server"
    emit_event "ruflo.init" "available=true"

    # Start MCP server in background using the same runtime as detection
    # (local binary or npx) to avoid a binary-not-found failure when ruflo
    # was found via npx but is not installed as a global command.
    if ruflo_available; then
        _ruflo_run mcp start &>/dev/null &
        RUFLO_MCP_PID=$!
        # Fixed 2s wait for the MCP server to bind its socket before the
        # liveness probe below. This is a one-time startup guard, not a
        # polling loop (testing-baseline: justified bounded sleep).
        sleep 2

        # Verify it's still running
        if ! kill -0 "$RUFLO_MCP_PID" 2>/dev/null; then
            warn "Ruflo MCP server failed to start — disabling ruflo"
            RUFLO_MCP_PID=""
            RUFLO_AVAILABLE=false
            emit_event "ruflo.init_failed" "reason=mcp_start_failed"
            return 0
        fi

        emit_event "ruflo.mcp_started" "pid=$RUFLO_MCP_PID"
    fi

    # Import memory from previous run (stub — implemented in Issue 2)
    ruflo_import_memory || true

    export RUFLO_AVAILABLE
    export RUFLO_MCP_PID
    return 0
}

# ─── ruflo_cleanup — cleanup ruflo at pipeline end ───────────────────────────
# Exports memory (stub), stops MCP server. No-op if ruflo was not active.
# Always returns 0.
ruflo_cleanup() {
    [[ -z "${RUFLO_MCP_PID:-}" ]] && return 0

    # Export memory for next run (stub — implemented in Issue 2)
    ruflo_export_memory || true

    # Stop MCP server — capture PID before clearing so the event is accurate
    if [[ -n "$RUFLO_MCP_PID" ]]; then
        local _pid="$RUFLO_MCP_PID"
        kill "$_pid" 2>/dev/null || true
        RUFLO_MCP_PID=""
        emit_event "ruflo.mcp_stopped" "pid=$_pid"
    fi

    return 0
}

# ─── ruflo_with_timeout — run a ruflo command with circuit-breaker ────────────
# On timeout or failure, sets RUFLO_AVAILABLE=false to disable ruflo for the
# remainder of the pipeline run.
# Usage: ruflo_with_timeout <seconds> <command...>
# Returns 0 on success, 1 on timeout or failure (and disables ruflo).
# Note: without a system `timeout` binary, the command runs without a time
# bound — the circuit-breaker still fires on failure but not on hang.
ruflo_with_timeout() {
    local timeout_s="${1:-30}"
    shift

    if [[ $# -eq 0 ]]; then
        return 1
    fi

    local exit_code=0

    # Use _timeout if available (from helpers.sh), fall back to timeout command
    if type _timeout >/dev/null 2>&1; then
        _timeout "$timeout_s" "$@" || exit_code=$?
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" "$@" || exit_code=$?
    else
        # No timeout binary available — run directly (no wall-clock bound)
        "$@" || exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        warn "Ruflo command timed out or failed — disabling ruflo for this run"
        RUFLO_AVAILABLE=false
        export RUFLO_AVAILABLE
        emit_event "ruflo.circuit_break" "exit_code=$exit_code"
        return 1
    fi

    return 0
}

# ─── ruflo_store — store a value in ruflo memory via CLI ─────────────────────
# Usage: ruflo_store <key> <value> [namespace] [tags]
# No-op when ruflo is unavailable. Always returns 0 (fail-open).
# On timeout, circuit-breaker disables ruflo for the remainder of the run.
ruflo_store() {
    ruflo_available || return 0
    local key="$1" value="$2" namespace="${3:-default}" tags="${4:-}"
    ruflo_with_timeout 10 _ruflo_run_quiet memory store \
        --key "$key" --value "$value" --namespace "$namespace" \
        ${tags:+--tags "$tags"} || true
}

# ─── ruflo_recall — semantic search in ruflo memory via CLI ───────────────────
# Usage: ruflo_recall <query> [namespace]
# Prints matching results to stdout. Returns empty string when ruflo unavailable.
# No-op when ruflo is unavailable. Always returns 0 (fail-open).
# On timeout, circuit-breaker disables ruflo for the remainder of the run.
ruflo_recall() {
    ruflo_available || { echo ""; return 0; }
    local query="$1" namespace="${2:-default}"
    ruflo_with_timeout 10 _ruflo_run_quiet memory search \
        --query "$query" --namespace "$namespace" --limit 3 || echo ""
}

# ─── _ruflo_repo_hash_candidates — emit candidate hashes for memory dir lookup ─
# Tries the canonical Shipwright hash (shasum -a 256 of origin URL) first, then
# falls back to sha1/md5 variants for cross-platform compatibility.
# Outputs one hash per line. No-op if origin URL cannot be determined.
_ruflo_repo_hash_candidates() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || true)
    [[ -n "$origin" ]] || return 0
    # Canonical: shasum -a 256 (matches sw-memory.sh repo_hash())
    command -v shasum  >/dev/null 2>&1 && printf '%s' "$origin" | shasum  -a 256 2>/dev/null | cut -c1-12
    # Fallbacks for non-macOS systems
    command -v sha256sum >/dev/null 2>&1 && printf '%s' "$origin" | sha256sum 2>/dev/null | cut -c1-12
    command -v sha1sum >/dev/null 2>&1 && printf '%s' "$origin" | sha1sum 2>/dev/null | cut -c1-12
}

# ─── _ruflo_shipwright_memory_dir — resolve actual memory dir for this repo ────
# Returns "<hash>:<path>" on the first candidate whose directory exists.
# Returns nothing when no matching directory is found.
_ruflo_shipwright_memory_dir() {
    local repo_hash mem_dir
    while IFS= read -r repo_hash; do
        [[ -n "$repo_hash" ]] || continue
        mem_dir="$HOME/.shipwright/memory/$repo_hash"
        if [[ -d "$mem_dir" ]]; then
            printf '%s:%s\n' "$repo_hash" "$mem_dir"
            return 0
        fi
    done < <(_ruflo_repo_hash_candidates)
}

# ─── _ruflo_resolve_repo_hash — return a deterministic repo hash ─────────────
# Returns REPO_HASH if already set by the pipeline (sw-pipeline.sh), otherwise
# derives it from the git origin URL using the same algorithm as sw-memory.sh.
# Prints the hash and returns 0 on success; prints nothing and returns 1 when
# the hash cannot be determined (e.g., no git origin, no hash tool available).
# Callers MUST skip namespace operations when this returns 1 to preserve
# repo-isolation guarantees.
_ruflo_resolve_repo_hash() {
    # Fast path: already computed and exported by the pipeline
    if [[ -n "${REPO_HASH:-}" && "${REPO_HASH}" != "unknown" ]]; then
        printf '%s' "$REPO_HASH"
        return 0
    fi
    # Slow path: derive from git origin URL (matches sw-memory.sh repo_hash())
    local _origin
    _origin=$(git config --get remote.origin.url 2>/dev/null || true)
    [[ -n "$_origin" ]] || return 1
    local _hash=""
    if command -v shasum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | shasum -a 256 2>/dev/null | cut -c1-12)
    elif command -v sha256sum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | sha256sum 2>/dev/null | cut -c1-12)
    fi
    [[ -n "$_hash" ]] || return 1
    printf '%s' "$_hash"
}

# ─── ruflo_index_shipwright_memory — index ~/.shipwright/memory/ into ruflo ───
# Indexes architecture and skill files from the repo's memory directory into
# ruflo HNSW storage for semantic retrieval by pipeline stages.
# No-op when ruflo is unavailable or memory directory is missing.
ruflo_index_shipwright_memory() {
    ruflo_available || return 0
    local repo_memory repo_hash mem_dir
    repo_memory=$(_ruflo_shipwright_memory_dir)
    if [[ -z "$repo_memory" ]]; then
        emit_event "ruflo.indexing_skipped" "reason=no_memory_dir"
        return 0
    fi
    repo_hash="${repo_memory%%:*}"
    mem_dir="${repo_memory#*:}"

    if [[ -f "$mem_dir/architecture.json" ]]; then
        local _arch_content
        _arch_content=$(jq -sR . < "$mem_dir/architecture.json" 2>/dev/null || true)
        if [[ -n "$_arch_content" ]]; then
            ruflo_store "shipwright-architecture" \
                "$_arch_content" \
                "shipwright-$repo_hash" "architecture,patterns" || true
        fi
    fi

    local f _skill_content
    for f in "$mem_dir"/skill-*.json; do
        [[ -f "$f" ]] || continue
        _skill_content=$(jq -sR . < "$f" 2>/dev/null || true)
        [[ -n "$_skill_content" ]] || continue
        ruflo_store "shipwright-$(basename "$f" .json)" \
            "$_skill_content" \
            "shipwright-$repo_hash" "skills,learning" || true
    done

    emit_event "ruflo.indexing_complete" "repo_hash=$repo_hash"
}

# ─── ruflo_import_memory — import memory from previous run ───────────────────
# Loads the last memory export into ruflo and indexes Shipwright's memory dir.
# No-op when ruflo is unavailable. Always returns 0.
ruflo_import_memory() {
    ruflo_available || return 0
    local export_file="${PROJECT_ROOT:-.}/.claude-flow/data/memory-export.json"
    if [[ -f "$export_file" ]]; then
        if ruflo_with_timeout 30 _ruflo_run_quiet memory import \
            --input "$export_file"; then
            emit_event "ruflo.import_memory_ok" "file=$export_file"
        else
            emit_event "ruflo.import_memory_failed" "file=$export_file"
        fi
    fi
    ruflo_index_shipwright_memory || true
    return 0
}

# ─── ruflo_export_memory — export memory for next run ────────────────────────
# Saves current ruflo memory to a JSON file for re-import on the next run.
# No-op when ruflo is unavailable. Always returns 0.
ruflo_export_memory() {
    ruflo_available || return 0
    local export_file="${PROJECT_ROOT:-.}/.claude-flow/data/memory-export.json"
    mkdir -p "$(dirname "$export_file")" 2>/dev/null || true
    if ruflo_with_timeout 30 _ruflo_run_quiet memory export \
        --output "$export_file"; then
        emit_event "ruflo.export_memory_ok" "file=$export_file"
    else
        emit_event "ruflo.export_memory_failed" "file=$export_file"
    fi
    return 0
}

# ─── _ruflo_resolve_repo_hash — get repo-specific hash for namespace isolation ─
# Returns $REPO_HASH if already set by pipeline, otherwise derives it on-demand
# from the git origin URL using SHA-256 (same algorithm as sw-memory.sh).
# Returns non-zero when hash cannot be determined — callers should skip.
_ruflo_resolve_repo_hash() {
    if [[ -n "${REPO_HASH:-}" && "${REPO_HASH}" != "unknown" ]]; then
        printf '%s' "$REPO_HASH"
        return 0
    fi
    local _origin
    _origin=$(git config --get remote.origin.url 2>/dev/null || true)
    [[ -n "$_origin" ]] || return 1
    local _hash=""
    if command -v shasum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | shasum -a 256 2>/dev/null | cut -c1-12)
    elif command -v sha256sum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | sha256sum 2>/dev/null | cut -c1-12)
    fi
    [[ -n "$_hash" ]] || return 1
    printf '%s' "$_hash"
}

# ─── ruflo_execute_build_single — execute build via a single ruflo agent ─────
# Spawns a ruflo agent to execute the build goal in single-agent mode.
# Provides a lighter-weight alternative to the full sw loop for simple tasks.
# Usage: ruflo_execute_build_single <goal> [max_turns]
# Returns 0 on success, 1 on failure. Caller is expected to fall back to sw loop.
# No-op (returns 1) when ruflo is unavailable — always fails open to sw loop.
# Uses ruflo_with_timeout circuit-breaker: 10-minute wall-clock bound.
#
# Note: calls the ruflo binary directly (not via _ruflo_run_quiet) so the
# invocation is a real external command that the system timeout binary can
# exec. Shell functions cannot be exec'd by timeout directly.
ruflo_execute_build_single() {
    ruflo_available || return 1
    local goal="$1"
    local max_turns="${2:-30}"
    [[ -n "$goal" ]] || return 1

    emit_event "ruflo.build_agent_start" "max_turns=$max_turns"

    # Call the binary directly — system timeout cannot exec shell functions.
    # On failure (including if 'agent spawn' is unsupported), returns 1 so
    # the caller falls back to sw loop.
    local _exit_code=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 600 npx -y ruflo@latest agent spawn \
            --goal "$goal" --max-turns "$max_turns" || _exit_code=$?
    else
        ruflo_with_timeout 600 ruflo agent spawn \
            --goal "$goal" --max-turns "$max_turns" || _exit_code=$?
    fi

    if [[ $_exit_code -eq 0 ]]; then
        emit_event "ruflo.build_agent_complete" "success=true"
        return 0
    fi
    emit_event "ruflo.build_agent_failed" "success=false"
    return 1
}

# ─── _ruflo_hive_shutdown — tear down a hive-mind session safely ─────────────
# Sends shutdown to the hive identified by $1. Swallows errors — cleanup is
# best-effort only; the pipeline must not fail on teardown failure.
# Uses ruflo_with_timeout with a short bound so a hung ruflo can't stall the
# pipeline during cleanup.
# Always returns 0.
_ruflo_hive_shutdown() {
    local hive_id="${1:-}"
    [[ -n "$hive_id" ]] || return 0
    local _shutdown_timeout="${RUFLO_HIVE_SHUTDOWN_TIMEOUT_SECONDS:-15}"
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout "$_shutdown_timeout" \
            npx -y ruflo@latest hive-mind shutdown --hive-id "$hive_id" \
            >/dev/null 2>&1 || true
    else
        ruflo_with_timeout "$_shutdown_timeout" \
            ruflo hive-mind shutdown --hive-id "$hive_id" \
            >/dev/null 2>&1 || true
    fi
    return 0
}

# ─── ruflo_execute_build_hive — execute build via a ruflo hive-mind swarm ────
# Spawns a hierarchical multi-agent hive to execute the build goal in parallel.
# Uses Q-learning via hooks_route to select the optimal agent count and topology.
# Falls back gracefully: any init/spawn/orchestrate failure causes the function
# to return 1, letting the caller fall back to single-agent or sw loop.
#
# Environment knobs:
#   RUFLO_HIVE_MAX_AGENTS  — hard cap on parallel agents (default 4)
#   RUFLO_HIVE_TOPOLOGY    — force topology (default: hierarchical)
#   RUFLO_USE_NPX          — use npx instead of installed ruflo binary
#
# Usage: ruflo_execute_build_hive <goal> [max_turns]
# Returns 0 on success, 1 on failure (caller falls back). Fail-open design.
#
# Note: calls hive-mind/agent binaries directly (not via _ruflo_run_quiet) so
# the invocations are real external commands the system timeout binary can exec.
ruflo_execute_build_hive() {
    ruflo_available || return 1
    local goal="$1"
    local max_turns="${2:-30}"
    [[ -n "$goal" ]] || return 1

    local max_agents="${RUFLO_HIVE_MAX_AGENTS:-4}"
    local topology="${RUFLO_HIVE_TOPOLOGY:-hierarchical}"

    emit_event "ruflo.hive_build_start" \
        "max_agents=$max_agents" "topology=$topology" "max_turns=$max_turns"

    # Q-learning agent selection: ask hooks_route for recommended agent count/
    # topology based on historical performance. Use defaults on any failure.
    # JSON is built with jq --arg to safely handle quotes/newlines in goal.
    local _route_context
    _route_context=$(jq -n \
        --arg goal "$goal" \
        --argjson max_agents "$max_agents" \
        '{goal:$goal,max_agents:$max_agents}' 2>/dev/null || true)
    local _route_json=""
    if [[ -n "$_route_context" ]]; then
        if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
            _route_json=$(npx -y ruflo@latest hooks route \
                --event "build.start" \
                --context "$_route_context" \
                2>/dev/null || true)
        else
            _route_json=$(ruflo hooks route \
                --event "build.start" \
                --context "$_route_context" \
                2>/dev/null || true)
        fi
    fi

    if [[ -n "$_route_json" ]]; then
        local _recommended_agents
        _recommended_agents=$(printf '%s' "$_route_json" | \
            jq -r '.agent_count // empty' 2>/dev/null || true)
        # Validate _recommended_agents is a non-negative integer before numeric compare
        if [[ "$_recommended_agents" =~ ^[0-9]+$ && "$_recommended_agents" -le "$max_agents" ]]; then
            max_agents="$_recommended_agents"
        fi
        local _recommended_topology
        _recommended_topology=$(printf '%s' "$_route_json" | \
            jq -r '.topology // empty' 2>/dev/null || true)
        [[ -n "$_recommended_topology" ]] && topology="$_recommended_topology"
    fi

    # Initialize the hive-mind session — wrapped in ruflo_with_timeout so a hung
    # init command doesn't stall the build stage indefinitely.
    local hive_id=""
    local _init_out
    local _init_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _init_out=$(ruflo_with_timeout 30 npx -y ruflo@latest hive-mind init \
            --topology "$topology" \
            --max-agents "$max_agents" \
            --output-format json 2>/dev/null) || _init_exit=$?
    else
        _init_out=$(ruflo_with_timeout 30 ruflo hive-mind init \
            --topology "$topology" \
            --max-agents "$max_agents" \
            --output-format json 2>/dev/null) || _init_exit=$?
    fi
    [[ $_init_exit -eq 0 ]] && \
        hive_id=$(printf '%s' "$_init_out" | jq -r '.hive_id // empty' 2>/dev/null || true)

    if [[ $_init_exit -ne 0 || -z "$hive_id" ]]; then
        emit_event "ruflo.hive_init_failed" "topology=$topology"
        return 1
    fi

    # Spawn worker agents — spawn failures are fatal: any non-zero exit triggers
    # hive shutdown and causes the function to return 1 (caller falls back).
    local _spawn_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 60 npx -y ruflo@latest hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role "worker" 2>/dev/null || _spawn_exit=$?
    else
        ruflo_with_timeout 60 ruflo hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role "worker" 2>/dev/null || _spawn_exit=$?
    fi

    if [[ $_spawn_exit -ne 0 ]]; then
        warn "Ruflo hive spawn failed (hive_id=$hive_id) — aborting hive build"
        emit_event "ruflo.hive_spawn_failed" "hive_id=$hive_id"
        _ruflo_hive_shutdown "$hive_id"
        return 1
    fi

    # Orchestrate the build goal across the hive
    local _orch_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 600 npx -y ruflo@latest coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "$goal" \
            --max-turns "$max_turns" \
            --mode "pipeline" 2>/dev/null || _orch_exit=$?
    else
        ruflo_with_timeout 600 ruflo coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "$goal" \
            --max-turns "$max_turns" \
            --mode "pipeline" 2>/dev/null || _orch_exit=$?
    fi

    # Always shut down the hive regardless of outcome
    _ruflo_hive_shutdown "$hive_id"

    if [[ $_orch_exit -eq 0 ]]; then
        emit_event "ruflo.hive_build_complete" \
            "hive_id=$hive_id" "agents=$max_agents" "topology=$topology"
        return 0
    fi

    emit_event "ruflo.hive_build_failed" \
        "hive_id=$hive_id" "exit_code=$_orch_exit"
    return 1
}

# ─── ruflo_learn_from_shipwright — bridge Shipwright outcomes to ruflo ───────
# Called after skill_memory_record() writes an outcome. Accepts either a path
# to an outcome JSON file or a raw JSON string, then indexes the outcome into
# ruflo HNSW under a repo-specific namespace for vector-similarity search.
# No-op when ruflo unavailable, input is empty/invalid, or repo hash cannot
# be determined. Always returns 0 (fail-open).
ruflo_learn_from_shipwright() {
    ruflo_available || return 0
    local outcome_source="${1:-}"
    [[ -n "$outcome_source" ]] || return 0

    # Resolve repo hash — skip if unavailable to prevent namespace cross-pollution
    local _ns_hash
    _ns_hash=$(_ruflo_resolve_repo_hash) || return 0

    local _key="shipwright-outcome-$(date +%s)-$$"
    local _task_type="unknown"
    local _content=""

    if [[ -f "$outcome_source" ]]; then
        # Input is a file path — read task_type (fall back to issue_type for
        # Shipwright records that use issue_type as the canonical field name)
        _task_type=$(jq -r '.task_type // .issue_type // "unknown"' \
            "$outcome_source" 2>/dev/null || echo "unknown")
        _content=$(jq -sR . < "$outcome_source" 2>/dev/null || true)
    else
        # Input is a raw JSON string
        _task_type=$(printf '%s\n' "$outcome_source" | \
            jq -r '.task_type // .issue_type // "unknown"' 2>/dev/null || echo "unknown")
        _content=$(printf '%s\n' "$outcome_source" | jq -c . 2>/dev/null || true)
    fi

    [[ -n "$_content" ]] || return 0
    ruflo_store "$_key" "$_content" \
        "learning-$_ns_hash" \
        "skill-memory,outcome,$_task_type" || true
    emit_event "ruflo.learn_from_shipwright" \
        "task_type=$_task_type" \
        "repo=$_ns_hash"
    return 0
}

# ─── ruflo_recall_similar_outcomes — query ruflo for vector-similar past outcomes
# Supplements Shipwright's file-based skill selection with semantic vector search.
# Returns matching outcomes to stdout. Returns empty string when unavailable or
# when repo hash cannot be determined (to prevent cross-repo namespace pollution).
ruflo_recall_similar_outcomes() {
    ruflo_available || { echo ""; return 0; }
    local task_type="$1" issue_labels="${2:-}"
    local _ns_hash
    _ns_hash=$(_ruflo_resolve_repo_hash) || { echo ""; return 0; }
    ruflo_recall "skill selection for ${task_type} ${issue_labels}" \
        "learning-$_ns_hash"
    return 0
}

# ─── ruflo_index_adr_artifacts — index pipeline ADR artifacts into ruflo ────
# Indexes design-stage ADR files so review and build stages can query them for
# architectural compliance checking. Uses repo-specific namespace.
# No-op when ruflo unavailable, no ADR files found, or repo hash unavailable.
# Content is bounded to RUFLO_ADR_INDEX_MAX_BYTES (default 4000) to avoid
# exceeding argv limits and tripping the circuit-breaker on large files.
# Always returns 0 (fail-open).
ruflo_index_adr_artifacts() {
    ruflo_available || return 0
    local _ns_hash
    _ns_hash=$(_ruflo_resolve_repo_hash) || return 0
    local artifacts_dir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    [[ -d "$artifacts_dir" ]] || return 0
    local _max_bytes="${RUFLO_ADR_INDEX_MAX_BYTES:-4000}"
    local _count=0
    local adr _key _content
    for adr in "$artifacts_dir"/design*.md "$artifacts_dir"/adr*.md; do
        [[ -f "$adr" ]] || continue
        _key="adr-$(basename "$adr" .md)-${SHIPWRIGHT_PIPELINE_ID:-unknown}"
        _content=$(head -c "$_max_bytes" "$adr" 2>/dev/null | jq -sR . 2>/dev/null || true)
        [[ -n "$_content" ]] || continue
        ruflo_store "$_key" "$_content" \
            "adrs-$_ns_hash" "adr,architecture" || true
        _count=$(( _count + 1 ))
    done
    [[ "$_count" -gt 0 ]] && \
        emit_event "ruflo.adr_indexed" "count=$_count" "repo=$_ns_hash" || true
    return 0
}
