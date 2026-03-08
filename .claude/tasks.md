# Tasks — Pipeline-level intelligent retry with failure classification

## Status: In Progress
Pipeline: standard | Branch: ci/pipeline-level-intelligent-retry-with-fa-67

## Checklist
- [ ] Task 1: Read and understand current `run_stage_with_retry()` retry decision block (lines 999-1052)
- [ ] Task 2: Replace 3-class case statement with 6-class strategy from `get_retry_strategy()`
- [ ] Task 3: Replace fixed exponential backoff with `get_backoff_seconds()` from shared library
- [ ] Task 4: Add `effective_max = min(strategy_max, template_max)` ceiling logic
- [ ] Task 5: Handle `action=skip` (environment errors) — skip retry, emit event, return 1
- [ ] Task 6: Handle `action=immediate` (flaky tests) — skip backoff delay
- [ ] Task 7: Handle `action=analysis` (code bugs) — keep existing retry-context writing
- [ ] Task 8: Enrich `retry.classified` event with strategy metadata
- [ ] Task 9: Add `retry.skipped_not_retryable` and `retry.outcome` events
- [ ] Task 10: Create `scripts/sw-pipeline-retry-test.sh` with classification accuracy tests
- [ ] Task 11: Add strategy correctness and backoff calculation tests
- [ ] Task 12: Add pipeline integration test (mock stage failure → verify retry behavior)
- [ ] Task 13: Add effective-max ceiling test
- [ ] Task 14: Add new test script to `package.json` test chain
- [ ] `run_stage_with_retry()` uses 6-class taxonomy from `failure-classifier.sh` for all retry decisions
- [ ] Retry strategy (immediate/delayed/analysis/skip) is applied per failure class
- [ ] Backoff uses `get_backoff_seconds()` with exponential + jitter instead of fixed `2^attempt`
- [ ] Template `retries` config remains the ceiling — never exceeds configured max
- [ ] Events emitted: `retry.classified` (with strategy metadata), `retry.skipped_not_retryable`, `retry.outcome`
- [ ] All 6 failure classes have test coverage for classification accuracy

## Notes
- Generated from pipeline plan at 2026-03-08T12:17:43Z
- Pipeline will update status as tasks complete
