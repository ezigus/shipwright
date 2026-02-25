# Tasks — Read and resolve code review comments from PRs and issues

## Status: In Progress
Pipeline: standard | Branch: refactor/read-and-resolve-code-review-comments-fr-24

## Checklist
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

## Notes
- Generated from pipeline plan at 2026-02-25T20:04:45Z
- Pipeline will update status as tasks complete
