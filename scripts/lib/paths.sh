#!/usr/bin/env bash
# Centralized path defaults for Shipwright.
# Do NOT add set -euo pipefail here — this file is sourced as a library and must not
# alter the caller's shell options.
# SW_PIPELINE_ARTIFACTS is derived from this script's location (scripts/lib/paths.sh →
# scripts/lib/ → scripts/ → repo root) so it is correct regardless of $PWD.
_SW_PATHS_SCRIPT="${BASH_SOURCE[0]:-}"
if [[ -n "$_SW_PATHS_SCRIPT" ]]; then
    _SW_REPO_DIR="$(cd "$(dirname "$_SW_PATHS_SCRIPT")/../.." 2>/dev/null && pwd)" || _SW_REPO_DIR=""
else
    _SW_REPO_DIR=""
fi
SW_HOME="${HOME}/.shipwright"
SW_EVENTS="${SW_HOME}/events.jsonl"
SW_COSTS="${SW_HOME}/costs.json"
SW_HEARTBEATS="${SW_HOME}/heartbeats"
SW_ARTIFACTS="${SW_HOME}/artifacts"
# Prefer an explicitly set value, then derive from repo root, then fall back to $PWD.
SW_PIPELINE_ARTIFACTS="${SW_PIPELINE_ARTIFACTS:-${_SW_REPO_DIR:+${_SW_REPO_DIR}/.claude/pipeline-artifacts}}"
SW_PIPELINE_ARTIFACTS="${SW_PIPELINE_ARTIFACTS:-${PWD}/.claude/pipeline-artifacts}"
export SW_HOME SW_EVENTS SW_COSTS SW_HEARTBEATS SW_ARTIFACTS SW_PIPELINE_ARTIFACTS
unset _SW_PATHS_SCRIPT _SW_REPO_DIR
