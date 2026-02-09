#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: Linear Provider                                     ║
# ║  Sourced by cct-tracker.sh — do not call directly                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file is sourced by cct-tracker.sh.
# It defines provider_* functions used by the tracker router.
# Do NOT add set -euo pipefail or a main() function here.

# ─── Load Linear-specific Config ───────────────────────────────────────────

provider_load_config() {
    local config="${HOME}/.claude-teams/tracker-config.json"

    # API key: env var → tracker-config.json → linear-config.json (legacy)
    LINEAR_API_KEY="${LINEAR_API_KEY:-$(jq -r '.linear.api_key // empty' "$config" 2>/dev/null || true)}"
    if [[ -z "$LINEAR_API_KEY" ]]; then
        local legacy_config="${HOME}/.claude-teams/linear-config.json"
        if [[ -f "$legacy_config" ]]; then
            LINEAR_API_KEY="${LINEAR_API_KEY:-$(jq -r '.api_key // empty' "$legacy_config" 2>/dev/null || true)}"
        fi
    fi

    LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-$(jq -r '.linear.team_id // empty' "$config" 2>/dev/null || true)}"
    LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-$(jq -r '.linear.project_id // empty' "$config" 2>/dev/null || true)}"

    # Status IDs from config or defaults
    STATUS_BACKLOG="${LINEAR_STATUS_BACKLOG:-$(jq -r '.linear.statuses.backlog // empty' "$config" 2>/dev/null || true)}"
    STATUS_TODO="${LINEAR_STATUS_TODO:-$(jq -r '.linear.statuses.todo // empty' "$config" 2>/dev/null || true)}"
    STATUS_IN_PROGRESS="${LINEAR_STATUS_IN_PROGRESS:-$(jq -r '.linear.statuses.in_progress // empty' "$config" 2>/dev/null || true)}"
    STATUS_IN_REVIEW="${LINEAR_STATUS_IN_REVIEW:-$(jq -r '.linear.statuses.in_review // empty' "$config" 2>/dev/null || true)}"
    STATUS_DONE="${LINEAR_STATUS_DONE:-$(jq -r '.linear.statuses.done // empty' "$config" 2>/dev/null || true)}"

    LINEAR_API="https://api.linear.app/graphql"
}

# ─── Linear GraphQL Helper ────────────────────────────────────────────────

linear_graphql() {
    local query="$1"
    local variables="${2:-{}}"

    local payload
    payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

    local response
    response=$(curl -sf -X POST "$LINEAR_API" \
        -H "Authorization: $LINEAR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        error "Linear API request failed"
        echo "$response" >&2
        return 1
    }

    # Check for GraphQL errors
    local errors
    errors=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
    if [[ -n "$errors" ]]; then
        error "Linear API error: $errors"
        return 1
    fi

    echo "$response"
}

# ─── Update Linear Issue Status ────────────────────────────────────────────

linear_update_status() {
    local issue_id="$1"
    local state_id="$2"

    # Skip if no state ID provided
    [[ -z "$state_id" ]] && return 0

    local query='mutation($issueId: String!, $stateId: String!) {
        issueUpdate(id: $issueId, input: { stateId: $stateId }) {
            issue { id identifier }
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg stateId "$state_id" \
        '{issueId: $issueId, stateId: $stateId}')

    linear_graphql "$query" "$vars" >/dev/null
}

# ─── Add Comment to Linear Issue ───────────────────────────────────────────

linear_add_comment() {
    local issue_id="$1"
    local body="$2"

    local query='mutation($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
            comment { id }
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg body "$body" \
        '{issueId: $issueId, body: $body}')

    linear_graphql "$query" "$vars" >/dev/null
}

# ─── Attach PR Link to Linear Issue ───────────────────────────────────────

linear_attach_pr() {
    local issue_id="$1"
    local pr_url="$2"
    local pr_title="${3:-Pull Request}"

    local body
    body=$(printf "PR linked: [%s](%s)" "$pr_title" "$pr_url")
    linear_add_comment "$issue_id" "$body"
}

# ─── Find Linear Issue ID from GitHub Issue Body ──────────────────────────

find_linear_id() {
    local gh_issue="$1"

    if [[ -z "$gh_issue" ]]; then
        return 0
    fi

    gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -o 'Linear ID:.*' | sed 's/.*\*\*Linear ID:\*\* //' | tr -d '[:space:]' || true
}

# ─── Main Provider Entry Point ─────────────────────────────────────────────
# Called by tracker_notify() in cct-tracker.sh

provider_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    provider_load_config

    # Silently skip if no API key
    [[ -z "$LINEAR_API_KEY" ]] && return 0

    # Find the linked Linear issue
    local linear_id=""
    if [[ -n "$gh_issue" ]]; then
        linear_id=$(find_linear_id "$gh_issue")
    fi
    [[ -z "$linear_id" ]] && return 0

    case "$event" in
        spawn|started)
            linear_update_status "$linear_id" "$STATUS_IN_PROGRESS" || true
            linear_add_comment "$linear_id" "Pipeline started for GitHub issue #${gh_issue}" || true
            ;;
        stage_complete)
            # detail format: "stage_id|duration|description"
            local stage_id duration stage_desc
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            duration=$(echo "$detail" | cut -d'|' -f2)
            stage_desc=$(echo "$detail" | cut -d'|' -f3)
            linear_add_comment "$linear_id" "Stage **${stage_id}** complete (${duration}) — ${stage_desc}" || true
            ;;
        stage_failed)
            # detail format: "stage_id|error_context"
            local stage_id error_ctx
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            error_ctx=$(echo "$detail" | cut -d'|' -f2-)
            linear_add_comment "$linear_id" "Stage **${stage_id}** failed\n\n\`\`\`\n${error_ctx}\n\`\`\`" || true
            ;;
        review|pr-created)
            linear_update_status "$linear_id" "$STATUS_IN_REVIEW" || true
            if [[ -n "$detail" ]]; then
                linear_attach_pr "$linear_id" "$detail" "PR for #${gh_issue}" || true
            fi
            ;;
        completed|done)
            linear_update_status "$linear_id" "$STATUS_DONE" || true
            linear_add_comment "$linear_id" "Pipeline completed for GitHub issue #${gh_issue}" || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}\n\nDetails:\n${detail}"
            fi
            linear_add_comment "$linear_id" "$msg" || true
            ;;
    esac

    emit_event "tracker.notify" "provider=linear" "event=$event" "github_issue=$gh_issue"
}
