# Implementation Plan: Intelligent Template Auto-Recommendation Engine

**Issue**: #33 — Strategic Improvement: Auto-recommend pipeline templates based on repo analysis and historical success rates
**Goal**: Complete and validate the intelligent template auto-recommendation engine
**Status**: Planning phase
**Created**: 2026-03-05

---

## Executive Summary

The intelligent template auto-recommendation engine is **80% complete** with core components implemented. This plan details the final 20% of work needed to fully satisfy the acceptance criteria, including:

1. Completing outcome-based model updates in the self-optimize feedback loop
2. Ensuring daemon integration collects and uses historical data
3. Adding comprehensive end-to-end testing
4. Documenting the recommendation system for users
5. Validating the confidence scoring and reasoning display

---

## Requirements Clarity

### Minimum Viable Change

- Analyze repo structure and issue complexity
- Display recommendation with confidence score and reasoning
- Track whether recommendation was accepted or overridden
- Record pipeline outcome (success/failure)
- Update recommendation model based on outcomes

### Acceptance Criteria (from Issue #33)

- ✅ `shipwright pipeline start` analyzes repo and suggests template (can override with --template)
- ✅ Recommendation considers: project type, issue complexity, historical success rate per template
- ✅ Display recommendation with confidence score and reasoning
- ❌ Track recommendation acceptance rate and outcome — **NEEDS VALIDATION**
- ❌ Update recommendation model based on acceptance rate and success rate — **NEEDS COMPLETION**

### Implicit Requirements

- Recommendations must not block pipeline execution
- System must work even without historical data (sensible defaults)
- Recommendations should improve over time with more data
- User must always be able to override with --template
- Stats must be queryable to show recommendation effectiveness

---

## Design Alternatives & Rationale

### Alternative 1: Pure Historical Analysis (Chosen Approach)

**Approach**: Track success rates per template per project type, recommend highest-success template

**Pros**:

- Data-driven, learns from outcomes
- Improves recommendations over time
- Easy to explain (show historical win rate)
- Fallback to heuristics when data is sparse

**Cons**:

- Requires historical data accumulation
- Early pipelines use suboptimal templates until data is collected

**Trade-offs**:

- Complexity: Medium
- Performance: Fast (cached calculations)
- Maintainability: Good (rules + data, not pure ML)
- Blast radius: Low (recommendations are advisory, not mandatory)

### Alternative 2: Pure Rule-Based (Not Chosen)

**Approach**: Hardcoded heuristics based on project type/complexity

**Pros**: Fast, deterministic, no data collection needed
**Cons**: Brittle, doesn't improve, hard to maintain as rules grow complex
**Rejected**: Doesn't satisfy "update recommendation model based on outcomes"

### Alternative 3: ML-Based (Not Chosen)

**Approach**: Train a model on historical outcomes
**Pros**: Optimal recommendations
**Cons**: Overkill, requires significant data, hard to debug/explain
**Rejected**: Over-engineered for this use case

---

## Risk Analysis

| Risk                                            | Impact | Likelihood | Mitigation                                         |
| ----------------------------------------------- | ------ | ---------- | -------------------------------------------------- |
| Recommendation blocks pipeline                  | High   | Low        | Non-blocking display, timeout-protected DB calls   |
| Historical data corrupted                       | High   | Low        | Schema validation, atomic writes, cleanup commands |
| Early pipelines get wrong recommendation        | Medium | Medium     | Fallback heuristics, explicit confidence scores    |
| Performance regression on pipeline start        | Medium | Low        | Cache recommendations, profile before optimizing   |
| Recommendation changes user behavior negatively | Medium | Low        | Track override rates, monitor user satisfaction    |
| Database table migration fails                  | High   | Low        | Schema version check, idempotent migrations        |

---

## Alternatives Considered

### Alt A: Store recommendation outcome immediately on pipeline start

**Current approach**: Record at completion
**Considered approach**: Record success/failure immediately based on template choice
**Trade-off**: Recording at completion is correct; we want to know if the recommendation led to success

### Alt B: Include cost data in recommendation scoring

**Current approach**: Use success rate and complexity
**Considered approach**: Weight recommendations by cost (prefer cheap templates)
**Trade-off**: Success rate is primary signal; cost is secondary. Current approach is correct.

### Alt C: Allow users to provide feedback on recommendations

**Current approach**: Implicit feedback via acceptance/override + outcome
**Considered approach**: Explicit feedback form ("was this recommendation helpful?")
**Trade-off**: Implicit is simpler, scales better. Can add explicit feedback later if needed.

---

## Task Decomposition

### Phase 1: Validate & Complete Core Components (4 tasks)

**Dependency**: None

- **Task 1**: Verify database schema exists and migrations run correctly
  - Check `template_recommendations` and `pipeline_outcomes` tables exist
  - Run `shipwright db migrate` to ensure schema is initialized
  - Validate all columns are present and accessible

- **Task 2**: Verify recommendation display in pipeline start
  - Test `shipwright pipeline start --goal "..."` shows recommendation box
  - Verify confidence score, reasoning, and alternatives are displayed
  - Ensure recommendation doesn't block pipeline execution

- **Task 3**: Verify acceptance/override tracking
  - Test recommendation is marked as `accepted=1` when user doesn't override
  - Test recommendation is marked as `accepted=0` when user uses `--template`
  - Verify events are emitted correctly

- **Task 4**: Verify outcome recording at pipeline completion
  - Test `db_update_recommendation_outcome()` is called with correct status
  - Verify outcomes are recorded as 'success' or 'failure' based on pipeline status
  - Check events are emitted

**Dependencies**: Task 1 must complete before Tasks 2-4

### Phase 2: Complete Feedback Loop (3 tasks)

**Dependency**: Phase 1 complete

- **Task 5**: Implement recommendation model update in self-optimize loop
  - `sw-self-optimize.sh`: Add function to read `template_recommendations` outcomes
  - Calculate success rate per template per complexity level
  - Write updated weights to `~/.shipwright/template-weights.json`
  - Ensure Thompson sampling reads the updated weights

- **Task 6**: Add recommendation tracking to daemon output
  - When daemon spawns pipeline via `shipwright pipeline start`, ensure recommendation is shown
  - Show acceptance/override decision in daemon logs
  - Track daemon-spawned recommendations separately if needed

- **Task 7**: Implement continuous model improvement
  - Connect `db_query_recommendation_stats()` output to self-optimize
  - Call `optimize_tune_templates()` after each pipeline completes (already done)
  - Verify weights converge toward better templates over time

**Dependencies**: Task 5→6→7 (sequential)

### Phase 3: Testing & Validation (5 tasks)

**Dependency**: Phase 2 complete

- **Task 8**: Write unit tests for recommendation signals
  - Test each signal function (`_labels_template`, `_dora_template`, `_quality_template`, etc.)
  - Test signal hierarchy and fallback
  - Test Thompson sampling calculation

- **Task 9**: Write integration tests for recommendation+pipeline flow
  - Test full flow: recommend → accept → execute → record outcome
  - Test full flow: recommend → override → execute → record outcome
  - Verify stats are updated after outcomes recorded

- **Task 10**: Write E2E tests for model improvement
  - Create synthetic history of multiple pipelines with different templates
  - Verify recommendation model improves (recommends better-performing templates)
  - Verify acceptance rate tracking

- **Task 11**: Validate stats reporting
  - Test `shipwright recommend stats` shows correct acceptance rate
  - Verify per-template accuracy is calculated
  - Ensure stats match database query results

- **Task 12**: Performance validation
  - Measure pipeline start latency with/without recommendation
  - Ensure database queries are fast (< 100ms)
  - Profile and optimize if needed

**Dependencies**: All independent, can run in parallel

### Phase 4: Documentation & Examples (2 tasks)

**Dependency**: Phase 3 complete

- **Task 13**: Add user documentation
  - Document how recommendations work (8 signals)
  - Explain confidence score interpretation
  - Show examples: when to trust, when to override
  - Add to README and CLAUDE.md

- **Task 14**: Add examples and CLI help improvements
  - Add `--help` examples showing recommendations
  - Add `shipwright recommend stats --help` output
  - Create example showing recommendation acceptance improving over time

**Dependencies**: Independent, can run in parallel

---

## Test Pyramid & Coverage Strategy

### Test Distribution

- **Unit tests** (70%): 50+ tests covering signal functions, scoring logic, database queries
- **Integration tests** (20%): 15+ tests covering pipeline→recommendation→outcome flow
- **E2E tests** (10%): 3+ tests covering full model improvement cycle

### Critical Paths to Test

#### Happy Path

1. User runs `shipwright pipeline start --goal "..."` → recommendation shown → user accepts (no override) → pipeline executes → outcome recorded → stats updated

#### Error Cases

1. No historical data → recommendation uses heuristics + falls back to "standard"
2. Database unavailable → recommendation still works (skips Thompson sampling)
3. Multiple recommendations for same issue → latest outcome overwrites previous

#### Edge Cases

1. Recommendation shown but user interrupts pipeline (status = incomplete)
2. Override with invalid template → should fail at validation
3. Recommendation confidence = 1.0 (label override) vs. 0.3 (fallback)
4. Thompson sampling with 0 historical outcomes
5. Stats query with no data (last 30 days)

### Coverage Targets

- **Signal functions**: 100% coverage (critical business logic)
- **Database functions**: 95% coverage (skip error paths for unavailable DB)
- **Stats queries**: 90% coverage (SQL edge cases)
- **Recommendation display**: 85% coverage (UI formatting variations)
- **Pipeline integration**: 80% coverage (many edge cases in pipeline itself)

---

## Definition of Done

The intelligent template auto-recommendation engine is **complete** when:

1. ✅ **Core recommendation engine**
   - `recommend_template()` produces recommendations with 8 signals
   - Confidence scores are accurate and calibrated
   - Reasoning explains the recommendation

2. ✅ **Pipeline integration**
   - Recommendation is shown on pipeline start (when no --template specified)
   - Recommendation does not block pipeline execution
   - User can override with --template flag

3. ✅ **Tracking & recording**
   - Acceptance/override is recorded in database
   - Pipeline outcome (success/failure) is recorded
   - Events are emitted for analytics

4. ✅ **Model improvement**
   - Self-optimize loop updates template weights based on outcomes
   - Thompson sampling uses updated weights for next recommendation
   - Success rates converge toward better templates over time

5. ✅ **Stats & reporting**
   - `shipwright recommend stats` shows acceptance rate
   - Per-template accuracy is tracked and displayed
   - Users can query recommendation effectiveness

6. ✅ **Daemon integration**
   - Daemon-spawned pipelines collect recommendation data
   - Historical data is available for analysis
   - Recommendations improve as daemon processes more issues

7. ✅ **Testing**
   - 60+ unit tests covering signals and scoring
   - 15+ integration tests covering full flow
   - 3+ E2E tests verifying model improvement
   - All critical paths tested with happy path + error cases + edge cases

8. ✅ **Documentation**
   - User-facing docs explain how recommendations work
   - Examples show when to trust/override recommendations
   - CLI help updated with recommendation details

9. ✅ **Quality gates**
   - All tests pass (npm test)
   - No regressions in pipeline performance
   - Database migrations are idempotent and safe

---

## Files to Modify

### Core Files

- `/Volumes/zHardDrive/code/shipwright/scripts/sw-recommend.sh` — Add model update functions
- `/Volumes/zHardDrive/code/shipwright/scripts/sw-self-optimize.sh` — Connect outcome data to weights update
- `/Volumes/zHardDrive/code/shipwright/scripts/sw-db.sh` — Verify functions exist, add if missing
- `/Volumes/zHardDrive/code/shipwright/scripts/sw-pipeline.sh` — Verify integration points

### Test Files

- `/Volumes/zHardDrive/code/shipwright/scripts/sw-recommend-test.sh` — Add new test suites
- Create: `/Volumes/zHardDrive/code/shipwright/scripts/sw-recommend-integration-test.sh` — New integration tests
- Create: `/Volumes/zHardDrive/code/shipwright/scripts/sw-recommend-e2e-test.sh` — New E2E tests

### Documentation

- `/Volumes/zHardDrive/code/shipwright/README.md` — Add recommendation section
- `/Volumes/zHardDrive/code/shipwright/.claude/CLAUDE.md` — Document recommendation signals
- Create: `/Volumes/zHardDrive/code/shipwright/docs/recommendations.md` — Detailed guide

### Configuration

- `.claude/daemon-config.json` — May need recommendation settings
- `config/policy.json` — May need policy for recommendation overrides

---

## Implementation Steps

### Step 1: Validation & Schema (Task 1)

1. Run `shipwright db migrate` to ensure schema is initialized
2. Query database: verify `template_recommendations` table exists with all columns
3. Query database: verify `pipeline_outcomes` table exists
4. Check indices are created (`idx_recommendations_repo`, `idx_recommendations_template`)
5. Document schema version in implementation

### Step 2: Integration Validation (Tasks 2-4)

1. Run `shipwright pipeline start --goal "test auth feature"` manually
2. Verify recommendation is displayed in formatted box
3. Verify confidence score is shown correctly
4. Verify --template override works and is tracked
5. Complete full pipeline and verify outcome is recorded

### Step 3: Model Update (Task 5)

1. In `sw-self-optimize.sh`, add `optimize_update_recommendation_model()` function
2. Query `template_recommendations` outcomes: `SELECT COUNT(*), SUM(outcome='success') FROM template_recommendations WHERE ... GROUP BY recommended_template`
3. Calculate success rate = successes / total per template per complexity
4. Write weights to `~/.shipwright/template-weights.json`
5. Call from pipeline completion hook (line 2855 in sw-pipeline.sh)

### Step 4: Daemon Integration (Task 6-7)

1. Verify daemon calls `shipwright pipeline start` with recommendation collection
2. Ensure recommendation data is persisted across daemon restarts
3. Daemon improvement cycle: collect outcomes → update weights → use in next recommendation

### Step 5: Testing (Tasks 8-12)

1. Add signal function unit tests to `sw-recommend-test.sh`
2. Create `sw-recommend-integration-test.sh` with full flow tests
3. Create `sw-recommend-e2e-test.sh` with model improvement tests
4. Add to `package.json` test script
5. Run full test suite: `npm test`

### Step 6: Documentation (Tasks 13-14)

1. Add "Recommendations" section to README
2. Document the 8 signals in CLAUDE.md
3. Create `docs/recommendations.md` with examples
4. Update CLI help text in sw-recommend.sh

---

## Metrics & Success Criteria

The implementation is successful when:

| Metric                     | Target                           | Validation                                                       |
| -------------------------- | -------------------------------- | ---------------------------------------------------------------- |
| Test coverage              | 75%+                             | `npm test` coverage report                                       |
| Unit test count            | 50+                              | `grep "assert_pass\|assert_fail" sw-recommend-test.sh`           |
| Signal hierarchy working   | 100%                             | Label override always wins, signal precedence respected          |
| Acceptance rate tracking   | ≥90% accuracy                    | Manual verification + integration tests                          |
| Recommendation latency     | <100ms                           | Measure pipeline start time                                      |
| Model convergence          | Templates ranked by success rate | After 50+ outcomes, verify top template has highest success rate |
| Documentation completeness | 100%                             | All signals documented + examples provided                       |

---

## Risk Mitigation

1. **Data integrity**: Use atomic writes, validate schema on startup
2. **Performance**: Cache recommendations, set DB query timeout to 5s
3. **Fallback**: Heuristics work when DB unavailable
4. **Testing**: Comprehensive test suite prevents regressions
5. **Documentation**: Users understand when to trust vs. override
6. **Rollback**: All changes are reversible (new code, no breaking changes)

---

## Timeline Estimate

- **Phase 1** (Validation): 2-3 hours
- **Phase 2** (Feedback Loop): 4-5 hours
- **Phase 3** (Testing): 6-8 hours
- **Phase 4** (Documentation): 2-3 hours

**Total**: 14-19 hours of work

---

## Next Steps

1. **Immediate**: Run validation tasks (Phase 1) to establish baseline
2. **Short-term**: Complete feedback loop (Phase 2)
3. **Mid-term**: Comprehensive testing (Phase 3)
4. **Long-term**: Documentation and user education (Phase 4)

---

## Dependencies

- **Upstream**: `sw-self-optimize.sh`, `sw-db.sh` — existing infrastructure
- **Downstream**: None
- **External**: None (all internal system)

---

## Acceptance Criteria (from Issue)

- [x] `shipwright pipeline start` analyzes repo and suggests template — **IMPLEMENTED**
- [x] Recommendation considers project type, complexity, historical success — **IMPLEMENTED**
- [x] Display recommendation with confidence score and reasoning — **IMPLEMENTED**
- [ ] Track recommendation acceptance rate and outcome — **NEEDS VALIDATION**
- [ ] Update recommendation model based on outcomes — **NEEDS COMPLETION**

---

**Plan prepared by**: Claude Code Agent
**Last updated**: 2026-03-05
**Status**: Ready for approval
