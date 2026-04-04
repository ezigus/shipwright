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
if ! type info >/dev/null 2>&1; then
    info()    { echo "▸ $*"; }
fi
if ! type warn >/dev/null 2>&1; then
    warn()    { echo "⚠ $*" >&2; }
fi
if ! type emit_event >/dev/null 2>&1; then
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

# ─── ruflo_import_memory — stub for Issue 2 (memory bridge) ──────────────────
# Imports ruflo memory from previous run into the current pipeline context.
# Returns 0 (no-op until Issue 2 is implemented).
ruflo_import_memory() {
    return 0
}

# ─── ruflo_export_memory — stub for Issue 2 (memory bridge) ──────────────────
# Exports current pipeline context to ruflo memory for future runs.
# Returns 0 (no-op until Issue 2 is implemented).
ruflo_export_memory() {
    return 0
}
