#!/usr/bin/env bash
# sed-portable.sh — Cross-platform sed -i wrapper.
# Provides sed_inplace() for callers that don't source compat.sh.
# compat.sh provides the same functionality as sed_i().
set -euo pipefail
[[ -n "${_SED_PORTABLE_LOADED:-}" ]] && return 0
_SED_PORTABLE_LOADED=1

sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}
# Alias to match compat.sh naming
sed_i() { sed_inplace "$@"; }
