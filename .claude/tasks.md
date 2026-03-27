# Tasks — bug: pipeline-tasks.md not cleared on resume — stale tasks injected into build loop

## Status: In Progress
Pipeline: autonomous | Branch: fix/bug-pipeline-tasks-md-not-cleared-on-res-232

## Checklist
- [ ] **Code Complete**
  - [ ] Task 1: initialize_state() removes pipeline-tasks.md
  - [ ] Task 2: resume_state() extracts issue from metadata
  - [ ] Task 3: resume_state() validates and removes stale tasks
  - [ ] Task 4: stage_build() validates before injection
  - [ ] Task 5: TEST_CMD leak investigated and fixed
- [ ] **Tests Pass**
  - [ ] Task 6: Initialize clear test passes
  - [ ] Task 7: Resume validation test passes
  - [ ] Task 8: Injection validation test passes
  - [ ] Task 9: Full integration test passes
  - [ ] Task 10: All 50+ existing tests pass (no regressions)
- [ ] **Acceptance Verified**
  - [ ] Old tasks not injected when issue changes
  - [ ] New tasks ARE injected when issue matches
  - [ ] Malformed files don't crash pipeline
  - [ ] Resume flow unchanged for valid cases
  - [ ] TEST_CMD properly isolated (if issue found)
- [ ] **Quality Checks**
  - [ ] Bash 3.2 compatible (no associative arrays, etc.)

## Notes
- Generated from pipeline plan at 2026-03-27T00:12:48Z
- Pipeline will update status as tasks complete
