---
goal: "Read and resolve code review comments from PRs and issues

## Plan Summary
# Implementation Plan: Read and Resolve Code Review Comments

## Summary

Add review comment triage to Shipwright's PR lifecycle. After opening a PR (or at any review/merge gate), the pipeline fetches all open review comments, classifies each as `fix` / `dismiss` / `human_required` using Claude, acts on substantive comments by re-entering the build loop, dismisses noise with an automated reply, and blocks auto-merge until all threads are resolved.

---

## Files to Modify

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `scripts/sw-pr-lifecycle.sh` | **Modify** | Add `triage_review_comments`, `fetch_review_comments`, `classify_comment`, `act_on_triage`, `dismiss_comment`, `inject_review_feedback` functions |
| 2 | `scripts/sw-pr-lifecycle-test.sh` | **Modify** | Add tests for triage classification, fix injection, dismiss reply, bot detection, NO_GITHUB guard |
| 3 | `scripts/lib/pipeline-stages.sh` | **Modify** | Call `triage_review_comments` from `stage_review` (when PR exists) and before merge in `stage_merge`; inject review feedback in `stage_build` |
| 4 | `config/policy.json` | **Modify** | Add `reviewTriage` policy section with bot author patterns |

---

## Implementation Steps
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Read and resolve code review comments from PRs and issues
## Context
## Decision
### Architecture: Triage-Classify-Act pipeline inside `sw-pr-lifecycle.sh`
### Error handling
### Event telemetry
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {"file": "patterns.json", "relevance": 85, "summary": "Project conventions (node, vitest, npm, commonjs) directly inform how to run tests and structure code during build stage"},
    {"file": "patterns.json", "relevance": 60, "summary": "Bootstrap-detected nodejs project type confirms runtime environment for build"},
    {"file": "failures.json", "relevance": 40, "summary": "Empty failures list means no known pitfalls to avoid, but relevant to check before build"},
    {"file": "decisions.json", "relevance": 20, "summary": "Empty decisions log — no prior architectural choices to honor during implementation"},
    {"file": "global.json", "relevance": 10, "summary": "No cross-repo learnings available to inform this build"}
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Read and resolve code review comments from PRs and issues — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Read and resolve code review comments from PRs and issues

## Implementation Checklist
- [ ] Task 1: Add `reviewTriage` section to `config/policy.json`
- [ ] Task 2: Add `fetch_review_comments()` function to `sw-pr-lifecycle.sh`
- [ ] Task 3: Add `classify_comment()` function to `sw-pr-lifecycle.sh`
- [ ] Task 4: Add `triage_review_comments()` orchestrator to `sw-pr-lifecycle.sh`
- [ ] Task 5: Add `inject_review_feedback()` function to `sw-pr-lifecycle.sh`
- [ ] Task 6: Add `dismiss_comment()` function to `sw-pr-lifecycle.sh`
- [ ] Task 7: Add `triage` subcommand to CLI router and help text in `sw-pr-lifecycle.sh`
- [ ] Task 8: Integrate triage into `stage_review()` in `pipeline-stages.sh`
- [ ] Task 9: Integrate triage + merge-blocking into `stage_merge()` in `pipeline-stages.sh`
- [ ] Task 10: Inject `review-feedback.json` into build loop goal in `stage_build()` in `pipeline-stages.sh`
- [ ] Task 11: Add triage tests to `sw-pr-lifecycle-test.sh`
- [ ] Task 12: Run full test suite and fix any failures
- [ ] `triage_review_comments` function exists in `sw-pr-lifecycle.sh` and fetches + classifies all open PR threads
- [ ] Each comment classified as `fix` | `dismiss` | `human_required` via Claude call (with heuristic fallback)
- [ ] `fix` comments serialized to `.claude/pipeline-artifacts/review-feedback.json`
- [ ] `dismiss` comments get automated reply posted
- [ ] `human_required` comments pause the pipeline at the merge gate
- [ ] Pipeline stage log shows each comment's triage decision
- [ ] Works for both human and bot comments (Copilot, Codex, Dependabot)
- [ ] `$NO_GITHUB` respected — triage skipped in local mode

## Context
- Pipeline: standard
- Branch: refactor/read-and-resolve-code-review-comments-fr-24
- Issue: #24
- Generated: 2026-02-25T20:04:44Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
test_cmd_auto: true
model: opus
agents: 1
loop_start_commit: 3bf2139f24f986ac18e79ac9dd79cf2102ef726b
started_at: 2026-02-25T20:47:18Z
last_iteration_at: 2026-02-25T20:47:18Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-25T20:47:18Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":1540506,"duration_api_ms":293559,"num_turns":41,"res

