#!/usr/bin/env bash
# daemon-runtime.sh — Untracked runtime config overlay for daemon-config.json
# Writes go to .claude/daemon-runtime.json (gitignored) to keep daemon-config.json clean.

write_daemon_runtime() {
    # Usage: write_daemon_runtime [jq-args...] '<filter>'
    # Last argument is always the jq filter; preceding args are jq flags.
    # NOTE: Two concurrent callers could race on the read-modify-write cycle.
    # In practice daemon_self_optimize and optimize_adjust_audit_intensity never
    # overlap, so this is acceptable. If that changes, add a lockfile.
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="."
    local runtime_file="${root}/.claude/daemon-runtime.json"
    mkdir -p "$(dirname "$runtime_file")"
    if [[ ! -f "$runtime_file" ]]; then
        echo '{}' > "$runtime_file"
        chmod 600 "$runtime_file"
    fi
    local tmp_file="${runtime_file}.tmp.$$"
    # Extract last arg (filter) — bash 3.2 compatible via ${!#} indirect expansion
    local filter="${!#}"
    # Build jq args from all but last arg using indexed indirect expansion
    local n=$# i=1
    local jq_args=()
    while [[ $i -lt $n ]]; do
        jq_args+=("${!i}")
        i=$((i+1))
    done
    jq "${jq_args[@]}" "$filter" "$runtime_file" > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$runtime_file"
}
