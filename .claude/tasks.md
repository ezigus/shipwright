# Tasks — Build loop context exhaustion prevention with proactive summarization

## Status: In Progress
Pipeline: standard | Branch: feat/build-loop-context-exhaustion-prevention-154

## Checklist
- [ ] Task 1: Add `context_token_limit` and `context_summary_threshold` to `config/defaults.json`
- [ ] Task 2: Add `loop.context_summary` event type to `config/event-schema.json`
- [ ] Task 3: Implement `write_context_summary()` function in `scripts/sw-loop.sh`
- [ ] Task 4: Implement `check_context_exhaustion()` function in `scripts/sw-loop.sh`
- [ ] Task 5: Initialize `CONTEXT_SUMMARIZED=false` in loop state setup and restart reset
- [ ] Task 6: Call `check_context_exhaustion` in `run_single_agent_loop()` after each iteration
- [ ] Task 7: Implement `inject_context_summary()` function in `scripts/lib/loop-iteration.sh`
- [ ] Task 8: Modify `compose_prompt()` to use compressed context when `CONTEXT_SUMMARIZED=true`
- [ ] Task 9: Add tests for context exhaustion functions and configuration
- [ ] Task 10: Run full test suite and verify no regressions
- [ ] `check_context_exhaustion()` detects when cumulative tokens exceed 70% of configurable limit
- [ ] `write_context_summary()` produces valid JSON with error patterns, files modified, test status, fixes attempted
- [ ] `compose_prompt()` uses compressed summary instead of verbose history when summarized
- [ ] `loop.context_summary` telemetry event emitted with iteration, tokens_used, threshold_pct
- [ ] Configuration keys in `defaults.json` with sensible defaults (180000 tokens, 70% threshold)
- [ ] All new tests pass in `sw-loop-test.sh`
- [ ] Existing tests in `npm test` continue to pass (no regressions)
- [ ] Session continues seamlessly after summarization (verified by integration test)
- [x] No secrets in code
- [x] No external network calls

## Notes
- Generated from pipeline plan at 2026-03-13T20:56:23Z
- Pipeline will update status as tasks complete
