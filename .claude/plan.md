# Implementation Plan: Fix Infinite Quality Loop from Stale Findings

## Problem Analysis

### Root Cause

The compound audit cascade accumulates findings across multiple cycles in `_cascade_all_findings`. When code modifications occur during the build loop, these findings become **stale** (line numbers shift, code structure changes). However, agents still receive these stale findings with instructions to "avoid repeating" them. The structural deduplication logic (file + category + line within 5) fails to match because line numbers have shifted, causing agents to report the same logical issue as "new" findings with different line numbers. This creates an infinite loop:

1. Cycle N finds issue X at file.js:42
2. Code is modified in build loop → line numbers change
3. Re-enter compound quality
4. Agents get stale finding (file.js:42, issue X) in "Previously Found Issues"
5. Agent can't structurally match the old finding (code has shifted to line 50)
6. Agent flags the same issue at file.js:50 as a new critical finding
7. Cascade doesn't converge (always finding "new" issues that are just location-shifted old ones)
8. Loop repeats

### Why Current Fixes Don't Prevent This

- PR #142 fixed **convergence detection** (we now properly stop when findings repeat)
- But it didn't fix **finding staleness** (findings from before code edits are still passed to agents)
- The structural dedup only works if line numbers haven't changed much, which fails for modified code

## Requirements & Success Criteria

### Acceptance Criteria (Definition of Done)

1. **Findings don't accumulate across builds:** When re-entering compound_quality after a build loop, findings are isolated to that specific pass
2. **Structural matching works:** Dedup logic correctly identifies true duplicates even when code has been modified
3. **No false infinite loops:** Cascade converges within max_cycles, even when code is heavily modified
4. **Backwards compatible:** Existing dedup logic and convergence checks still work
5. **Testable:** Verify with a test case where agents make changes and cascade runs multiple times

## Design Alternatives Considered

### Alternative A: "Fresh cascade per rebuild" (CHOSEN)

**Approach:** Clear `_cascade_all_findings` when entering compound_quality from a successful build

- **Pros:**
  - Simple, low risk: no stale findings can ever accumulate
  - Ensures each cascade cycle sees fresh code state
  - Prevents the structural matching problem entirely
- **Cons:**
  - Loses deduplication across build iterations (might re-report issues if agent partially fixes)
  - Slightly higher API cost (agents might rediscover same issues)

### Alternative B: "Verify findings before reuse"

**Approach:** Before passing findings to agents, verify they still match current code

- **Pros:**
  - Keeps institutional knowledge (valid findings persist across builds)
  - Only removes truly stale findings
- **Cons:**
  - Complex: requires smart code matching or git blame analysis
  - Slow: every finding verification is expensive

### Alternative C: "Cycle-scoped findings"

**Approach:** Only pass findings from the most recent cycle to next cycle, not all accumulated findings

- **Pros:**
  - Simpler than B, more sophisticated than A
  - Keeps some dedup benefit (same-cycle duplicates caught)
- **Cons:**
  - Still vulnerable to findings staleness over multiple cycles
  - Harder to reason about when exactly findings get cleared

### Alternative D: "Timestamp & age out findings"

**Approach:** Add timestamp metadata, age out findings older than N minutes or older than the last git commit

- **Pros:**
  - Very precise, catches the exact moment findings become stale
- **Cons:**
  - Requires tracking git state, timestamps, and complex metadata
  - Significant implementation complexity

## Chosen Approach: Alternative A + Verification Phase

**Why:**

- **Simplicity wins:** The pipeline is already complex; minimal changes reduce regression risk
- **Correctness first:** Better to re-run audits cleanly than pass stale data and hope dedup works
- **Cost trade-off acceptable:** Extra audit API calls are small compared to avoiding infinite loops

**Key Insight:** The cascade is cheap relative to the build loop. Clearing findings is safe because the build loop has already tested the code. We're just being extra cautious in quality gates.

## Implementation Steps

### Phase 1: Add Finding Freshness Tracking (Tasks 1-2)

1. **Add metadata to stage_compound_quality:** Track whether findings are from a fresh cascade or carry-forward from rebuild
2. **Add git commit snapshot:** Capture `git rev-parse HEAD` when compound_quality starts, use to invalidate old findings

### Phase 2: Clear Stale Findings (Tasks 3-5)

3. **Detect rebuild context:** Check if we're re-entering compound_quality after a build loop (new git commits since last cascade start)
4. **Clear accumulations on rebuild:** Reset `_cascade_all_findings="[]"` if re-entering after code changes
5. **Log clearing decision:** Emit audit event when findings are cleared so we can trace why cascade restarted

### Phase 3: Improve Structural Dedup (Tasks 6-8)

6. **Enhance structural matching:** Instead of just line±5, also check if finding file was modified since finding was created
7. **Add verification check before agent prompt:** Validate that at least one "Previously Found Issues" actually appears in current diff
8. **Warn about orphaned findings:** Log when findings can't be matched to current code

### Phase 4: Testing & Validation (Tasks 9-12)

9. **Unit test:** Test the new clearing logic in isolation
10. **Integration test:** Verify cascade converges with modified code
11. **Regression test:** Ensure normal (non-modified) cascade still works and dedup still catches duplicates
12. **Manual verification:** Run a pipeline where build loop modifies code multiple times, verify no infinite loop

## Task Decomposition (with dependencies)

- [ ] **Task 1: Add git commit snapshot tracking** (no dependencies)
  - Stores: `git rev-parse HEAD` when cascade starts in `_cascade_start_commit`
  - Location: pipeline-intelligence.sh, stage_compound_quality(), line ~1324
  - ~5 lines added

- [ ] **Task 2: Add freshness metadata to findings JSON** (depends on Task 1)
  - Adds: `created_at_commit` field to each finding
  - Location: compound-audit.sh, compound_audit_build_prompt(), line ~93
  - ~3 lines added

- [ ] **Task 3: Detect rebuild context** (depends on Task 1, blocks Task 4)
  - Check: `[[ $(git rev-parse HEAD) != "$_cascade_start_commit" ]]`
  - Location: pipeline-intelligence.sh, inside while loop before cascade block
  - ~8 lines added

- [ ] **Task 4: Clear stale findings on rebuild** (depends on Task 3)
  - Action: Reset `_cascade_all_findings="[]"` if rebuild detected
  - Location: pipeline-intelligence.sh, while loop, line ~1355
  - ~5 lines added

- [ ] **Task 5: Add audit events for clearing** (depends on Task 4)
  - Events: `compound.findings_cleared`, `compound.rebuild_detected`
  - Location: pipeline-intelligence.sh, alongside clearing code
  - ~6 lines added

- [ ] **Task 6: Enhance structural dedup logic** (depends on Task 2)
  - Update: compound_audit_dedup_structural() to check file modification
  - Use: git diff --name-only to see what files changed
  - Location: compound-audit.sh, compound_audit_dedup_structural(), line ~145
  - ~25 lines added

- [ ] **Task 7: Add pre-prompt verification** (depends on Task 6)
  - Check: Does proposed finding file appear in current diff?
  - Location: compound-audit.sh, compound_audit_build_prompt()
  - ~15 lines added

- [ ] **Task 8: Add orphaned finding warnings** (depends on Tasks 2, 6)
  - Log: "Finding for file.js line 42 not found in current code state"
  - Location: compound-audit.sh, compound_audit_dedup_structural()
  - ~8 lines added

- [ ] **Task 9: Unit test - clearing logic** (depends on Tasks 1-5)
  - Test: \_cascade_all_findings correctly resets on rebuild
  - File: scripts/sw-lib-pipeline-intelligence-test.sh (new test cases)
  - ~40 lines added

- [ ] **Task 10: Unit test - structural dedup enhancement** (depends on Tasks 2, 6, 8)
  - Test: Modified files correctly invalidate old findings
  - File: scripts/sw-lib-compound-audit-test.sh (new test cases)
  - ~45 lines added

- [ ] **Task 11: Integration test - multi-cycle with code changes** (depends on Tasks 1-5, 9)
  - Test: Run cascade → modify code → run cascade again → verify convergence
  - File: scripts/sw-lib-pipeline-intelligence-test.sh (new test)
  - ~50 lines added

- [ ] **Task 12: Regression test - normal cascade (no code changes)** (depends on Task 10)
  - Test: Verify dedup still works when code hasn't changed
  - File: scripts/sw-lib-compound-audit-test.sh
  - ~30 lines added

## Files to Modify

1. **scripts/lib/pipeline-intelligence.sh** (~2000 LOC)
   - Add `_cascade_start_commit` tracking at stage start
   - Add rebuild detection logic in while loop
   - Add clearing logic + audit events
   - **Impact:** ~40-60 lines added, minimal risk (isolated to cascade block)

2. **scripts/lib/compound-audit.sh** (~350 LOC)
   - Add finding metadata (created_at_commit)
   - Enhance structural dedup to check file modifications
   - Add pre-prompt verification
   - **Impact:** ~50-80 lines added, low risk (separate functions)

3. **scripts/sw-lib-compound-audit-test.sh** (~500 LOC)
   - Add test cases for enhanced dedup
   - Test orphaned finding detection
   - **Impact:** ~60-80 lines added, new tests only

4. **scripts/sw-lib-pipeline-intelligence-test.sh** (new or existing)
   - Add test for clearing logic
   - Add test for rebuild detection
   - **Impact:** ~80-120 lines added, new tests only

## Risk Analysis

| Risk                              | Impact                                   | Probability | Mitigation                                                |
| --------------------------------- | ---------------------------------------- | ----------- | --------------------------------------------------------- |
| Findings cleared too aggressively | Lose valid findings, repeat audits       | Low         | Emit audit events for every clear; easy to audit logs     |
| Rebuild detection false positives | Clear when shouldn't; miss issues        | Very low    | git rev-parse HEAD is reliable; unit tests                |
| Enhanced dedup logic bugs         | Keep stale findings OR remove valid ones | Medium      | Unit tests verify both cases; verify against current diff |
| Performance impact                | Cascade takes longer                     | Low         | Cache git diff results; reuse existing \_cascade_diff     |
| Breaking existing behavior        | Convergence breaks, dedup stops working  | Low         | Regression test ensures normal cascade works              |

## Testing Approach

### Unit Tests

- **Test 1:** Rebuild detection correctly identifies when HEAD changed
- **Test 2:** Clearing logic resets \_cascade_all_findings only when needed
- **Test 3:** Structural dedup with file modification detection works
- **Test 4:** Findings with no matching files are flagged as orphaned

### Integration Tests

- **Test 5:** Full cascade with code modification → converges
- **Test 6:** Multiple rebuilds → findings stay fresh
- **Test 7:** Normal cascade (no code changes) → dedup still catches duplicates

### Test Scenarios

1. **Scenario A:** Single cycle, no code changes (baseline)
   - Expected: Normal behavior, agents find issues

2. **Scenario B:** Build loop modifies code, re-enter compound_quality
   - Expected: Findings are cleared, cascade starts fresh

3. **Scenario C:** Multiple build loops with incremental fixes
   - Expected: Findings stay fresh each time, cascade converges

4. **Scenario D:** Code changes but same issue exists
   - Expected: Fresh findings catch the issue again (not treated as duplicate)

## Definition of Done Checklist

- [ ] Task 1: Git commit snapshot added and tracked
- [ ] Task 2: Findings include created_at_commit metadata
- [ ] Task 3: Rebuild detection logic working correctly
- [ ] Task 4: Stale findings cleared on rebuild
- [ ] Task 5: Audit events emitted for all clearing decisions
- [ ] Task 6: Structural dedup enhanced with file modification check
- [ ] Task 7: Pre-prompt verification filters orphaned findings
- [ ] Task 8: Orphaned findings are logged with warnings
- [ ] Task 9: Unit tests for clearing logic pass
- [ ] Task 10: Unit tests for enhanced dedup pass
- [ ] Task 11: Integration test with multi-cycle code changes passes
- [ ] Task 12: Regression test for normal cascade passes
- [ ] All existing tests still pass
- [ ] Code reviewed and approved
- [ ] No regressions in existing pipelines
