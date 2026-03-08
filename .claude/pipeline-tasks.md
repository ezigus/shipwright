# Pipeline Tasks — Test flakiness detection and isolated auto-retry

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/test-output-parser.sh` with vitest/jest/generic output parsing
- [ ] Task 2: Create `scripts/sw-lib-test-output-parser-test.sh` with unit tests for parser
- [ ] Task 3: Modify `stage_test()` in `pipeline-stages-build.sh` to integrate flakiness retry after test failure
- [ ] Task 4: Record individual test results to flakiness DB from pipeline test stage
- [ ] Task 5: Add `trends` subcommand to `sw-test-flaky.sh` for time-series data
- [ ] Task 6: Add flakiness types to `dashboard/src/types/api.ts`
- [ ] Task 7: Add `/api/flakiness` endpoint to `dashboard/server.ts`
- [ ] Task 8: Add `fetchFlakiness()` to `dashboard/src/core/api.ts`
- [ ] Task 9: Create `dashboard/src/views/flakiness.ts` with table and trends
- [ ] Task 10: Create `dashboard/src/views/flakiness.test.ts` with unit tests
- [ ] Task 11: Wire flakiness view into router and main
- [ ] Task 12: Create `scripts/sw-flakiness-integration-test.sh` — end-to-end synthetic flaky test
- [ ] Task 13: Run full test suite and fix any regressions
- [ ] Flakiness tracker stores test results across pipelines with pass/fail/skip counts (existing ✅, verify integration)
- [ ] Flakiness score calculated: fail_rate between 10-90% over last N runs = flaky (existing ✅)
- [ ] When flaky test fails in pipeline, auto-retry up to 3 times before declaring failure
- [ ] `shipwright test-flaky list|score|record|prune|report|trends` all functional
- [ ] Dashboard shows flakiness trends and most unreliable tests
- [ ] Test suite validates detection and retry logic on synthetic flaky tests
- [ ] All existing tests continue to pass (no regressions)

## Context
- Pipeline: standard
- Branch: test/test-flakiness-detection-and-isolated-au-69
- Issue: #69
- Generated: 2026-03-08T18:16:26Z
