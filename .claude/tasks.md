# Tasks — 

## Status: In Progress
Pipeline: standard | Branch: 

## Checklist
- [x] Task 1: Implement `get_stage_timeout()` with 4-tier fallback resolution
- [x] Task 2: Implement `capture_timeout_diagnostics()` for pre-kill context capture
- [x] Task 3: Implement `run_with_stage_timeout()` with watchdog pattern and graceful termination
- [x] Task 4: Integrate timeout into `run_stage_with_retry()` with error classification
- [x] Task 5: Define `stage.timeout` event schema in `config/event-schema.json`
- [x] Task 6: Add per-stage timeouts to `config/defaults.json` and `config/policy.json`
- [x] Task 7: Update all 9 pipeline templates with `timeout_seconds` per stage
- [x] Task 8: Write comprehensive test suite (`sw-pipeline-timeout-test.sh`, 19 tests)
- [x] Task 9: Generate timeout-resilience-patterns skill documentation
- [x] Task 10: Verify all tests pass (19/19 timeout tests, 218/218 core vitest tests)
- [x] Each pipeline stage has a configurable timeout (default: 30min, build: 90min)
- [x] Timeout triggers graceful termination (SIGTERM → 30s → SIGKILL) with diagnostic context captured
- [x] Auto-retry with backoff for infrastructure failures (exit code 124 classified as infrastructure)
- [x] Manual retry option for non-recoverable timeouts (configuration errors escalate immediately)
- [x] Timeout events logged to events.jsonl with stage, duration, cause, diagnostic_file
- [x] Test coverage for timeout enforcement and recovery paths (19 tests)
- [x] All pipeline templates updated with per-stage timeout_seconds
- [x] Config resolution chain works: template > policy > defaults > hardcoded fallbacks

## Notes
- Generated from pipeline plan at 2026-03-08T12:22:21Z
- Pipeline will update status as tasks complete
