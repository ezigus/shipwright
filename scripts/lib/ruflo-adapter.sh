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
# CI=true prevents ruflo from entering TTY branding mode, which forks subshells
# using cut in pipelines and writes "cut: stdout: Broken pipe" directly to
# /dev/tty — bypassing all stdout/stderr redirections from the caller.
_ruflo_run() {
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        CI=true npx -y ruflo@latest "$@"
    else
        CI=true ruflo "$@"
    fi
}

# ─── _ruflo_run_quiet — invoke ruflo, suppressing only the binary's stderr ────
# Unlike adding 2>/dev/null to ruflo_with_timeout, this preserves the
# circuit-breaker's own warn() output for observability.
_ruflo_run_quiet() {
    if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
        CI=true npx -y ruflo@latest "$@" 2>/dev/null
    else
        CI=true ruflo "$@" 2>/dev/null
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
# Detects ruflo, ensures project is initialized, starts orchestration daemon,
# and imports memory. No-op if ruflo is unavailable. Always returns 0.
#
# Uses `ruflo start --daemon` (not `ruflo mcp start`). The mcp subcommand
# launches a stdio JSON-RPC server intended for Claude Code's MCP integration —
# it reads from stdin and immediately exits when stdin is /dev/null, so it can
# never pass a liveness check. `ruflo start --daemon` is the correct command:
# it runs synchronously, performs internal health checks, and returns 0 only
# after the orchestration system is ready. No sleep or PID probe needed.
ruflo_init() {
    ruflo_detect || return 0

    info "Ruflo detected — starting orchestration daemon"
    emit_event "ruflo.init" "available=true"

    # Ensure ruflo is initialized in this project directory.
    # `ruflo init check` exits 0 when .claude-flow/config.yaml exists.
    # `ruflo init --minimal` is safe to run on already-initialized projects.
    if ! _ruflo_run init check &>/dev/null; then
        if ! _ruflo_run init --minimal &>/dev/null; then
            warn "Ruflo project init failed — disabling ruflo for this run"
            RUFLO_AVAILABLE=false
            emit_event "ruflo.init_failed" "reason=project_init_failed"
            return 0
        fi
    fi

    # Start orchestration daemon. Synchronous: returns 0 only after health
    # checks pass. Non-zero means startup failed OR a daemon is already running
    # (idempotent re-start is not an error — check status to distinguish).
    if ! _ruflo_run start --daemon &>/dev/null; then
        if ! _ruflo_run status &>/dev/null; then
            warn "Ruflo daemon failed to start — disabling ruflo for this run"
            RUFLO_AVAILABLE=false
            emit_event "ruflo.init_failed" "reason=daemon_start_failed"
            return 0
        fi
        # Daemon was already running — that's fine, continue
    fi

    emit_event "ruflo.mcp_started" "mode=daemon"

    ruflo_import_memory || true
    export RUFLO_AVAILABLE
    return 0
}

# ─── ruflo_cleanup — cleanup ruflo at pipeline end ───────────────────────────
# Exports memory, stops orchestration daemon. No-op if ruflo was not active.
# Always returns 0.
ruflo_cleanup() {
    ruflo_available || return 0

    # Export memory for next run (stub — implemented in Issue 2)
    ruflo_export_memory || true

    # Stop daemon — best-effort, never blocks pipeline exit
    _ruflo_run stop &>/dev/null || true
    emit_event "ruflo.mcp_stopped" "mode=daemon"

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

# ─── ruflo_learn_from_shipwright — bridge Shipwright outcomes to ruflo ───────
# Called after pipeline completion. Accepts either a path to an outcome JSON
# file or a raw JSON string, then indexes the outcome into ruflo HNSW under a
# repo-specific namespace for vector-similarity search.
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
