# Pipeline Tasks — Build iteration quality scoring with adaptive prompting

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-quality-score.sh` with scoring functions and adaptive actions
- [ ] Task 2: Add `loop.quality_scored` and `loop.quality_escalated` to `config/event-schema.json`
- [ ] Task 3: Integrate quality scoring into `scripts/sw-loop.sh` main loop
- [ ] Task 4: Create `scripts/sw-loop-quality-score-test.sh` bash test suite
- [ ] Task 5: Add `IterationQualityScore` type to `dashboard/src/types/api.ts`
- [ ] Task 6: Create `dashboard/src/core/quality-score.ts` with rendering helpers
- [ ] Task 7: Create `dashboard/src/core/quality-score.test.ts` vitest tests
- [ ] Task 8: Add quality trend panel to `dashboard/src/views/metrics.ts`
- [ ] Task 9: Run full test suite (`npm test`) and fix any failures
- [ ] Task 10: Verify event schema consistency and edge case handling
- [ ] `compute_iteration_quality_score()` produces correct weighted scores for all component combinations
- [ ] Score is logged to events.jsonl as `loop.quality_scored` with all component values
- [ ] Score < 30 triggers prompt adaptation (verifiable by GOAL modification)
- [ ] Score < 15 for 2+ consecutive iterations triggers model escalation to Opus
- [ ] Dashboard renders quality trend chart with threshold lines
- [ ] All tests pass (`npm test`)
- [ ] No regressions in existing loop behavior (convergence, stuckness detection, circuit breaker)
- [ ] Bash 3.2 compatible (no associative arrays, no `${var,,}`)

## Context
- Pipeline: standard
- Branch: feat/build-iteration-quality-scoring-with-ada-68
- Issue: #68
- Generated: 2026-03-08T08:35:19Z
