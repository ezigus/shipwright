#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright sensitive-data-filter — Redact secrets from pattern content  ║
# ║  Source this library; do not execute directly                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_SENSITIVE_DATA_FILTER_LOADED:-}" ]] && return 0
_SENSITIVE_DATA_FILTER_LOADED=1

# Patterns that indicate sensitive data (case-insensitive grep -iE)
_SENSITIVE_PATTERNS='(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|bearer|password|passwd|secret[_-]?key|private[_-]?key|ssh-rsa|AWS_SECRET|AWS_ACCESS_KEY|GITHUB_TOKEN|GITHUB_PAT|npm_token|DATABASE_URL|REDIS_URL|x-api-key|authorization:\s*(Bearer|Basic)|credential)'

# Patterns that look like actual secret values (hex strings, base64 tokens, etc.)
_SECRET_VALUE_PATTERNS='([A-Za-z0-9+/]{40,}={0,2}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{32,}|AKIA[A-Z0-9]{16}|xox[bpras]-[A-Za-z0-9-]{10,})'

# Filter sensitive data from a string
# Usage: _filter_sensitive_data "input string"
# Returns: redacted string on stdout
# Exit: 0 always (never fails pipeline)
_filter_sensitive_data() {
    local input="${1:-}"
    [[ -z "$input" ]] && return 0

    local output="$input"

    # Redact known secret key names and their values (key=value, key: value patterns)
    output=$(echo "$output" | sed -E \
        -e 's/(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|password|passwd|secret[_-]?key|private[_-]?key|npm_token|GITHUB_TOKEN|GITHUB_PAT|AWS_SECRET[_A-Z]*|AWS_ACCESS_KEY[_A-Z]*|DATABASE_URL|REDIS_URL)[[:space:]]*[=:][[:space:]]*[^[:space:]"'\'']+/\1=<REDACTED>/gi' \
        2>/dev/null || echo "$output")

    # Redact bearer/basic auth headers
    output=$(echo "$output" | sed -E \
        -e 's/(Bearer|Basic)[[:space:]]+[A-Za-z0-9+/=._-]{8,}/<AUTH_REDACTED>/gi' \
        2>/dev/null || echo "$output")

    # Redact GitHub PATs, AWS keys, Slack tokens, OpenAI keys
    output=$(echo "$output" | sed -E \
        -e 's/ghp_[A-Za-z0-9]{36}/<GITHUB_TOKEN_REDACTED>/g' \
        -e 's/gho_[A-Za-z0-9]{36}/<GITHUB_TOKEN_REDACTED>/g' \
        -e 's/sk-[A-Za-z0-9]{32,}/<API_KEY_REDACTED>/g' \
        -e 's/AKIA[A-Z0-9]{16}/<AWS_KEY_REDACTED>/g' \
        -e 's/xox[bpras]-[A-Za-z0-9-]{10,}/<SLACK_TOKEN_REDACTED>/g' \
        2>/dev/null || echo "$output")

    # Redact ssh private keys
    output=$(echo "$output" | sed -E \
        -e 's/ssh-rsa [A-Za-z0-9+/=]{20,}/<SSH_KEY_REDACTED>/g' \
        2>/dev/null || echo "$output")

    echo "$output"
}

# Check if text contains sensitive data that could not be fully redacted
# Returns: 0 if clean, 1 if sensitive data detected
_has_sensitive_data() {
    local input="${1:-}"
    [[ -z "$input" ]] && return 0

    if echo "$input" | grep -qiE "$_SECRET_VALUE_PATTERNS" 2>/dev/null; then
        return 1
    fi
    return 0
}
