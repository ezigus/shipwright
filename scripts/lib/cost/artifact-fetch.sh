#!/usr/bin/env bash
# lib/cost/artifact-fetch.sh — cross-machine cost-breakdown artifact fetcher
#
# Downloads dedicated `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>`
# artifacts produced by `shipwright-pipeline.yml` and merges each one into the
# local rolling baselines via `baseline_update_from_breakdown`.
#
# The catch-all `pipeline-logs-*` artifact also contains `cost-breakdown.json`,
# but it expires in 7 days and its name is run-scoped — this helper targets the
# dedicated artifact (90-day retention, queryable name prefix).
#
# Storage:
#   ${HOME}/.shipwright/baselines/.fetched-runs.json
#     { "merged":  { "<run_id>": {"name": "...", "merged_at": "<iso>"} },
#       "skipped": { "<run_id>": {"reason": "schema_mismatch"|"download_failed"|... } } }
#
# Dependency injection:
#   _GH_BIN  — defaults to `gh`; tests can shim by setting it to a path on PATH.
#
# Preconditions:
#   - `gh` available on PATH (or via _GH_BIN); else returns 1 with warn.
#   - `$NO_GITHUB` unset — honour the project-wide opt-out.
#
# Bash 3.2 compatible (no associative arrays, no readarray, no ${var,,}).
[[ -n "${_COST_ARTIFACT_FETCH_LOADED:-}" ]] && return 0
_COST_ARTIFACT_FETCH_LOADED=1

# Defaults (overridable for tests)
_GH_BIN="${_GH_BIN:-gh}"
ARTIFACT_FETCH_LIMIT_DEFAULT=20
ARTIFACT_FETCH_LIMIT_MAX=100
ARTIFACT_NAME_PREFIX="cost-breakdown-issue-"

# _artifact_fetch_baseline_dir — baseline directory (mirrors baselines.sh).
_artifact_fetch_baseline_dir() {
    echo "${SW_BASELINE_DIR:-${HOME}/.shipwright/baselines}"
}

# _artifact_fetch_tracking_file — path to .fetched-runs.json.
_artifact_fetch_tracking_file() {
    echo "$(_artifact_fetch_baseline_dir)/.fetched-runs.json"
}

# _artifact_fetch_init_tracking — create an empty tracking file if missing.
_artifact_fetch_init_tracking() {
    local dir file
    dir=$(_artifact_fetch_baseline_dir)
    file=$(_artifact_fetch_tracking_file)
    mkdir -p "$dir" 2>/dev/null || return 1
    if [[ ! -f "$file" ]]; then
        echo '{"merged":{},"skipped":{}}' > "$file" 2>/dev/null || return 1
    fi
    return 0
}

# _artifact_fetch_is_merged <run_id>
# 0 if already merged, 1 otherwise.
_artifact_fetch_is_merged() {
    local run_id="${1:-}"
    [[ -z "$run_id" ]] && return 1
    local file
    file=$(_artifact_fetch_tracking_file)
    [[ -f "$file" ]] || return 1
    jq -e --arg id "$run_id" '.merged[$id] != null' "$file" >/dev/null 2>&1
}

# _artifact_fetch_record_merged <run_id> <artifact_name>
_artifact_fetch_record_merged() {
    local run_id="${1:-}"
    local name="${2:-}"
    [[ -z "$run_id" ]] && return 1
    _artifact_fetch_init_tracking || return 1
    local file tmp ts
    file=$(_artifact_fetch_tracking_file)
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
    jq --arg id "$run_id" --arg name "$name" --arg ts "$ts" \
        '.merged[$id] = {name: $name, merged_at: $ts} | del(.skipped[$id])' \
        "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file" || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    return 0
}

# _artifact_fetch_record_skipped <run_id> <reason>
_artifact_fetch_record_skipped() {
    local run_id="${1:-}"
    local reason="${2:-unknown}"
    [[ -z "$run_id" ]] && return 1
    _artifact_fetch_init_tracking || return 1
    local file tmp ts
    file=$(_artifact_fetch_tracking_file)
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
    jq --arg id "$run_id" --arg reason "$reason" --arg ts "$ts" \
        '.skipped[$id] = {reason: $reason, skipped_at: $ts}' \
        "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file" || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    return 0
}

# _artifact_fetch_preflight — verify gh is callable and NO_GITHUB is unset.
# Returns 0 if usable, 1 otherwise (with warn).
_artifact_fetch_preflight() {
    if [[ "${NO_GITHUB:-}" == "1" || "${NO_GITHUB:-}" == "true" ]]; then
        warn "cost.artifact_fetch: NO_GITHUB is set — skipping remote fetch"
        return 1
    fi
    if ! command -v "$_GH_BIN" >/dev/null 2>&1; then
        warn "cost.artifact_fetch: '${_GH_BIN}' not found on PATH — skipping remote fetch"
        return 1
    fi
    return 0
}

# _artifact_fetch_match_filter <artifact_name> <filter>
# Filter forms: "all" | "issue:<N>" | "branch:<name>" (branch is best-effort —
# the workflow does not encode branch in the name, so branch filtering is a
# no-op for now and is reserved for future use). Returns 0 on match.
_artifact_fetch_match_filter() {
    local name="${1:-}"
    local filter="${2:-all}"
    [[ -z "$name" ]] && return 1
    case "$filter" in
        all|"")
            # Any artifact starting with our prefix matches.
            case "$name" in
                "${ARTIFACT_NAME_PREFIX}"*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        issue:*)
            local n="${filter#issue:}"
            # Sanitize to digits only.
            n=$(printf '%s' "$n" | tr -cd '0-9')
            [[ -z "$n" ]] && return 1
            case "$name" in
                "${ARTIFACT_NAME_PREFIX}${n}-run-"*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        branch:*)
            # Branch is not encoded in the artifact name; we treat this as
            # "match all" for now and rely on the caller to narrow later.
            case "$name" in
                "${ARTIFACT_NAME_PREFIX}"*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# _artifact_fetch_clamp_limit <requested>
# Echoes a sanitized positive integer within [1, ARTIFACT_FETCH_LIMIT_MAX].
_artifact_fetch_clamp_limit() {
    local req="${1:-${ARTIFACT_FETCH_LIMIT_DEFAULT}}"
    # Strip non-digits; fall back to default.
    req=$(printf '%s' "$req" | tr -cd '0-9')
    [[ -z "$req" ]] && req="$ARTIFACT_FETCH_LIMIT_DEFAULT"
    [[ "$req" -lt 1 ]] && req=1
    [[ "$req" -gt "$ARTIFACT_FETCH_LIMIT_MAX" ]] && req="$ARTIFACT_FETCH_LIMIT_MAX"
    echo "$req"
}

# _artifact_fetch_repo_slug — echo "<owner>/<repo>" using gh; empty on failure.
_artifact_fetch_repo_slug() {
    local slug
    slug=$("$_GH_BIN" repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || slug=""
    [[ -n "${GITHUB_REPOSITORY:-}" && -z "$slug" ]] && slug="$GITHUB_REPOSITORY"
    echo "$slug"
}

# _artifact_fetch_list_raw <limit>
# Calls `gh api` once and echoes the raw artifacts JSON array. Tests shim gh.
_artifact_fetch_list_raw() {
    local limit="${1:-100}"
    local slug
    slug=$(_artifact_fetch_repo_slug)
    [[ -z "$slug" ]] && { warn "cost.artifact_fetch: cannot resolve repo slug"; return 1; }
    # GitHub does not support server-side name filtering; we filter client-side.
    "$_GH_BIN" api \
        -H "Accept: application/vnd.github+json" \
        "/repos/${slug}/actions/artifacts?per_page=${limit}" 2>/dev/null \
        | jq -c '.artifacts // []' 2>/dev/null
}

# cost_list_remote_breakdowns [filter] [limit]
# Echoes one JSON object per matching artifact: {run_id, name, issue, created_at, size_bytes}.
# Does not download. Returns 0 even when zero matches; 1 only on hard error.
cost_list_remote_breakdowns() {
    local filter="${1:-all}"
    local limit
    limit=$(_artifact_fetch_clamp_limit "${2:-}")

    _artifact_fetch_preflight || return 1

    local raw
    raw=$(_artifact_fetch_list_raw 100) || return 1
    [[ -z "$raw" ]] && raw="[]"

    # Filter, then take up to <limit>. We compute issue by stripping the prefix.
    # Bash 3.2 compatible loop: read each entry's name, test with helper.
    local count=0 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$count" -ge "$limit" ]] && break
        local name run_id created_at size_bytes issue
        name=$(echo "$line"     | jq -r '.name // ""'         2>/dev/null)
        run_id=$(echo "$line"   | jq -r '.workflow_run.id // .id // ""' 2>/dev/null)
        created_at=$(echo "$line" | jq -r '.created_at // ""' 2>/dev/null)
        size_bytes=$(echo "$line" | jq -r '.size_in_bytes // 0' 2>/dev/null)
        [[ -z "$name" ]] && continue
        if _artifact_fetch_match_filter "$name" "$filter"; then
            # Parse issue from name: cost-breakdown-issue-<N>-run-...
            issue=$(printf '%s' "$name" \
                | sed -n 's/^cost-breakdown-issue-\([0-9][0-9]*\)-run-.*$/\1/p')
            jq -nc \
                --arg name "$name" \
                --arg run_id "$run_id" \
                --arg issue "$issue" \
                --arg created_at "$created_at" \
                --argjson size_bytes "${size_bytes:-0}" \
                '{run_id: $run_id, name: $name, issue: $issue,
                  created_at: $created_at, size_bytes: $size_bytes}'
            count=$((count + 1))
        fi
    done < <(echo "$raw" | jq -c '.[]' 2>/dev/null)

    return 0
}

# cost_fetch_remote_breakdowns [filter] [limit]
# Downloads up to <limit> matching artifacts and merges them into local
# baselines. Idempotent: skips run_ids already present in .fetched-runs.json.
#
# filter: "all" | "issue:<N>" | "branch:<name>"
# limit:  positive integer, default 20, max 100
# Returns: 0 on soft-success (incl. zero matches), 1 on hard error (gh missing).
# Emits:   event "cost.artifact_fetched" {count, filter}
cost_fetch_remote_breakdowns() {
    local filter="${1:-all}"
    local limit
    limit=$(_artifact_fetch_clamp_limit "${2:-}")

    _artifact_fetch_preflight || return 1
    _artifact_fetch_init_tracking || {
        warn "cost.artifact_fetch: failed to initialize tracking file"
        return 1
    }

    if ! type baseline_update_from_breakdown >/dev/null 2>&1; then
        warn "cost.artifact_fetch: baselines.sh not loaded; cannot merge"
        return 1
    fi

    local slug
    slug=$(_artifact_fetch_repo_slug)
    [[ -z "$slug" ]] && { warn "cost.artifact_fetch: cannot resolve repo slug"; return 1; }

    local raw
    raw=$(_artifact_fetch_list_raw 100) || return 1
    [[ -z "$raw" ]] && raw="[]"

    local merged=0 skipped=0 attempted=0
    local tmp_root
    tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/sw-cost-artifact-XXXXXX" 2>/dev/null) || {
        warn "cost.artifact_fetch: cannot create temp dir"
        return 1
    }

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$attempted" -ge "$limit" ]] && break
        local name run_id issue
        name=$(echo "$line"   | jq -r '.name // ""'                       2>/dev/null)
        run_id=$(echo "$line" | jq -r '.workflow_run.id // .id // ""'     2>/dev/null)
        [[ -z "$name" || -z "$run_id" ]] && continue
        _artifact_fetch_match_filter "$name" "$filter" || continue
        attempted=$((attempted + 1))

        if _artifact_fetch_is_merged "$run_id"; then
            continue
        fi

        issue=$(printf '%s' "$name" \
            | sed -n 's/^cost-breakdown-issue-\([0-9][0-9]*\)-run-.*$/\1/p')

        local dest="${tmp_root}/${run_id}"
        mkdir -p "$dest" 2>/dev/null || { skipped=$((skipped + 1)); continue; }

        # `gh run download` accepts either run_id+name or just artifact name.
        # We use --name <name> so the helper works with `gh` 2.x without needing
        # the run-id to also be a workflow run id (artifact API exposes both).
        if ! "$_GH_BIN" run download --name "$name" --dir "$dest" --repo "$slug" \
                >/dev/null 2>&1; then
            _artifact_fetch_record_skipped "$run_id" "download_failed" || true
            skipped=$((skipped + 1))
            continue
        fi

        local breakdown="${dest}/cost-breakdown.json"
        if [[ ! -f "$breakdown" ]]; then
            _artifact_fetch_record_skipped "$run_id" "missing_file" || true
            skipped=$((skipped + 1))
            continue
        fi

        # Validate schema_version == 1 (the helper's known contract).
        if ! jq -e '.schema_version == 1' "$breakdown" >/dev/null 2>&1; then
            _artifact_fetch_record_skipped "$run_id" "schema_mismatch" || true
            skipped=$((skipped + 1))
            continue
        fi

        # Merge into baselines (best-effort; non-zero from merge is logged).
        if ! baseline_update_from_breakdown "$breakdown" "$issue" >/dev/null 2>&1; then
            _artifact_fetch_record_skipped "$run_id" "merge_failed" || true
            skipped=$((skipped + 1))
            continue
        fi

        _artifact_fetch_record_merged "$run_id" "$name" || true
        merged=$((merged + 1))
    done < <(echo "$raw" | jq -c '.[]' 2>/dev/null)

    rm -rf "$tmp_root" 2>/dev/null || true

    info "cost.artifact_fetch: merged=${merged} skipped=${skipped} attempted=${attempted} filter=${filter}"
    emit_event "cost.artifact_fetched" \
        "count=${merged}" \
        "skipped=${skipped}" \
        "attempted=${attempted}" \
        "filter=${filter}" 2>/dev/null || true

    return 0
}
