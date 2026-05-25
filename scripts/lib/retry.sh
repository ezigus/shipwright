#!/usr/bin/env bash
# retry.sh — Exponential backoff with jitter for polling loops.
# Replaces sleep N; check_condition patterns.
set -euo pipefail
[[ -n "${_RETRY_LOADED:-}" ]] && return 0
_RETRY_LOADED=1

# retry <max_attempts> <initial_delay_s> <command...>
# Returns 0 if command succeeds within max_attempts.
# Returns 1 if all attempts fail.
# Delay grows exponentially with random jitter up to 2x initial_delay.
retry() {
    local max_attempts="$1"
    local initial_delay="$2"
    shift 2
    local attempt=0
    local delay="$initial_delay"
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$(( attempt + 1 ))
        if "$@"; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            # Add jitter: delay + random(0..delay)
            local jitter=$(( RANDOM % (delay + 1) ))
            local sleep_time=$(( delay + jitter ))
            # Cap sleep at 60s to avoid excessive waits
            [[ $sleep_time -gt 60 ]] && sleep_time=60
            echo "retry: attempt ${attempt}/${max_attempts} failed — retrying in ${sleep_time}s" >&2
            sleep "$sleep_time"
            # Exponential backoff: double delay each round, cap at 30
            delay=$(( delay * 2 ))
            [[ $delay -gt 30 ]] && delay=30
        fi
    done
    echo "retry: all ${max_attempts} attempts failed" >&2
    return 1
}
