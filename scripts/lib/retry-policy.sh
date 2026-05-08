#!/usr/bin/env bash
# retry-policy.sh — Single source of truth for all retry caps.
# Source this file to get RETRY_MAX_PIPELINE_STARTS, RETRY_MAX_AUTO_RETRIES,
# RETRY_ABANDON_AFTER_MINUTES read from config/policy.json.
# Usage: source "$SCRIPT_DIR/lib/retry-policy.sh"
[[ -n "${_RETRY_POLICY_LOADED:-}" ]] && return 0
_RETRY_POLICY_LOADED=1

_RETRY_POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RETRY_POLICY_FILE="${_RETRY_POLICY_DIR}/../../config/policy.json"

RETRY_MAX_PIPELINE_STARTS=$(jq -r '.retry.max_pipeline_starts // 6' "$_RETRY_POLICY_FILE" 2>/dev/null || echo "6")
RETRY_MAX_AUTO_RETRIES=$(jq -r '.retry.max_auto_retries // 3' "$_RETRY_POLICY_FILE" 2>/dev/null || echo "3")
RETRY_ABANDON_AFTER_MINUTES=$(jq -r '.retry.abandon_after_minutes // 120' "$_RETRY_POLICY_FILE" 2>/dev/null || echo "120")

export RETRY_MAX_PIPELINE_STARTS RETRY_MAX_AUTO_RETRIES RETRY_ABANDON_AFTER_MINUTES
