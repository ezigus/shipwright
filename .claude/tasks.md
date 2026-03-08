# Tasks — Refactor sw-pipeline.sh monolith into modular stage architecture

## Status: In Progress
Pipeline: standard | Branch: refactor/refactor-sw-pipeline-sh-monolith-into-mo-71

## Checklist
- [ ] Task 1: Create `lib/stages/` directory and extract all 13 individual stage modules from grouped files
- [ ] Task 2: Update `lib/pipeline-stages.sh` loader to source individual stage files
- [ ] Task 3: Create `lib/pipeline-self-heal.sh` (self_healing_build_test + self_healing_review_build_test + auto_rebase)
- [ ] Task 4: Create `lib/pipeline-orchestrator.sh` (run_pipeline core loop)
- [ ] Task 5: Create `lib/pipeline-completion.sh` (post-pipeline events, cost, memory, learning)
- [ ] Task 6: Create `lib/pipeline-notifications.sh`, `lib/pipeline-heartbeat.sh`, `lib/pipeline-ci.sh`
- [ ] Task 7: Extend `lib/pipeline-utils.sh` with helper functions from monolith
- [ ] Task 8: Deduplicate `lib/pipeline-runner.sh` and `lib/pipeline-preflight.sh` with monolith copies
- [ ] Task 9: Slim `sw-pipeline.sh` to <500 lines — replace extracted code with source statements
- [ ] Task 10: Run `scripts/sw-pipeline-test.sh` — all tests pass without modification
- [ ] Task 11: Run `npm test` — full suite passes
- [ ] Task 12: Verify line count, VERSION consistency, and guard patterns across all modules
- [ ] Each of 12+ stages exists as `lib/stages/<stage-name>.sh` with consistent interface (guard, VERSION, single function)
- [ ] Main `sw-pipeline.sh` is under 500 lines (orchestration + glue only)
- [ ] All existing pipeline tests pass without modification (`scripts/sw-pipeline-test.sh`)
- [ ] Full test suite passes (`npm test`)
- [ ] No code duplication between monolith and lib/ modules
- [ ] `scripts/check-version-consistency.sh` passes
- [ ] Shell syntax check passes on all new modules (`bash -n`)
- [ ] No functional regressions: pipelines run identically before/after refactor

## Notes
- Generated from pipeline plan at 2026-03-08T12:20:13Z
- Pipeline will update status as tasks complete
