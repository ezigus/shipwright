#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: Jira Provider                                       ║
# ║  Sourced by cct-tracker.sh — do not call directly                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file is sourced by cct-tracker.sh.
# It defines provider_* functions used by the tracker router.
# Do NOT add set -euo pipefail or a main() function here.

# ─── Load Jira-specific Config ─────────────────────────────────────────────

provider_load_config() {
    local config="${HOME}/.claude-teams/tracker-config.json"

    JIRA_BASE_URL="${JIRA_BASE_URL:-$(jq -r '.jira.base_url // empty' "$config" 2>/dev/null || true)}"
    JIRA_EMAIL="${JIRA_EMAIL:-$(jq -r '.jira.email // empty' "$config" 2>/dev/null || true)}"
    JIRA_API_TOKEN="${JIRA_API_TOKEN:-$(jq -r '.jira.api_token // empty' "$config" 2>/dev/null || true)}"
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-$(jq -r '.jira.project_key // empty' "$config" 2>/dev/null || true)}"

    # Transition names from config or defaults
    JIRA_TRANSITION_IN_PROGRESS="${JIRA_TRANSITION_IN_PROGRESS:-$(jq -r '.jira.transitions.in_progress // "In Progress"' "$config" 2>/dev/null || echo "In Progress")}"
    JIRA_TRANSITION_IN_REVIEW="${JIRA_TRANSITION_IN_REVIEW:-$(jq -r '.jira.transitions.in_review // "In Review"' "$config" 2>/dev/null || echo "In Review")}"
    JIRA_TRANSITION_DONE="${JIRA_TRANSITION_DONE:-$(jq -r '.jira.transitions.done // "Done"' "$config" 2>/dev/null || echo "Done")}"

    # Strip trailing slash from base URL
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
}

# ─── Jira REST API Helper ─────────────────────────────────────────────────

jira_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64)

    local args=(-sf -X "$method" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json")

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${JIRA_BASE_URL}/rest/api/3/${endpoint}" 2>&1
}

# ─── Find Jira Issue Key from GitHub Issue Body ───────────────────────────

find_jira_key() {
    local gh_issue="$1"

    if [[ -z "$gh_issue" ]]; then
        return 0
    fi

    gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -oE 'Jira:.*[A-Z]+-[0-9]+' | grep -oE '[A-Z]+-[0-9]+' | head -1 || true
}

# ─── Add Comment to Jira Issue ─────────────────────────────────────────────
# Uses Atlassian Document Format (ADF) for the comment body.

jira_add_comment() {
    local issue_key="$1"
    local body="$2"

    local payload
    payload=$(jq -n --arg text "$body" '{
        body: {
            type: "doc",
            version: 1,
            content: [{
                type: "paragraph",
                content: [{type: "text", text: $text}]
            }]
        }
    }')

    jira_api "POST" "issue/${issue_key}/comment" "$payload"
}

# ─── Transition Jira Issue ─────────────────────────────────────────────────
# Finds the transition ID by name and applies it.

jira_transition() {
    local issue_key="$1"
    local transition_name="$2"

    # Get available transitions
    local transitions
    transitions=$(jira_api "GET" "issue/${issue_key}/transitions") || return 0

    # Find transition ID by name
    local transition_id
    transition_id=$(echo "$transitions" | jq -r --arg name "$transition_name" \
        '.transitions[] | select(.name == $name) | .id' 2>/dev/null || true)

    if [[ -z "$transition_id" ]]; then
        # Transition not available — silently skip
        return 0
    fi

    local payload
    payload=$(jq -n --arg id "$transition_id" '{transition: {id: $id}}')

    jira_api "POST" "issue/${issue_key}/transitions" "$payload"
}

# ─── Add Remote Link (PR) to Jira Issue ───────────────────────────────────

jira_attach_pr() {
    local issue_key="$1"
    local pr_url="$2"
    local pr_title="${3:-Pull Request}"

    local payload
    payload=$(jq -n --arg url "$pr_url" --arg title "$pr_title" '{
        object: {url: $url, title: $title}
    }')

    jira_api "POST" "issue/${issue_key}/remotelink" "$payload"
}

# ─── Main Provider Entry Point ─────────────────────────────────────────────
# Called by tracker_notify() in cct-tracker.sh

provider_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    provider_load_config

    # Silently skip if not configured
    [[ -z "$JIRA_BASE_URL" || -z "$JIRA_API_TOKEN" ]] && return 0

    # Find the linked Jira issue
    local jira_key=""
    if [[ -n "$gh_issue" ]]; then
        jira_key=$(find_jira_key "$gh_issue")
    fi
    [[ -z "$jira_key" ]] && return 0

    case "$event" in
        spawn|started)
            jira_transition "$jira_key" "$JIRA_TRANSITION_IN_PROGRESS" || true
            jira_add_comment "$jira_key" "Pipeline started for GitHub issue #${gh_issue}" || true
            ;;
        stage_complete)
            # detail format: "stage_id|duration|description"
            local stage_id duration stage_desc
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            duration=$(echo "$detail" | cut -d'|' -f2)
            stage_desc=$(echo "$detail" | cut -d'|' -f3)
            jira_add_comment "$jira_key" "Stage ${stage_id} complete (${duration}) — ${stage_desc}" || true
            ;;
        stage_failed)
            # detail format: "stage_id|error_context"
            local stage_id error_ctx
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            error_ctx=$(echo "$detail" | cut -d'|' -f2-)
            jira_add_comment "$jira_key" "Stage ${stage_id} failed: ${error_ctx}" || true
            ;;
        review|pr-created)
            jira_transition "$jira_key" "$JIRA_TRANSITION_IN_REVIEW" || true
            if [[ -n "$detail" ]]; then
                jira_attach_pr "$jira_key" "$detail" "PR for #${gh_issue}" || true
            fi
            ;;
        completed|done)
            jira_transition "$jira_key" "$JIRA_TRANSITION_DONE" || true
            jira_add_comment "$jira_key" "Pipeline completed for GitHub issue #${gh_issue}" || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}. ${detail}"
            fi
            jira_add_comment "$jira_key" "$msg" || true
            ;;
    esac

    emit_event "tracker.notify" "provider=jira" "event=$event" "github_issue=$gh_issue"
}
