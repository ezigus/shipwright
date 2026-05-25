#!/usr/bin/env bash
# Single source of truth for SW_VERSION. Sourced by all scripts; never hardcode version strings.
# Do NOT add set -euo pipefail here — this file is sourced as a library and must not alter
# the caller's shell options or hard-fail in environments without jq or package.json.
# Already set (e.g. by a parent script or test harness) — use existing value.
if [[ -n "${SW_VERSION:-}" ]]; then
    export SW_VERSION
    return 0 2>/dev/null || true
fi
# Locate package.json relative to this script (scripts/lib/version.sh → repo root)
_SW_SCRIPT="${BASH_SOURCE[0]:-}"
if [[ -n "$_SW_SCRIPT" ]]; then
    _SW_PACKAGE_JSON="$(cd "$(dirname "$_SW_SCRIPT")/../../" && pwd)/package.json"
else
    _SW_PACKAGE_JSON=""
fi
if [[ -f "${_SW_PACKAGE_JSON:-}" ]] && command -v jq >/dev/null 2>&1; then
    SW_VERSION="$(jq -r .version "$_SW_PACKAGE_JSON")"
elif [[ -f "${_SW_PACKAGE_JSON:-}" ]]; then
    # Fallback: parse package.json with grep/sed (no jq)
    SW_VERSION="$(grep '"version"' "$_SW_PACKAGE_JSON" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/".*//')"
else
    # package.json not found (e.g. test temp dir) — use safe placeholder
    SW_VERSION="0.0.0-unknown"
fi
export SW_VERSION
