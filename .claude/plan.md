# Implementation Plan: Cost-Aware Model Routing

## Status Assessment

**Iteration 1 (commit e77d6d2) completed ~80% of the feature.** The task classifier, model router integration, policy config, pipeline/loop wiring, cost-aware template, and test suites are all implemented and passing (40 classifier tests + 51 router tests = 91 total, all green).

### What's Done

- [x] Task 1: `scripts/sw-task-classifier.sh` — 4-signal weighted classifier (322 LOC)
- [x] Task 2: `config/policy.json` — `modelRouting` section with weights, thresholds, stage overrides
- [x] Task 3: `scripts/sw-model-router.sh` — `route_model_auto()`, classifier sourcing, `is_classifier_enabled()`, caching
- [x] Task 4: `scripts/sw-pipeline.sh` — Classifier wired into stage execution (lines 1701-1715)
- [x] Task 5: `scripts/sw-loop.sh` — `classify_task_from_git()` integration (line 437)
- [x] Task 6: `templates/pipelines/cost-aware.json` — `classify_complexity: true` on adaptive stages
- [x] Task 8: `scripts/sw-task-classifier-test.sh` — 40 tests (all passing)
- [x] Task 9: `scripts/sw-model-router-test.sh` — 51 tests including auto-classify integration (all passing)
- [x] Task 10 (partial): `scripts/skills/generated/cost-aware-model-routing.md` — exists but outdated

### What Remains

- [ ] Task 7: A/B testing enhancement — `ab_test_should_use_classifier()` not implemented
- [ ] Task 10: Documentation needs update to reflect actual implementation
- [ ] Gap: Cost-aware template still has some hardcoded models that should use dynamic routing
- [ ] Gap: `route_model()` complexity-low threshold routes to `sonnet` instead of `haiku`
- [ ] Gap: No `line_count` parameter passed from pipeline classifier call (line 1703 passes `"0"`)
- [ ] Gap: Budget enforcement doesn't factor in model tier cost differential

---

## Brainstorming: Design Analysis

### Requirements Clarity

**Minimum viable change**: Fix the remaining gaps and add the A/B testing function. The core infrastructure is solid — the classifier scores correctly, the router selects tiers, caching works, and pipeline/loop integration exists.

**Implicit requirements discovered during analysis**:

- The `route_model()` function routes `complexity < 30` to **sonnet** (line 172), not haiku. This contradicts the classifier design where score < 30 should map to haiku. The issue title says "Haiku for simple tasks" — this is a bug.
- Pipeline classifier call at `sw-pipeline.sh:1703` passes `"0"` for line_count, missing the actual change size signal. Should use `git diff --stat` to get real line count.
- The cost-aware template hardcodes `model: "claude-haiku-4-5-20251001"` on intake/test/audit/pr stages. These should either be removed (let classifier decide) or documented as intentional overrides.

### Alternatives Considered

**Approach A: Fix route_model() threshold + add A/B function** (CHOSEN)

- Pros: Minimal changes (~100 LOC), builds on solid foundation, all tests already exist
- Cons: Doesn't address all gaps in one sweep
- Blast radius: 4-5 files modified

**Approach B: Rewrite router with full tier-aware budget enforcement**

- Pros: More complete solution, budget decisions account for model cost differences
- Cons: Scope creep, existing budget enforcement works at pipeline level, over-engineering for P3
- Rejected: Can be a follow-up issue

**Decision**: Approach A — fix the critical routing bug (sonnet→haiku for simple tasks), implement `ab_test_should_use_classifier()`, enhance pipeline line_count detection, and update documentation.

### Risk Analysis

1. **Changing `route_model()` low-complexity behavior from sonnet→haiku**: Could cause regressions if any code depends on sonnet being the minimum tier.
   - **Mitigation**: Existing escalation (`escalate_model()`) handles haiku→sonnet→opus on failure. The cost-aware template already assigns haiku to several stages. Risk is low.

2. **A/B testing splitting pipelines**: Could introduce non-determinism if A/B state leaks between test runs.
   - **Mitigation**: A/B is opt-in (`a_b_test.enabled: false` by default). Test suite unsets env vars between tests.

3. **Pipeline line_count detection adding latency**: Running `git diff --stat` adds ~50ms.
   - **Mitigation**: Already cached via `PIPELINE_COMPLEXITY_SCORE`. Runs once per pipeline, not per stage.

---

## Architecture Decision Record

### Component Diagram

```
┌─────────────────────┐     ┌──────────────────────────┐
│  Pipeline / Loop     │────▶│  Task Classifier           │
│  (sw-pipeline.sh)    │     │  (sw-task-classifier.sh)   │
│  (sw-loop.sh)        │     │  classify_task()            │
└──────┬──────────────┘     │  classify_task_from_git()   │
       │                     └──────┬───────────────────┘
       │                            │ score 0-100
       ▼                            ▼
┌─────────────────────┐     ┌──────────────────────────┐
│  Model Router        │◀───│  Policy Config             │
│  (sw-model-router.sh)│     │  (config/policy.json)      │
│  route_model()       │     │  modelRouting section       │
│  route_model_auto()  │     └──────────────────────────┘
│  ab_test_*()         │
└──────┬──────────────┘
       │ haiku|sonnet|opus
       ▼
┌─────────────────────┐
│  Cost Tracker        │
│  (sw-cost.sh)        │
│  cost_record()       │
│  cost_check_budget() │
└─────────────────────┘
```

### Interface Contracts

```typescript
// Task Classifier (existing, no changes needed)
classify_task(issue_body: string, file_list?: string, error_context?: string, line_count?: string): number // 0-100
classify_task_from_git(issue_body?: string, error_context?: string): number // 0-100
complexity_to_tier(score: number, low?: number, high?: number): "haiku" | "sonnet" | "opus"

// Model Router (fix: low complexity → haiku instead of sonnet)
route_model(stage: string, complexity?: number): "haiku" | "sonnet" | "opus"
route_model_auto(stage: string, issue_body?: string, file_list?: string, error_context?: string, line_count?: string): "haiku" | "sonnet" | "opus"

// A/B Testing (NEW function)
ab_test_should_use_classifier(): boolean  // true = use classifier, false = use static routing

// Error contracts: all functions fall back to safe defaults on error (sonnet for router, 50 for classifier)
```

### Data Flow

```
GitHub Issue → Pipeline Intake
  → Extract: issue_body, file_list (git diff --name-only), line_count (git diff --stat)
  → classify_task(issue_body, file_list, error_context, line_count) → score 0-100
  → Cache: export PIPELINE_COMPLEXITY_SCORE=$score
  → For each stage:
      → [A/B check] ab_test_should_use_classifier() → static or dynamic routing
      → route_model(stage, PIPELINE_COMPLEXITY_SCORE) → haiku|sonnet|opus
      → Execute stage with selected model
      → On failure: escalate_model() → retry with next tier
      → cost_record(tokens, model, stage)
```

### Error Boundaries

| Component            | Error                  | Handling                                    |
| -------------------- | ---------------------- | ------------------------------------------- |
| Classifier           | crash/invalid output   | Fall back to score=50 (sonnet), log warning |
| Router               | missing config/jq      | Use hardcoded defaults (stage-based)        |
| A/B test             | config error           | Default to control group (static routing)   |
| Cost tracker         | write failure          | Non-blocking, log and continue              |
| Pipeline integration | classifier not sourced | Skip classification, use template defaults  |

---

## Files to Modify

### Modified Files

1. **`scripts/sw-model-router.sh`** — Fix `route_model()` to route low complexity to haiku (not sonnet); add `ab_test_should_use_classifier()`
2. **`scripts/sw-pipeline.sh`** — Enhance classifier call to pass real line_count from `git diff --stat`
3. **`scripts/sw-model-router-test.sh`** — Add tests for haiku routing at low complexity; add A/B classifier tests
4. **`scripts/skills/generated/cost-aware-model-routing.md`** — Update documentation to match actual implementation
5. **`templates/pipelines/cost-aware.json`** — Document which stages use hardcoded models vs dynamic routing

---

## Implementation Steps

### Step 1: Fix `route_model()` low-complexity routing (sw-model-router.sh)

**The critical bug**: Line 172 routes `complexity < COMPLEXITY_LOW` to `sonnet`. Per the design and issue title ("Haiku for simple tasks"), this should be `haiku`.

Change in `route_model()` Strategy 2 block (lines 171-187):

```bash
# Before:
if [[ "$complexity" -lt "$COMPLEXITY_LOW" ]]; then
    model="sonnet"

# After:
if [[ "$complexity" -lt "$COMPLEXITY_LOW" ]]; then
    model="haiku"
```

Also fix the complexity override block (lines 189-196) to be consistent:

```bash
# Before:
if [[ "$complexity" -lt "$COMPLEXITY_LOW" && "$model" == "opus" ]]; then
    model="sonnet"

# After:
if [[ "$complexity" -lt "$COMPLEXITY_LOW" && "$model" == "opus" ]]; then
    model="haiku"
```

**Dependencies**: None
**Blocks**: Step 4 (test updates)

### Step 2: Add `ab_test_should_use_classifier()` (sw-model-router.sh)

Add new function after `is_classifier_enabled()` (~line 270):

```bash
ab_test_should_use_classifier() {
    _resolve_routing_config
    if [[ -n "$MODEL_ROUTING_CONFIG" && -f "$MODEL_ROUTING_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        local enabled percentage
        enabled=$(jq -r '.a_b_test.enabled // false' "$MODEL_ROUTING_CONFIG" 2>/dev/null || echo "false")
        if [[ "$enabled" != "true" ]]; then
            # A/B test disabled → always use classifier (if enabled)
            return 0
        fi
        percentage=$(jq -r '.a_b_test.percentage // 50' "$MODEL_ROUTING_CONFIG" 2>/dev/null || echo "50")
        # Deterministic: use pipeline run ID or RANDOM
        local roll=$(( RANDOM % 100 ))
        if [[ "$roll" -lt "$percentage" ]]; then
            return 0  # Experimental group: use classifier
        else
            return 1  # Control group: use static routing
        fi
    fi
    return 0  # Default: use classifier
}
```

Integrate into `route_model_auto()`: before classifying, check A/B test. If control group, skip classification and return default stage routing.

**Dependencies**: None
**Blocks**: Step 5 (A/B test tests)

### Step 3: Enhance pipeline line_count detection (sw-pipeline.sh)

At line 1703, currently:

```bash
_cls_score=$(classify_task "${GOAL:-}" "" "" "0" 2>/dev/null) || _cls_score=""
```

Should detect file list and line count from git:

```bash
local _cls_files="" _cls_lines="0"
if command -v git >/dev/null 2>&1; then
    _cls_files=$(git diff --name-only HEAD 2>/dev/null || true)
    [[ -z "$_cls_files" ]] && _cls_files=$(git diff --name-only --cached 2>/dev/null || true)
    local _adds _dels
    _adds=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo "0")
    _dels=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$2} END {print s+0}' || echo "0")
    _cls_lines=$((_adds + _dels))
fi
_cls_score=$(classify_task "${GOAL:-}" "$_cls_files" "" "$_cls_lines" 2>/dev/null) || _cls_score=""
```

**Dependencies**: None
**Blocks**: None

### Step 4: Update model-router tests (sw-model-router-test.sh)

Add/fix tests:

- Test that `route_model intake 10` now returns `haiku` (not sonnet)
- Test that `route_model build 10` returns `haiku` (low complexity override)
- Test `ab_test_should_use_classifier()` returns 0 when A/B disabled
- Test `ab_test_should_use_classifier()` returns 0 or 1 when A/B enabled

**Dependencies**: Steps 1, 2

### Step 5: Update documentation (cost-aware-model-routing.md)

Update the skills doc to match actual implementation:

- Correct scoring formula (weighted sum 0-100, not 0-10)
- Document actual thresholds: `< 30 → haiku, 30-79 → sonnet, ≥ 80 → opus`
- Document `policy.json` configuration keys
- Document `ab_test_should_use_classifier()` function
- Document escalation chain
- Add CLI usage examples: `shipwright model route-auto`, `shipwright classify`

**Dependencies**: Steps 1, 2

---

## Task Checklist

- [ ] Task 1: Fix `route_model()` to route complexity < 30 to haiku instead of sonnet
- [ ] Task 2: Fix complexity override block to downgrade opus→haiku (not opus→sonnet) for low complexity
- [ ] Task 3: Add `ab_test_should_use_classifier()` function to sw-model-router.sh
- [ ] Task 4: Integrate A/B test check into `route_model_auto()` flow
- [ ] Task 5: Enhance sw-pipeline.sh classifier call with real file list and line count from git
- [ ] Task 6: Update model-router tests for haiku routing at low complexity
- [ ] Task 7: Add A/B test function tests to sw-model-router-test.sh
- [ ] Task 8: Update cost-aware-model-routing.md documentation with actual implementation details
- [ ] Task 9: Run full test suite (`npm test`) to verify no regressions
- [ ] Task 10: Verify cost-aware template stages make sense with new haiku routing

---

## Task Decomposition (with dependencies)

1. **Fix route_model() haiku routing** — no dependencies
2. **Fix complexity override block** — depends on Task 1
3. **Add ab_test_should_use_classifier()** — no dependencies (parallel with 1-2)
4. **Integrate A/B into route_model_auto()** — depends on Task 3
5. **Enhance pipeline line_count detection** — no dependencies (parallel with all)
6. **Update router tests** — depends on Tasks 1, 2, 3, 4
7. **Add A/B test tests** — depends on Tasks 3, 4
8. **Update documentation** — depends on Tasks 1-5
9. **Run full test suite** — depends on Tasks 6, 7
10. **Verify cost-aware template** — depends on Task 1

**Parallelism**: Tasks 1-2, 3, and 5 can execute in parallel. Tasks 6-7 in parallel after their deps. Task 8 can overlap with 6-7.

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests** (~6 new): haiku routing at low complexity, A/B function behavior, pipeline line_count extraction
- **Integration tests** (~4 new): route_model_auto with A/B enabled/disabled, end-to-end classify→route→haiku path
- **Existing tests** (91 passing): All must continue to pass — some router tests may need updating for haiku instead of sonnet

### Coverage Targets

- Router: 90% branch coverage (all routing paths including new haiku path)
- A/B function: 100% (small function, 3 paths: disabled, experimental, control)
- Pipeline integration: Verified by existing pipeline test suite

### Critical Paths to Test

- **Happy path**: Simple task (2 files, 30 lines, docs keywords) → score 14 → haiku selected
- **Error case 1**: A/B test config malformed → default to classifier (experimental group)
- **Error case 2**: Haiku fails → escalate_model("haiku") → sonnet → retry
- **Edge case 1**: Score exactly 30 → sonnet (boundary)
- **Edge case 2**: Score exactly 29 → haiku (boundary)
- **Edge case 3**: A/B test at 0% → all control group (static routing)

### Test Commands

```bash
bash scripts/sw-task-classifier-test.sh    # 40 tests
bash scripts/sw-model-router-test.sh       # 51+ tests (updating)
npm test                                    # Full suite regression
```

---

## Definition of Done

- [ ] `route_model "intake" 10` returns `haiku` (not sonnet)
- [ ] `route_model "build" 10` returns `haiku` (low complexity overrides static config)
- [ ] `ab_test_should_use_classifier()` exists and respects A/B config
- [ ] Pipeline classifier uses real git diff for file list and line count
- [ ] All 91+ existing tests pass
- [ ] New tests cover haiku routing boundaries and A/B function
- [ ] Documentation reflects actual scoring formula, thresholds, and CLI commands
- [ ] No regressions in `npm test`

---

## User Stories

### Primary

**As a** Shipwright pipeline operator, **I want** simple tasks (docs, single-file fixes) to automatically route to Haiku, **so that** I reduce pipeline costs by 30-50% without manual model selection.

### Secondary

**As a** pipeline administrator, **I want** A/B testing between classifier-routed and static-routed pipelines, **so that** I can validate cost savings against success rate impact before full rollout.

## Acceptance Criteria (Given/When/Then)

1. **Given** a task with 1 file and 20 lines of docs changes, **When** the pipeline runs with cost-aware template, **Then** the classifier scores < 30 and routes to haiku.
2. **Given** a task with 10+ files and architecture keywords, **When** classified, **Then** scores >= 80 and routes to opus.
3. **Given** `modelRouting.enabled: false` in policy.json, **When** pipeline runs, **Then** classifier is skipped and static stage models are used.
4. **Given** A/B test enabled at 50%, **When** 100 pipelines run, **Then** approximately 50 use classifier routing and 50 use static routing, with cost/success metrics logged.
5. **Given** haiku fails on a misclassified task, **When** escalation triggers, **Then** the task retries with sonnet automatically.

## Edge Cases from User Perspective

1. **Empty state**: No previous cost data → cost dashboard shows "No usage data yet" (existing behavior, no regression)
2. **Error state**: Classifier crashes mid-pipeline → falls back to sonnet, pipeline continues without interruption
3. **Overload state**: 100+ files in a single task → capped at score 90, routes to opus appropriately

---

## Endpoint Specification

_Not applicable — internal CLI/library change, no API endpoints._

## Rate Limiting

_Not applicable — internal pipeline orchestration._

## Versioning

Scripts use `VERSION="3.2.4"`. No version bump needed — this is additive/fix behavior within existing feature.
