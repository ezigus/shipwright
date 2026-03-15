# Tasks — Build loop context exhaustion prevention with proactive summarization

## Status: In Progress
Pipeline: autonomous | Branch: feat/build-loop-context-exhaustion-prevention-154

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-context-monitor.sh` with module guard, constants, `check_context_exhaustion()`, `summarize_loop_state()`, `get_context_usage_pct()`
- [ ] Task 2: Source the new module in `sw-loop.sh` (near line 28 with other lib sources)
- [ ] Task 3: Add context exhaustion check in main loop after `accumulate_loop_tokens` call (~line 2166 in `run_single_agent_loop`)
- [ ] Task 4: Handle `context_exhaustion` status in `run_loop_with_restarts()` — allow restart with summary injection
- [ ] Task 5: Add `loop.context_exhaustion_warning` and `loop.context_exhaustion_restart` event emissions
- [ ] Task 6: Emit `loop.context_usage` event per iteration with cumulative token usage percentage
- [ ] Task 7: Add threshold calculation unit tests to `sw-loop-test.sh`
- [ ] Task 8: Add summarization output unit tests to `sw-loop-test.sh`
- [ ] Task 9: Add restart trigger integration test to `sw-loop-test.sh`
- [ ] Task 10: Verify existing tests still pass after changes
- [ ] `check_context_exhaustion()` correctly identifies when cumulative tokens exceed 70% of context window
- [ ] `summarize_loop_state()` produces compressed state with: goal, iteration count, modified files, error patterns, test status
- [ ] Loop continues seamlessly after summarization-triggered restart without losing critical context
- [ ] `loop.context_exhaustion_warning` event emitted when threshold crossed (observable in events.jsonl)
- [ ] `loop.context_exhaustion_restart` event emitted when restart occurs
- [ ] Per-iteration `loop.context_usage` event includes cumulative token percentage
- [ ] All new code has test coverage (threshold boundaries, summarization output, restart trigger)
- [ ] Existing test suite passes without regression
- [ ] Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- [ ] Uses `set -euo pipefail` and module guard pattern

## Notes
- Generated from pipeline plan at 2026-03-15T18:08:59Z
- Pipeline will update status as tasks complete
