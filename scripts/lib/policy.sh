# policy.sh — Load central policy from config/policy.json or ~/.shipwright/policy.json
# Source this to get POLICY_* vars (optional). Scripts can also jq config/policy.json directly.
# Usage: source "$SCRIPT_DIR/lib/policy.sh"   (after SCRIPT_DIR is set)
[[ -n "${POLICY_LOADED:-}" ]] && return 0
POLICY_LOADED=1

# Resolve repo root (caller may set REPO_DIR)
_REPO_DIR="${REPO_DIR:-}"
[[ -z "$_REPO_DIR" && -n "${SCRIPT_DIR:-}" ]] && _REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -z "$_REPO_DIR" ]] && _REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"

_POLICY_FILE=""
[[ -n "$_REPO_DIR" && -f "$_REPO_DIR/config/policy.json" ]] && _POLICY_FILE="$_REPO_DIR/config/policy.json"
[[ -f "${HOME}/.shipwright/policy.json" ]] && _POLICY_FILE="${HOME}/.shipwright/policy.json"

# Export a single helper: policy_get <json_path> [default]
# e.g. policy_get ".daemon.poll_interval_seconds" 60
policy_get() {
    local path="$1"
    local default="${2:-}"
    if [[ -z "$_POLICY_FILE" || ! -f "$_POLICY_FILE" ]]; then
        echo "$default"
        return 0
    fi
    local val
    val=$(jq -r "${path} // \"\"" "$_POLICY_FILE" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}
