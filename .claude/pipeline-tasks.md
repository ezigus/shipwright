# Pipeline Tasks — Pipeline-level intelligent retry with failure classification

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/failure-classifier.sh` with 6-class taxonomy, classify_failure_from_log(), get_retry_strategy(), get_backoff_seconds(), is_retryable()
- [ ] Task 2: Enhance `classify_error()` in sw-pipeline.sh to use failure-classifier.sh (Task 1 blocks this)
- [ ] Task 3: Enhance `run_stage_with_retry()` in sw-pipeline.sh with per-class retry limits, strategy actions, backoff, and retry budget (Task 1, 2 block this)
- [ ] Task 4: Add retry configuration blocks to pipeline templates (standard.json, autonomous.json, full.json)
- [ ] Task 5: Update config/event-schema.json with retry.outcome and retry.strategy events
- [ ] Task 6: Update config/policy.json with pipeline_retry defaults
- [ ] Task 7: Create `scripts/sw-lib-failure-classifier-test.sh` test suite (Task 1 blocks this)
- [ ] Task 8: Run full test suite (`npm test`) and fix any regressions (all tasks block this)
- [ ] `classify_failure_from_log()` correctly categorizes all 6 failure types with regex pattern matching
- [ ] `run_stage_with_retry()` applies per-class retry strategy (immediate/delayed/analysis/skip)
- [ ] Retry metadata emitted to events.jsonl with `retry.classified`, `retry.outcome`, `retry.strategy` events
- [ ] Pipeline templates include retry configuration (standard, autonomous, full)
- [ ] Test suite (`sw-lib-failure-classifier-test.sh`) passes with all classification and strategy tests green
- [ ] Existing pipeline tests (`sw-pipeline-test.sh`) pass without regression
- [ ] `npm test` passes clean
- [ ] Backward compatible: pipelines without retry config in templates default to 0 retries (no behavior change)

## Context
- Pipeline: standard
- Branch: feat/pipeline-level-intelligent-retry-with-fa-67
- Issue: #67
- Generated: 2026-03-08T08:35:56Z
