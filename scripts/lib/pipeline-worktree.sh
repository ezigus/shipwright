#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-worktree.sh — Git worktree lifecycle for pipeline isolation    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Extracted from sw-pipeline.sh for modular architecture.
# Guard: prevent double-sourcing
[[ -n "${_PIPELINE_WORKTREE_LOADED:-}" ]] && return 0
_PIPELINE_WORKTREE_LOADED=1

VERSION="3.2.4"

# ─── Worktree Isolation ───────────────────────────────────────────────────
# Creates a git worktree for parallel-safe pipeline execution

pipeline_setup_worktree() {
    local worktree_base=".worktrees"
    local name="${WORKTREE_NAME}"

    # Auto-generate name from issue number or timestamp
    if [[ -z "$name" ]]; then
        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            name="pipeline-issue-${ISSUE_NUMBER}"
        else
            name="pipeline-$(date +%s)"
        fi
    fi

    local worktree_path="${worktree_base}/${name}"
    local branch_name="pipeline/${name}"

    info "Setting up worktree: ${DIM}${worktree_path}${RESET}"

    # Ensure worktree base exists
    mkdir -p "$worktree_base"

    # Remove stale worktree if it exists
    if [[ -d "$worktree_path" ]]; then
        warn "Worktree already exists — removing: ${worktree_path}"
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Delete stale branch if it exists
    git branch -D "$branch_name" 2>/dev/null || true

    # Create worktree with new branch from current HEAD
    git worktree add -b "$branch_name" "$worktree_path" HEAD

    # Store original dir for cleanup, then cd into worktree
    ORIGINAL_REPO_DIR="$(pwd)"
    cd "$worktree_path" || { error "Failed to cd into worktree: $worktree_path"; return 1; }
    CLEANUP_WORKTREE=true

    success "Worktree ready: ${CYAN}${worktree_path}${RESET} (branch: ${branch_name})"
}

pipeline_cleanup_worktree() {
    if [[ "${CLEANUP_WORKTREE:-false}" != "true" ]]; then
        return
    fi

    local worktree_path
    worktree_path="$(pwd)"

    if [[ -n "${ORIGINAL_REPO_DIR:-}" && "$worktree_path" != "$ORIGINAL_REPO_DIR" ]]; then
        cd "$ORIGINAL_REPO_DIR" 2>/dev/null || cd /
        # Only clean up worktree on success — preserve on failure for inspection
        if [[ "${PIPELINE_EXIT_CODE:-1}" -eq 0 ]]; then
            info "Cleaning up worktree: ${DIM}${worktree_path}${RESET}"
            # Extract branch name before removing worktree
            local _wt_branch=""
            _wt_branch=$(git worktree list --porcelain 2>/dev/null | grep -A1 "worktree ${worktree_path}$" | grep "^branch " | sed 's|^branch refs/heads/||' || true)
            if ! git worktree remove --force "$worktree_path" 2>/dev/null; then
                warn "Failed to remove worktree at ${worktree_path} — may need manual cleanup"
            fi
            # Clean up the local branch
            if [[ -n "$_wt_branch" ]]; then
                if ! git branch -D "$_wt_branch" 2>/dev/null; then
                    warn "Failed to delete local branch ${_wt_branch}"
                fi
            fi
            # Clean up the remote branch (if it was pushed)
            if [[ -n "$_wt_branch" && "${NO_GITHUB:-}" != "true" ]]; then
                git push origin --delete "$_wt_branch" 2>/dev/null || true
            fi
        else
            warn "Pipeline failed — worktree preserved for inspection: ${DIM}${worktree_path}${RESET}"
            warn "Clean up manually: ${DIM}git worktree remove --force ${worktree_path}${RESET}"
        fi
    fi
}
