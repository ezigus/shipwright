# Tasks — Refactor sw-pipeline.sh monolith into modular stage architecture

## Status: In Progress
Pipeline: standard | Branch: refactor/refactor-sw-pipeline-sh-monolith-into-mo-71

## Checklist
- [ ] Task 1: Create `lib/pipeline-utils.sh` — extract utility functions
- [ ] Task 2: Create `lib/pipeline-worktree.sh` — extract worktree functions
- [ ] Task 3: Update sw-pipeline.sh to source new modules, remove extracted utils/worktree code
- [ ] Task 4: Run tests to verify Phase 1 (no regressions)
- [ ] Task 5: Create `lib/pipeline-preflight.sh` — extract setup/validation functions
- [ ] Task 6: Update sw-pipeline.sh, remove preflight code, run tests
- [ ] Task 7: Create `lib/pipeline-runner.sh` — extract classify_error + run_stage_with_retry
- [ ] Task 8: Update sw-pipeline.sh, remove runner code, run tests
- [ ] Task 9: Create `lib/pipeline-self-healing.sh` — extract self-healing loops
- [ ] Task 10: Update sw-pipeline.sh, remove self-healing code, run tests
- [ ] Task 11: Create `lib/pipeline-cli.sh` — extract parse_args + show_help
- [ ] Task 12: Update sw-pipeline.sh, remove CLI code, run tests
- [ ] Task 13: Create `lib/pipeline-orchestrator.sh` — extract run_pipeline + entry points
- [ ] Task 14: Reduce sw-pipeline.sh to thin orchestrator (~450 lines), run tests
- [ ] Task 15: Create `sw-lib-pipeline-runner-test.sh` — unit tests for runner
- [ ] Task 16: Create `sw-lib-pipeline-utils-test.sh` — unit tests for utils
- [ ] Task 17: Final validation — line count check, full test suite, integration tests
- [ ] sw-pipeline.sh is under 500 lines (target: ~450)
- [ ] All 12 stages remain functional (intake, plan, design, build, test, review, compound_quality, pr, merge, deploy, validate, monitor)
- [ ] `npm test` passes without modification to existing tests

## Notes
- Generated from pipeline plan at 2026-03-08T08:35:53Z
- Pipeline will update status as tasks complete
