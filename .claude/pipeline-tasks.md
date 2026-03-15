# Pipeline Tasks — Build loop context exhaustion prevention with proactive summarization

## Implementation Checklist

- [x] Task 1: Create `scripts/lib/loop-context-monitor.sh` with module guard, constants, `check_context_exhaustion()`, `summarize_loop_state()`, `get_context_usage_pct()`
- [x] Task 2: Source the new module in `sw-loop.sh` (near line 28 with other lib sources)
- [x] Task 3: Add context exhaustion check in main loop after `accumulate_loop_tokens` call (~line 2166 in `run_single_agent_loop`)
- [x] Task 4: Handle `context_exhaustion` status in `run_loop_with_restarts()` — allow restart with summary injection
- [x] Task 5: Add `loop.context_exhaustion_warning` and `loop.context_exhaustion_restart` event emissions
- [x] Task 6: Emit `loop.context_usage` event per iteration with cumulative token usage percentage
- [x] Task 7: Add threshold calculation unit tests to `sw-loop-test.sh`
- [x] Task 8: Add summarization output unit tests to `sw-loop-test.sh`
- [x] Task 9: Add restart trigger integration test to `sw-loop-test.sh`
- [x] Task 10: Verify existing tests still pass after changes
- [x] `check_context_exhaustion()` correctly identifies when cumulative tokens exceed 70% of context window
- [x] `summarize_loop_state()` produces compressed state with: goal, iteration count, modified files, error patterns, test status
- [x] Loop continues seamlessly after summarization-triggered restart without losing critical context
- [x] `loop.context_exhaustion_warning` event emitted when threshold crossed (observable in events.jsonl)
- [x] `loop.context_exhaustion_restart` event emitted when restart occurs
- [x] Per-iteration `loop.context_usage` event includes cumulative token percentage
- [x] All new code has test coverage (threshold boundaries, summarization output, restart trigger)
- [x] Existing test suite passes without regression (96/96 loop tests pass)
- [x] Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- [x] Uses `set -euo pipefail` and module guard pattern

## Context

- Pipeline: autonomous
- Branch: feat/build-loop-context-exhaustion-prevention-154
- Issue: #154
- Generated: 2026-03-15T18:08:57Z
- Completed: 2026-03-15
