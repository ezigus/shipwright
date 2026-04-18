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
# Use ${VAR:-default} to preserve values inherited from a parent process (e.g.
# sw-pipeline.sh) when ruflo-adapter.sh is sourced in a subprocess like sw-loop.sh.
RUFLO_AVAILABLE="${RUFLO_AVAILABLE:-false}"
RUFLO_USE_NPX="${RUFLO_USE_NPX:-false}"        # true when ruflo is only available via npx (not a local binary)
RUFLO_DAEMON_STARTED="${RUFLO_DAEMON_STARTED:-false}" # true only when THIS run started the daemon via ruflo start --daemon
RUFLO_FAILURE_COUNT="${RUFLO_FAILURE_COUNT:-0}"      # incremented by circuit-breaker; reset on recovery
export RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_FAILURE_COUNT

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

# ─── ruflo_load_defaults — load project-level ruflo config ───────────────────
# Reads .shipwright/defaults.json (repo-local, higher priority) or
# ~/.shipwright/defaults.json (user-global fallback) and exports config vars.
# No-op when neither file exists. Always returns 0 (fail-open).
# Variables exported when present in the file:
#   RUFLO_MAX_AGENTS            — hard cap on parallel agents across all hives
#   RUFLO_COST_BUDGET_MULTIPLIER — multiplier applied to per-stage cost budget
#   RUFLO_CIRCUIT_BREAKER_TIMEOUT — default ruflo_with_timeout seconds
#   RUFLO_LEARNING_BRIDGE       — enable/disable ruflo<->Shipwright learning bridge
#   RUFLO_Q_LEARNING            — enable/disable Q-learning agent router
ruflo_load_defaults() {
    local _repo_defaults=".shipwright/defaults.json"
    local _user_defaults="$HOME/.shipwright/defaults.json"
    local _defaults_file=""

    if [[ -f "$_repo_defaults" ]]; then
        _defaults_file="$_repo_defaults"
    elif [[ -f "$_user_defaults" ]]; then
        _defaults_file="$_user_defaults"
    fi

    [[ -n "$_defaults_file" ]] || return 0

    # Parse each key using select(. != null) rather than // empty because jq's
    # alternative operator treats boolean false as falsy and returns empty for
    # learning_bridge: false, which would leave the variable unset.
    # select(. != null) correctly passes false through while filtering null/missing.
    local _v
    # Validate integer fields: only export if value is a non-negative integer to
    # prevent a non-integer (string/float) from being passed to ruflo_with_timeout
    # or hive agent count, which would cause unexpected errors.
    _v=$(jq -r '.ruflo.max_agents | select(. != null)' "$_defaults_file" 2>/dev/null || true)
    if [[ -n "$_v" ]] && [[ "$_v" =~ ^[0-9]+$ ]]; then
        RUFLO_MAX_AGENTS="$_v"; export RUFLO_MAX_AGENTS
    fi

    _v=$(jq -r '.ruflo.cost_budget_multiplier | select(. != null)' "$_defaults_file" 2>/dev/null || true)
    [[ -n "$_v" ]] && { RUFLO_COST_BUDGET_MULTIPLIER="$_v"; export RUFLO_COST_BUDGET_MULTIPLIER; }

    _v=$(jq -r '.ruflo.circuit_breaker_timeout_s | select(. != null)' "$_defaults_file" 2>/dev/null || true)
    if [[ -n "$_v" ]] && [[ "$_v" =~ ^[0-9]+$ ]]; then
        RUFLO_CIRCUIT_BREAKER_TIMEOUT="$_v"; export RUFLO_CIRCUIT_BREAKER_TIMEOUT
    fi

    _v=$(jq -r '(.ruflo.learning_bridge | select(. != null)) | tostring' "$_defaults_file" 2>/dev/null || true)
    [[ -n "$_v" ]] && { RUFLO_LEARNING_BRIDGE="$_v"; export RUFLO_LEARNING_BRIDGE; }

    _v=$(jq -r '(.ruflo.q_learning_routing | select(. != null)) | tostring' "$_defaults_file" 2>/dev/null || true)
    [[ -n "$_v" ]] && { RUFLO_Q_LEARNING="$_v"; export RUFLO_Q_LEARNING; }

    emit_event "ruflo.defaults_loaded" \
        "file=$_defaults_file" \
        "max_agents=${RUFLO_MAX_AGENTS:-default}" || true
    return 0
}

# ─── _ruflo_run_timed — invoke ruflo binary with a timeout (no circuit-breaker)
# Unlike ruflo_with_timeout, this does NOT trip the circuit-breaker on failure.
# Used in ruflo_init where transient failures (e.g. init check on first run)
# are expected. Calls the ruflo binary directly so system timeout(1) can exec it.
# Usage: _ruflo_run_timed <seconds> <ruflo-args...>
# Returns the exit code of the underlying command (0=success, 124=timeout, etc).
_ruflo_run_timed() {
    local _t="${1:-30}"; shift
    if command -v timeout >/dev/null 2>&1; then
        if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
            timeout "$_t" npx -y ruflo@latest "$@"
        else
            timeout "$_t" ruflo "$@"
        fi
    else
        _ruflo_run "$@"
    fi
}

# ─── ruflo_init — initialize ruflo at pipeline start ─────────────────────────
# Detects ruflo, ensures the project is initialized, starts the orchestration
# daemon, and imports memory. No-op if ruflo is unavailable. Always returns 0.
#
# Uses `ruflo start --daemon` (NOT `ruflo mcp start`). The mcp subcommand is
# a stdio JSON-RPC server for Claude Code's MCP client — it exits immediately
# when stdin is /dev/null (EOF), so liveness probes always fail. In contrast,
# `ruflo start --daemon` is synchronous, performs internal health checks, and
# returns exit 0 only after the orchestration system is ready.
#
# All ruflo calls are wrapped in _ruflo_run_timed to prevent an unresponsive
# ruflo binary from stalling the entire pipeline indefinitely. The init-phase
# timeout defaults to 30s (override with RUFLO_INIT_TIMEOUT).
ruflo_init() {
    # Load project/user defaults before detection so env vars are set before
    # the daemon starts and before any hive function reads them.
    ruflo_load_defaults || true

    ruflo_detect || return 0

    info "Ruflo detected — starting orchestration daemon"
    emit_event "ruflo.init" "available=true"

    local _init_timeout="${RUFLO_INIT_TIMEOUT:-30}"

    # Ensure ruflo is initialized in this project directory.
    # `ruflo init check` exits 0 when .claude/settings.json exists, but
    # `ruflo start --daemon` also requires .claude-flow/config.yaml. Use the
    # check only as a fast path; a failed daemon start triggers a force-reinit.
    if ! _ruflo_run init check &>/dev/null; then
        if ! _ruflo_run init --minimal &>/dev/null; then
            warn "Ruflo project init failed — disabling ruflo for this run"
            RUFLO_AVAILABLE=false
            emit_event "ruflo.init_failed" "reason=project_init_failed"
            return 0
        fi
    fi

    # Start daemon synchronously — returns 0 only when ready, no sleep needed.
    # Treat already-running daemon as success via `ruflo status` fallback, but
    # only set RUFLO_DAEMON_STARTED when THIS run started it (not pre-existing).
    #
    # Recovery: if start fails (e.g. .claude-flow/ runtime missing despite
    # init check passing), attempt a force-reinit once before giving up.
    if _ruflo_run start --daemon &>/dev/null; then
        RUFLO_DAEMON_STARTED=true
        export RUFLO_DAEMON_STARTED
    elif ! _ruflo_run status &>/dev/null; then
        # Daemon not running — try force-reinit to repair missing runtime files
        if _ruflo_run init --force &>/dev/null && _ruflo_run start --daemon &>/dev/null; then
            RUFLO_DAEMON_STARTED=true
            export RUFLO_DAEMON_STARTED
            emit_event "ruflo.init_repaired" "reason=force_reinit"
        else
            warn "Ruflo daemon failed to start — disabling ruflo for this run"
            RUFLO_AVAILABLE=false
            emit_event "ruflo.init_failed" "reason=daemon_start_failed"
            return 0
        fi
    fi

    emit_event "ruflo.mcp_started" "mode=daemon"

    # Import memory from previous run (stub — implemented in Issue 2)
    ruflo_import_memory || true

    export RUFLO_AVAILABLE
    return 0
}

# ─── ruflo_cleanup — cleanup ruflo at pipeline end ───────────────────────────
# Exports memory, stops the orchestration daemon. No-op if this run did not
# start the daemon (circuit-breaker may have flipped RUFLO_AVAILABLE=false
# after startup — we still need to stop a daemon we started). Always returns 0.
ruflo_cleanup() {
    [[ "${RUFLO_DAEMON_STARTED:-false}" == "true" ]] || return 0

    # Export memory for next run (stub — implemented in Issue 2)
    ruflo_export_memory || true

    # Stop daemon with a short timeout. Call the binary directly (not the
    # _ruflo_run shell function) so system timeout(1) can exec it.
    if command -v timeout >/dev/null 2>&1; then
        if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
            timeout 10 npx -y ruflo@latest stop &>/dev/null || true
        else
            timeout 10 ruflo stop &>/dev/null || true
        fi
    else
        _ruflo_run stop &>/dev/null || true
    fi
    emit_event "ruflo.mcp_stopped" "mode=daemon"

    return 0
}

# ─── ruflo_health_check — check daemon liveness and attempt recovery ──────────
# Resets RUFLO_AVAILABLE=true and RUFLO_FAILURE_COUNT=0 if daemon responds.
# No-op if ruflo was never started by this run. Always returns 0 (fail-open).
ruflo_health_check() {
    # If currently healthy, nothing to do
    [[ "${RUFLO_AVAILABLE:-false}" == "true" ]] && return 0
    # Only attempt recovery if this run started the daemon
    [[ "${RUFLO_DAEMON_STARTED:-false}" == "true" ]] || return 0

    if _ruflo_run status &>/dev/null; then
        RUFLO_AVAILABLE=true
        RUFLO_FAILURE_COUNT=0
        export RUFLO_AVAILABLE
        emit_event "ruflo.health_recovered"
        return 0
    fi

    # Daemon dead — try one restart
    if _ruflo_run start --daemon &>/dev/null; then
        RUFLO_AVAILABLE=true
        RUFLO_FAILURE_COUNT=0
        export RUFLO_AVAILABLE
        emit_event "ruflo.health_restarted"
        return 0
    fi

    emit_event "ruflo.health_failed"
    return 0
}

# ─── ruflo_with_timeout — run a ruflo command with recoverable circuit-breaker ─
# Shell functions are run in a background subshell + poll so they get a real
# wall-clock bound (timeout(1) can only exec binaries, not functions).
# Failures increment RUFLO_FAILURE_COUNT; ruflo is only disabled after
# RUFLO_MAX_FAILURES (default 5) consecutive failures — transient errors recover.
# Usage: ruflo_with_timeout <seconds> <command...>
# Returns 0 on success, 1 on failure. Returns 1 immediately when ruflo is disabled.
ruflo_with_timeout() {
    local timeout_s="${1:-30}"
    shift

    if [[ $# -eq 0 ]]; then
        return 1
    fi

    local exit_code=0
    local cmd_type
    cmd_type=$(type -t "$1" 2>/dev/null || true)

    if [[ "$cmd_type" == "function" ]]; then
        # Shell functions can't be exec'd by timeout(1) — run in background
        # subshell and poll until done or wall-clock limit reached.
        ( "$@" ) &
        local bg_pid=$!
        local waited=0
        while kill -0 "$bg_pid" 2>/dev/null && [[ "$waited" -lt "$timeout_s" ]]; do
            sleep 1
            waited=$(( waited + 1 ))
        done
        if kill -0 "$bg_pid" 2>/dev/null; then
            # Kill child processes first (e.g. ruflo binary spawned by the function)
            # then the wrapper subshell. pkill -P kills by parent PID, which works
            # even without a dedicated process group (non-interactive shell, no set -m).
            if command -v pkill >/dev/null 2>&1; then
                pkill -TERM -P "$bg_pid" 2>/dev/null || true
            fi
            kill "$bg_pid" 2>/dev/null || true
            wait "$bg_pid" 2>/dev/null || true
            exit_code=124  # match timeout(1)'s exit code
        else
            wait "$bg_pid" 2>/dev/null || exit_code=$?
        fi
    elif type _timeout >/dev/null 2>&1; then
        _timeout "$timeout_s" "$@" || exit_code=$?
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" "$@" || exit_code=$?
    else
        # No timeout binary available — run directly (no wall-clock bound)
        "$@" || exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        RUFLO_FAILURE_COUNT=$(( RUFLO_FAILURE_COUNT + 1 ))
        export RUFLO_FAILURE_COUNT
        if [[ "$RUFLO_FAILURE_COUNT" -ge "${RUFLO_MAX_FAILURES:-5}" ]]; then
            warn "Ruflo command failed ${RUFLO_FAILURE_COUNT} times — disabling ruflo for this run"
            RUFLO_AVAILABLE=false
            export RUFLO_AVAILABLE
        else
            warn "Ruflo command failed (attempt ${RUFLO_FAILURE_COUNT}/${RUFLO_MAX_FAILURES:-5})"
        fi
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
    ruflo_with_timeout "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-10}" _ruflo_run_quiet memory store \
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
    ruflo_with_timeout "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-10}" _ruflo_run_quiet memory search \
        --query "$query" --namespace "$namespace" --limit 3 || echo ""
}

# ─── _ruflo_repo_hash_candidates — emit candidate hashes for memory dir lookup ─
# Tries the canonical Shipwright hash (shasum -a 256 of origin URL) first, then
# falls back to sha1/md5 variants for cross-platform compatibility.
# Outputs one hash per line. No-op if origin URL cannot be determined.
_ruflo_repo_hash_candidates() {
    local origin _h
    origin=$(git config --get remote.origin.url 2>/dev/null || true)
    [[ -n "$origin" ]] || return 0
    # Canonical: shasum -a 256 (matches sw-memory.sh repo_hash())
    if command -v shasum >/dev/null 2>&1; then
        _h=$(printf '%s' "$origin" | shasum -a 256 2>/dev/null) || true
        [[ -n "$_h" ]] && printf '%.12s\n' "$_h" && return 0
    fi
    # Fallbacks for non-macOS systems
    if command -v sha256sum >/dev/null 2>&1; then
        _h=$(printf '%s' "$origin" | sha256sum 2>/dev/null) || true
        [[ -n "$_h" ]] && printf '%.12s\n' "$_h" && return 0
    fi
    if command -v sha1sum >/dev/null 2>&1; then
        _h=$(printf '%s' "$origin" | sha1sum 2>/dev/null) || true
        [[ -n "$_h" ]] && printf '%.12s\n' "$_h" && return 0
    fi
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
        _hash=$(printf '%s' "$_origin" | shasum -a 256 2>/dev/null) || true
        _hash="${_hash:0:12}"
    elif command -v sha256sum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | sha256sum 2>/dev/null) || true
        _hash="${_hash:0:12}"
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

    # RUFLO_HIVE_MAX_AGENTS (function-level) overrides RUFLO_MAX_AGENTS (global default)
    local max_agents="${RUFLO_HIVE_MAX_AGENTS:-${RUFLO_MAX_AGENTS:-4}}"
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
    local _init_stderr_file
    _init_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ruflo-init-stderr.XXXXXX")
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _init_out=$(ruflo_with_timeout 30 npx -y ruflo@latest hive-mind init \
            --topology "$topology" \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    else
        _init_out=$(ruflo_with_timeout 30 ruflo hive-mind init \
            --topology "$topology" \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    fi
    [[ $_init_exit -eq 0 ]] && \
        hive_id=$(printf '%s' "$_init_out" | jq -r '.hive_id // empty' 2>/dev/null || true)

    if [[ $_init_exit -ne 0 || -z "$hive_id" ]]; then
        local _init_stderr=""
        [[ -f "$_init_stderr_file" ]] && _init_stderr=$(head -c 512 "$_init_stderr_file" 2>/dev/null || true)
        local _init_stdout_snip=""
        [[ -n "$_init_out" ]] && _init_stdout_snip=$(printf '%s' "$_init_out" | head -c 512 || true)
        # Strip control characters (including ANSI escapes, CR, NUL) so event fields
        # are safe for events.jsonl and SQL interpolation in db_add_event.
        _init_stderr=$(printf '%s' "$_init_stderr" | tr -d '\000-\037\177' || true)
        _init_stdout_snip=$(printf '%s' "$_init_stdout_snip" | tr -d '\000-\037\177' || true)
        rm -f "$_init_stderr_file"
        emit_event "ruflo.hive_init_failed" "topology=$topology" \
            "exit_code=$_init_exit" \
            "stderr=$_init_stderr" \
            "stdout=$_init_stdout_snip"
        return 1
    fi
    rm -f "$_init_stderr_file"

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

# ─── ruflo_execute_review — parallel review via ruflo hive-mind ──────────────
# Spawns specialist reviewer agents (security, code_quality, test_gap, architecture)
# in parallel using hive-mind. Findings are aggregated via union — NOT Byzantine
# consensus voting (which is for conflicting outputs; review findings are additive).
# The architecture reviewer receives ADR context from ruflo memory for compliance.
#
# Usage: ruflo_execute_review <diff_content> <artifact_file>
# Returns 0 on success (artifact_file written with union of findings),
#         1 on any hive failure (caller falls back to native review).
# Always fail-open — never blocks the pipeline.
#
# Environment knobs:
#   RUFLO_REVIEW_MAX_AGENTS  — max parallel reviewers (default 4)
ruflo_execute_review() {
    ruflo_available || return 1
    local diff_content="$1"
    local artifact_file="$2"
    [[ -n "$diff_content" && -n "$artifact_file" ]] || return 1

    # RUFLO_REVIEW_MAX_AGENTS (function-level) overrides RUFLO_MAX_AGENTS (global default)
    local max_agents="${RUFLO_REVIEW_MAX_AGENTS:-${RUFLO_MAX_AGENTS:-4}}"
    # Use pipeline_id when available; fall back to epoch+PID to ensure namespace
    # uniqueness across concurrent runs when SHIPWRIGHT_PIPELINE_ID is unset.
    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-$(date +%s)-$$}"
    local review_ns="hive-review-${pipeline_id}"

    emit_event "ruflo.review_start" "max_agents=$max_agents"

    # Q-learning agent selection via hooks_route — select reviewer subset based on
    # issue context (e.g. security-heavy issues get more security reviewers).
    # JSON is built with jq --arg to safely handle quotes/newlines in goal.
    local _route_context
    _route_context=$(jq -n \
        --arg goal "${GOAL:-review}" \
        --argjson max_agents "$max_agents" \
        '{goal:$goal,max_agents:$max_agents,stage:"review"}' 2>/dev/null || true)
    if [[ -n "$_route_context" ]]; then
        local _route_json=""
        if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
            _route_json=$(npx -y ruflo@latest hooks route \
                --event "review.start" \
                --context "$_route_context" 2>/dev/null || true)
        else
            _route_json=$(ruflo hooks route \
                --event "review.start" \
                --context "$_route_context" 2>/dev/null || true)
        fi
        if [[ -n "$_route_json" ]]; then
            local _recommended
            _recommended=$(printf '%s' "$_route_json" | \
                jq -r '.agent_count // empty' 2>/dev/null || true)
            # Validate _recommended is a non-negative integer before numeric compare
            if [[ "$_recommended" =~ ^[0-9]+$ && "$_recommended" -le "$max_agents" ]]; then
                max_agents="$_recommended"
            fi
        fi
    fi

    # Initialize review hive — wrapped in ruflo_with_timeout to prevent hangs
    local hive_id=""
    local _init_exit=0
    local _init_out=""
    local _init_stderr_file
    _init_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ruflo-init-stderr.XXXXXX")
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _init_out=$(ruflo_with_timeout 30 npx -y ruflo@latest hive-mind init \
            --topology hierarchical \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    else
        _init_out=$(ruflo_with_timeout 30 ruflo hive-mind init \
            --topology hierarchical \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    fi
    [[ $_init_exit -eq 0 ]] && \
        hive_id=$(printf '%s' "$_init_out" | jq -r '.hive_id // empty' 2>/dev/null || true)
    if [[ $_init_exit -ne 0 || -z "$hive_id" ]]; then
        local _init_stderr=""
        [[ -f "$_init_stderr_file" ]] && _init_stderr=$(head -c 512 "$_init_stderr_file" 2>/dev/null || true)
        local _init_stdout_snip=""
        [[ -n "$_init_out" ]] && _init_stdout_snip=$(printf '%s' "$_init_out" | head -c 512 || true)
        # Strip control characters (including ANSI escapes, CR, NUL) so event fields
        # are safe for events.jsonl and SQL interpolation in db_add_event.
        _init_stderr=$(printf '%s' "$_init_stderr" | tr -d '\000-\037\177' || true)
        _init_stdout_snip=$(printf '%s' "$_init_stdout_snip" | tr -d '\000-\037\177' || true)
        rm -f "$_init_stderr_file"
        emit_event "ruflo.review_failed" "reason=hive_init_failed" \
            "exit_code=$_init_exit" \
            "stderr=$_init_stderr" \
            "stdout=$_init_stdout_snip"
        return 1
    fi
    rm -f "$_init_stderr_file"

    # Spawn specialist reviewers — spawn failures are non-fatal (proceed with fewer agents)
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 60 npx -y ruflo@latest hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role specialist \
            --prefix "review-${pipeline_id}" 2>/dev/null || true
    else
        ruflo_with_timeout 60 ruflo hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role specialist \
            --prefix "review-${pipeline_id}" 2>/dev/null || true
    fi

    # Store diff in shared hive memory for reviewers to consume.
    # Bounded to 8000 bytes to avoid exceeding argv limits.
    local _bounded_diff
    _bounded_diff=$(printf '%s' "$diff_content" | head -c 8000 2>/dev/null || true)
    ruflo_store "review-diff" "$_bounded_diff" "$review_ns" "review,diff" || true

    # Inject ADR context for architecture reviewer — enables compliance checking.
    # Only runs when repo hash is determinable (to prevent cross-repo namespace leaks).
    local _ns_hash
    if _ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null); then
        local _adrs
        _adrs=$(ruflo_recall "architecture decisions" "adrs-${_ns_hash}" 2>/dev/null || true)
        if [[ -n "$_adrs" ]]; then
            ruflo_store "review-adrs" "$_adrs" "$review_ns" "adr,context" || true
        fi
    fi

    # Orchestrate parallel review across the hive — each specialist agent analyses
    # the diff from their domain perspective (security, code_quality, test_gap,
    # architecture). Results are written to the shared hive memory namespace.
    local _orch_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 300 npx -y ruflo@latest coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "parallel code review: analyse diff in namespace ${review_ns}" \
            --max-turns 20 \
            --mode "review" 2>/dev/null || _orch_exit=$?
    else
        ruflo_with_timeout 300 ruflo coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "parallel code review: analyse diff in namespace ${review_ns}" \
            --max-turns 20 \
            --mode "review" 2>/dev/null || _orch_exit=$?
    fi

    # Aggregate findings via union — list all entries from the hive shared memory.
    # Union (not Byzantine consensus): all reviewer findings are included regardless
    # of whether they overlap. Duplicate deduplication is handled downstream.
    local _findings=""
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _findings=$(ruflo_with_timeout 10 npx -y ruflo@latest hive-mind memory \
            --action list \
            --namespace "$review_ns" 2>/dev/null) || true
    else
        _findings=$(ruflo_with_timeout 10 ruflo hive-mind memory \
            --action list \
            --namespace "$review_ns" 2>/dev/null) || true
    fi

    # Always shut down the hive regardless of outcome
    _ruflo_hive_shutdown "$hive_id"

    # Write findings to artifact file — ensure parent directory exists
    mkdir -p "$(dirname "$artifact_file")" 2>/dev/null || true
    if ! printf '%s\n' "${_findings:-}" > "$artifact_file" 2>/dev/null; then
        warn "ruflo: failed to write review artifact: $artifact_file"
        # Fail-open: caller checks -s before injecting context, so empty = no-op
    fi

    # Persist review result for downstream stage context (PR, audit stages)
    ruflo_store "stage-review-result" \
        "$(head -c 2000 "$artifact_file" 2>/dev/null || true)" \
        "pipeline-${pipeline_id}" \
        "review,outcome" || true

    emit_event "ruflo.review_complete" "hive_id=$hive_id"
    return 0
}

# ─── ruflo_execute_compound_quality — adversarial quality hive ───────────────
# Spawns adversarial specialist agents for compound quality checks:
#   - negative_tester: writes failing tests for uncovered edge cases
#   - dod_auditor: checks Definition of Done criteria
#   - e2e_validator: end-to-end scenario coverage
# Findings aggregated via union (same principle as ruflo_execute_review).
#
# Usage: ruflo_execute_compound_quality <diff_content> <artifact_file>
# Returns 0 on success, 1 on any hive failure (caller falls back to native checks).
# Always fail-open — never blocks the pipeline.
ruflo_execute_compound_quality() {
    ruflo_available || return 1
    local diff_content="$1"
    local artifact_file="$2"
    [[ -n "$diff_content" && -n "$artifact_file" ]] || return 1

    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-$(date +%s)-$$}"
    local cq_ns="hive-cq-${pipeline_id}"
    # Adversarial quality agents: RUFLO_CQ_MAX_AGENTS > RUFLO_MAX_AGENTS > default(3)
    local cq_agents="${RUFLO_CQ_MAX_AGENTS:-${RUFLO_MAX_AGENTS:-3}}"

    emit_event "ruflo.cq_start"

    # Initialize adversarial quality hive
    local hive_id=""
    local _init_exit=0
    local _init_out=""
    local _init_stderr_file
    _init_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ruflo-init-stderr.XXXXXX")
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _init_out=$(ruflo_with_timeout 30 npx -y ruflo@latest hive-mind init \
            --topology hierarchical \
            --max-agents "$cq_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    else
        _init_out=$(ruflo_with_timeout 30 ruflo hive-mind init \
            --topology hierarchical \
            --max-agents "$cq_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    fi
    [[ $_init_exit -eq 0 ]] && \
        hive_id=$(printf '%s' "$_init_out" | jq -r '.hive_id // empty' 2>/dev/null || true)
    if [[ $_init_exit -ne 0 || -z "$hive_id" ]]; then
        local _init_stderr=""
        [[ -f "$_init_stderr_file" ]] && _init_stderr=$(head -c 512 "$_init_stderr_file" 2>/dev/null || true)
        local _init_stdout_snip=""
        [[ -n "$_init_out" ]] && _init_stdout_snip=$(printf '%s' "$_init_out" | head -c 512 || true)
        # Strip control characters (including ANSI escapes, CR, NUL) so event fields
        # are safe for events.jsonl and SQL interpolation in db_add_event.
        _init_stderr=$(printf '%s' "$_init_stderr" | tr -d '\000-\037\177' || true)
        _init_stdout_snip=$(printf '%s' "$_init_stdout_snip" | tr -d '\000-\037\177' || true)
        rm -f "$_init_stderr_file"
        emit_event "ruflo.cq_failed" "reason=hive_init_failed" \
            "exit_code=$_init_exit" \
            "stderr=$_init_stderr" \
            "stdout=$_init_stdout_snip"
        return 1
    fi
    rm -f "$_init_stderr_file"

    # Spawn adversarial agents — non-fatal spawn failure
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 60 npx -y ruflo@latest hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$cq_agents" \
            --role specialist \
            --prefix "quality-${pipeline_id}" 2>/dev/null || true
    else
        ruflo_with_timeout 60 ruflo hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$cq_agents" \
            --role specialist \
            --prefix "quality-${pipeline_id}" 2>/dev/null || true
    fi

    # Store diff and prior review findings for adversarial agents to consume
    local _bounded_diff
    _bounded_diff=$(printf '%s' "$diff_content" | head -c 8000 2>/dev/null || true)
    ruflo_store "cq-diff" "$_bounded_diff" "$cq_ns" "quality,diff" || true

    # Inject prior review results so adversarial agents can target gaps
    local _prior_review
    _prior_review=$(ruflo_recall "stage-review-result" \
        "pipeline-${pipeline_id}" 2>/dev/null || true)
    if [[ -n "$_prior_review" ]]; then
        ruflo_store "cq-review-context" "$_prior_review" "$cq_ns" "quality,context" || true
    fi

    # Orchestrate adversarial quality checks — agents run negative testing,
    # DoD auditing, and E2E scenario validation in parallel.
    local _orch_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 300 npx -y ruflo@latest coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "adversarial quality: negative tests, DoD audit, E2E validation for namespace ${cq_ns}" \
            --max-turns 15 \
            --mode "quality" 2>/dev/null || _orch_exit=$?
    else
        ruflo_with_timeout 300 ruflo coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "adversarial quality: negative tests, DoD audit, E2E validation for namespace ${cq_ns}" \
            --max-turns 15 \
            --mode "quality" 2>/dev/null || _orch_exit=$?
    fi

    # Aggregate via union — all adversarial findings included
    local _findings=""
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _findings=$(ruflo_with_timeout 10 npx -y ruflo@latest hive-mind memory \
            --action list \
            --namespace "$cq_ns" 2>/dev/null) || true
    else
        _findings=$(ruflo_with_timeout 10 ruflo hive-mind memory \
            --action list \
            --namespace "$cq_ns" 2>/dev/null) || true
    fi

    # Always shut down the hive regardless of outcome
    _ruflo_hive_shutdown "$hive_id"

    # Write findings to artifact file — ensure parent directory exists
    mkdir -p "$(dirname "$artifact_file")" 2>/dev/null || true
    if ! printf '%s\n' "${_findings:-}" > "$artifact_file" 2>/dev/null; then
        warn "ruflo: failed to write compound quality artifact: $artifact_file"
    fi

    # Persist compound quality result for downstream stages
    ruflo_store "stage-cq-result" \
        "$(head -c 2000 "$artifact_file" 2>/dev/null || true)" \
        "pipeline-${pipeline_id}" \
        "quality,outcome" || true

    emit_event "ruflo.cq_complete" "hive_id=$hive_id"
    return 0
}

# ─── ruflo_execute_audit — parallel security audit via ruflo hive-mind ───────
# Spawns specialist security audit agents in parallel:
#   - cve_scanner: scans dependencies and code for known CVEs
#   - secrets_detector: deep secrets and credential leak analysis
#   - owasp_auditor: OWASP Top-10 vulnerability assessment
#   - compliance_checker: policy and compliance constraint checking
# Findings aggregated via union — all specialist findings are additive.
# Prior review results are injected for cross-stage context.
#
# Usage: ruflo_execute_audit <diff_content> <artifact_file>
# Returns 0 on success (artifact_file written with union of findings),
#         1 on any hive failure (caller falls back to native audit checks).
# Always fail-open — never blocks the pipeline.
#
# Environment knobs:
#   RUFLO_AUDIT_MAX_AGENTS  — max parallel audit specialists (default 4)
ruflo_execute_audit() {
    ruflo_available || return 1
    local diff_content="$1"
    local artifact_file="$2"
    [[ -n "$diff_content" && -n "$artifact_file" ]] || return 1

    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-$(date +%s)-$$}"
    local audit_ns="hive-audit-${pipeline_id}"
    local max_agents="${RUFLO_AUDIT_MAX_AGENTS:-${RUFLO_MAX_AGENTS:-4}}"

    emit_event "ruflo.audit_start" "max_agents=$max_agents"

    # Initialize audit hive
    local hive_id=""
    # Save caller's EXIT trap so we can restore it and chain it on unexpected exits.
    # Using local variables avoids leaking state across calls.
    # _prev_exit_raw: full "trap -- '...' EXIT" string, used to restore on explicit returns.
    # _prev_exit_body: just the handler body, embedded inline in our chained trap so that
    # both hive cleanup AND caller teardown (lock release, stash restore, etc.) run if the
    # process exits unexpectedly (SIGTERM, set -e, etc.) while our trap is installed.
    local _prev_exit_raw
    local _prev_exit_body=""
    _prev_exit_raw=$(trap -p EXIT 2>/dev/null || true)
    if [[ -n "$_prev_exit_raw" ]]; then
        # Extract handler body from: trap -- 'body' EXIT
        _prev_exit_body=$(printf '%s\n' "$_prev_exit_raw" | sed "s/^trap -- '//; s/' EXIT\$//")
    fi
    # Declare _init_stderr_file before trap so cleanup can reference it even on
    # abnormal exits (SIGTERM, set -e) — the trap body uses ${_init_stderr_file:-}.
    local _init_stderr_file
    _init_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ruflo-init-stderr.XXXXXX")
    local _chained_trap='[[ -n "${hive_id:-}" ]] && _ruflo_hive_shutdown "${hive_id}" 2>/dev/null || true; rm -f "${_init_stderr_file:-}" 2>/dev/null || true'
    [[ -n "$_prev_exit_body" ]] && _chained_trap="${_chained_trap}; ${_prev_exit_body}"
    trap "$_chained_trap" EXIT
    local _init_exit=0
    local _init_out=""
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _init_out=$(ruflo_with_timeout 30 npx -y ruflo@latest hive-mind init \
            --topology hierarchical \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    else
        _init_out=$(ruflo_with_timeout 30 ruflo hive-mind init \
            --topology hierarchical \
            --max-agents "$max_agents" \
            --output-format json 2>"$_init_stderr_file") || _init_exit=$?
    fi
    [[ $_init_exit -eq 0 ]] && \
        hive_id=$(printf '%s' "$_init_out" | jq -r '.hive_id // empty' 2>/dev/null || true)
    if [[ $_init_exit -ne 0 || -z "$hive_id" ]]; then
        local _init_stderr=""
        [[ -f "$_init_stderr_file" ]] && _init_stderr=$(head -c 512 "$_init_stderr_file" 2>/dev/null || true)
        local _init_stdout_snip=""
        [[ -n "$_init_out" ]] && _init_stdout_snip=$(printf '%s' "$_init_out" | head -c 512 || true)
        # Strip control characters (including ANSI escapes, CR, NUL) so event fields
        # are safe for events.jsonl and SQL interpolation in db_add_event.
        _init_stderr=$(printf '%s' "$_init_stderr" | tr -d '\000-\037\177' || true)
        _init_stdout_snip=$(printf '%s' "$_init_stdout_snip" | tr -d '\000-\037\177' || true)
        rm -f "$_init_stderr_file"
        emit_event "ruflo.audit_failed" "reason=hive_init_failed" \
            "exit_code=$_init_exit" \
            "stderr=$_init_stderr" \
            "stdout=$_init_stdout_snip"
        if [[ -n "${_prev_exit_raw:-}" ]]; then eval "${_prev_exit_raw}"; else trap - EXIT; fi
        return 1
    fi
    rm -f "$_init_stderr_file"

    # Spawn specialist security audit agents — non-fatal spawn failure
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 60 npx -y ruflo@latest hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role specialist \
            --prefix "audit-${pipeline_id}" 2>/dev/null || true
    else
        ruflo_with_timeout 60 ruflo hive-mind spawn \
            --hive-id "$hive_id" \
            --count "$max_agents" \
            --role specialist \
            --prefix "audit-${pipeline_id}" 2>/dev/null || true
    fi

    # Store diff in shared hive memory for audit agents to consume.
    # Bounded to 8000 bytes to avoid exceeding argv limits.
    local _bounded_diff
    local _diff_bytes
    _diff_bytes=$(printf '%s' "$diff_content" | wc -c 2>/dev/null || echo 0)
    if (( _diff_bytes > 8000 )); then
        warn "ruflo: audit diff exceeds 8KB (${_diff_bytes} bytes) — truncated to first 8000 bytes (may miss issues in larger diffs)"
    fi
    _bounded_diff=$(printf '%s' "$diff_content" | head -c 8000 2>/dev/null || true)
    ruflo_store "audit-diff" "$_bounded_diff" "$audit_ns" "audit,diff" || true

    # Inject prior review findings so audit agents can target flagged areas.
    local _prior_review
    _prior_review=$(ruflo_recall "stage-review-result" \
        "pipeline-${pipeline_id}" 2>/dev/null || true)
    if [[ -n "$_prior_review" ]]; then
        ruflo_store "audit-review-context" "$_prior_review" "$audit_ns" "audit,context" || true
    fi

    # Inject ADR context for compliance checking — enables audit agents to verify
    # that changes comply with documented architecture decisions.
    local _ns_hash
    if _ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null); then
        local _adrs
        _adrs=$(ruflo_recall "architecture decisions" "adrs-${_ns_hash}" 2>/dev/null || true)
        if [[ -n "$_adrs" ]]; then
            ruflo_store "audit-adrs" "$_adrs" "$audit_ns" "adr,context" || true
        fi
    fi

    # Orchestrate parallel security audit — CVE scanning, secrets detection,
    # OWASP assessment, and compliance checking run in parallel across the hive.
    local _orch_exit=0
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        ruflo_with_timeout 300 npx -y ruflo@latest coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "parallel security audit: CVE scan, secrets detection, OWASP assessment, compliance check for namespace ${audit_ns}" \
            --max-turns 15 \
            --mode "audit" 2>/dev/null || _orch_exit=$?
    else
        ruflo_with_timeout 300 ruflo coordination orchestrate \
            --hive-id "$hive_id" \
            --goal "parallel security audit: CVE scan, secrets detection, OWASP assessment, compliance check for namespace ${audit_ns}" \
            --max-turns 15 \
            --mode "audit" 2>/dev/null || _orch_exit=$?
    fi

    # Fail fast if orchestration failed — no findings to aggregate
    if [[ $_orch_exit -ne 0 ]]; then
        warn "ruflo: orchestration failed with exit $_orch_exit"
        _ruflo_hive_shutdown "$hive_id"
        emit_event "ruflo.audit_failed" "reason=orchestration_failed"
        if [[ -n "${_prev_exit_raw:-}" ]]; then eval "${_prev_exit_raw}"; else trap - EXIT; fi
        return 1
    fi

    # Aggregate via union — all specialist findings included
    local _findings=""
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        _findings=$(ruflo_with_timeout 10 npx -y ruflo@latest hive-mind memory \
            --action list \
            --namespace "$audit_ns" 2>/dev/null) || true
    else
        _findings=$(ruflo_with_timeout 10 ruflo hive-mind memory \
            --action list \
            --namespace "$audit_ns" 2>/dev/null) || true
    fi

    # Always shut down the hive regardless of outcome
    _ruflo_hive_shutdown "$hive_id"

    # Write findings to artifact file — ensure parent directory exists
    mkdir -p "$(dirname "$artifact_file")" 2>/dev/null || true
    if ! printf '%s\n' "${_findings:-}" > "$artifact_file"; then
        warn "ruflo: failed to write audit artifact: $artifact_file"
        if [[ -n "${_prev_exit_raw:-}" ]]; then eval "${_prev_exit_raw}"; else trap - EXIT; fi
        return 1
    fi

    # Persist audit result for downstream stages
    ruflo_store "stage-audit-result" \
        "$(head -c 2000 "$artifact_file" 2>/dev/null || true)" \
        "pipeline-${pipeline_id}" \
        "audit,outcome" || true

    emit_event "ruflo.audit_complete" "hive_id=$hive_id" "stage=audit"
    if [[ -n "${_prev_exit_raw:-}" ]]; then eval "${_prev_exit_raw}"; else trap - EXIT; fi
    return 0
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
