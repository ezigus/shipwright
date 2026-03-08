# Pipeline Tasks — Pipeline stage timeout enforcement and auto-recovery

## Implementation Checklist
- [ ] Task 1: Add `pipeline.stage_timeouts` section to `config/policy.json` with per-stage values
- [ ] Task 2: Add `pipeline.stage_timeouts` defaults to `config/defaults.json`
- [ ] Task 3: Add `stage.timeout` event type to `config/event-schema.json`
- [ ] Task 4: Implement `get_stage_timeout()` function in `scripts/sw-pipeline.sh`
- [ ] Task 5: Implement `capture_timeout_diagnostics()` function in `scripts/sw-pipeline.sh`
- [ ] Task 6: Implement `run_with_stage_timeout()` function in `scripts/sw-pipeline.sh`
- [ ] Task 7: Modify `run_stage_with_retry()` to call `run_with_stage_timeout()` instead of direct stage function
- [ ] Task 8: Add `timeout_seconds` config to pipeline templates (standard, autonomous, full, hotfix, fast, cost-aware)
- [ ] Task 9: Write test file `scripts/sw-pipeline-timeout-test.sh` with 8+ test cases
- [ ] Task 10: Run `npm test` and verify all existing tests still pass
- [ ] Task 11: Manually verify timeout enforcement with a mock slow stage
- [ ] `get_stage_timeout()` resolves timeout from template config > policy > defaults > hardcoded
- [ ] Stages that exceed their timeout are terminated with SIGTERM (then SIGKILL after 30s)
- [ ] Diagnostic context (process tree, log tail, git status) captured before kill
- [ ] `stage.timeout` event emitted to events.jsonl with stage, timeout_s, elapsed_s
- [ ] Timed-out stages classified as `infrastructure` and retried per existing retry logic
- [ ] All 9 pipeline templates have appropriate `timeout_seconds` (or rely on defaults)
- [ ] 8+ test cases covering timeout trigger, diagnostics, events, retry, config resolution
- [ ] `npm test` passes with no regressions
- [ ] Build stage default timeout is 90min (5400s), all others default to 30min (1800s)

## Context
- Pipeline: standard
- Branch: ci/pipeline-stage-timeout-enforcement-and-a-62
- Issue: #62
- Generated: 2026-03-08T08:14:15Z
