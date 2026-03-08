# Design: Cost-aware model routing: Haiku for simple tasks, Opus for complex

## Context

Shipwright pipelines currently use a single model (typically Sonnet or Opus) for all stages regardless of task complexity. Simple tasks like documentation updates, single-file fixes, and intake/PR stages consume expensive Opus tokens unnecessarily. The goal is to route simple tasks to Haiku (5-19x cheaper) and reserve Opus for genuinely complex work, reducing pipeline costs by 30-50% without impacting quality.

**Constraints from the codebase:**

- Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- Shell scripts use `set -euo pipefail` with `jq` for JSON manipulation
- All config through `config/policy.json` and `~/.shipwright/optimization/model-routing.json`
- 91 existing tests provide a safety net; changes must not break them
- Pipeline stages execute sequentially; model selection happens once per stage
- Iteration 1 (commit `e77d6d2`) implemented ~80% of the feature; this design covers the remaining fixes and enhancements

**Critical bug discovered:** `route_model()` at `sw-model-router.sh:172` routes low-complexity tasks (`score < 30`) to **sonnet** instead of **haiku**, directly contradicting the issue title and the classifier's own `complexity_to_tier()` function.

## Decision

### Approach: Fix routing bug + add A/B testing + enhance classifier signal

The existing architecture is sound — a weighted classifier feeds a complexity score into a stage-aware router. We fix the routing bug (sonnet->haiku for simple tasks), add the missing `ab_test_should_use_classifier()` function for gradual rollout, and enhance the pipeline's classifier call with real `git diff` data instead of hardcoded `"0"` for line count.

### Component Diagram

```
                    ┌────────────────────────────┐
                    │       config/policy.json    │
                    │  modelRouting: {            │
                    │    classifier_weights,      │
                    │    complexity_thresholds,    │
                    │    stage_overrides           │
                    │  }                          │
                    └────────┬───────────────────┘
                             │ weights, thresholds
     ┌───────────────────────┼───────────────────────────┐
     │                       │                           │
     ▼                       ▼                           ▼
┌─────────────────┐  ┌────────────────────┐  ┌──────────────────────┐
│ Task Classifier  │  │   Model Router      │  │   Cost Tracker        │
│ sw-task-         │  │   sw-model-         │  │   (in sw-model-       │
│ classifier.sh    │──│   router.sh         │──│   router.sh)          │
│                  │  │                     │  │                       │
│ classify_task()  │  │ route_model()       │  │ record_usage()        │
│ _score_file_cnt()│  │ route_model_auto()  │  │ show_report()         │
│ _score_change()  │  │ escalate_model()    │  │ log_ab_result()       │
│ _score_error()   │  │ ab_test_should_*()  │  │                       │
│ _score_keywords()│  │ is_classifier_en()  │  │                       │
│ complexity_to_   │  │                     │  │                       │
│   tier()         │  │                     │  │                       │
└────────┬────────┘  └──────┬─────────────┘  └───────────┬──────────┘
         │ score 0-100      │ haiku|sonnet|opus          │ JSONL records
         ▼                  ▼                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Pipeline Orchestrator (sw-pipeline.sh) / Build Loop (sw-loop.sh)   │
│                                                                      │
│  1. classify_task() → PIPELINE_COMPLEXITY_SCORE (cached)             │
│  2. route_model(stage, score) → model selection per stage            │
│  3. Execute stage with CLAUDE_MODEL=$model                           │
│  4. On failure: escalate_model() → retry with next tier              │
│  5. record_usage() → append cost to usage log                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Interface Contracts

```typescript
// ─── Task Classifier (sw-task-classifier.sh) ───────────────────────
// No changes needed — existing implementation is correct

classify_task(
  issue_body: string,
  file_list?: string,     // newline-separated file paths
  error_context?: string, // error message text
  line_count?: string     // total lines changed (additions + deletions)
): number
// Returns: 0-100 complexity score
// Error: returns 50 (safe middle ground → sonnet)
// Formula: (file_score×0.3 + change_score×0.3 + error_score×0.2 + keyword_score×0.2)

complexity_to_tier(
  score: number,
  low_threshold?: number,  // default 30
  high_threshold?: number  // default 80
): "haiku" | "sonnet" | "opus"
// <30 → haiku, 30-79 → sonnet, ≥80 → opus

// ─── Model Router (sw-model-router.sh) ─────────────────────────────

route_model(
  stage: string,       // pipeline stage id
  complexity?: number  // 0-100, default 50
): "haiku" | "sonnet" | "opus"
// Resolution order:
//   1. Config file routes (.routes[stage].model or .default_routing[stage])
//   2. Built-in defaults (complexity + stage category)
//   3. Complexity overrides (downgrade opus→haiku if low, upgrade haiku→opus if high)
// Error: returns "sonnet" (safe default)

route_model_auto(
  stage: string,
  issue_body?: string,
  file_list?: string,
  error_context?: string,
  line_count?: string
): "haiku" | "sonnet" | "opus"
// Classifies via classify_task(), caches in PIPELINE_COMPLEXITY_SCORE,
// then delegates to route_model()
// Error: falls back to route_model(stage, 50)

escalate_model(
  current_model: "haiku" | "sonnet" | "opus"
): "sonnet" | "opus"
// haiku→sonnet, sonnet→opus, opus→opus (ceiling)

ab_test_should_use_classifier(): boolean  // NEW
// Returns 0 (true) = use classifier, 1 (false) = use static routing
// When A/B disabled: always returns 0 (use classifier)
// When A/B enabled: RANDOM % 100 < percentage → 0, else → 1
// Error: returns 0 (default to classifier)

is_classifier_enabled(): boolean
// Reads policy.json modelRouting.enabled
// Error: returns 1 (false)

record_usage(
  stage: string,
  model: "haiku" | "sonnet" | "opus",
  input_tokens?: number,  // default 0
  output_tokens?: number  // default 0
): void
// Appends JSONL to ~/.shipwright/optimization/model-usage.jsonl
// Error: non-blocking, log and continue
```

### Data Flow

```
GitHub Issue #N
       │
       ▼
[Pipeline Intake]
       │
       ├─ Extract: GOAL from issue body
       ├─ Extract: file_list = git diff --name-only HEAD
       ├─ Extract: line_count = git diff --numstat | sum(adds + dels)  ← ENHANCED
       │
       ▼
[classify_task(GOAL, file_list, "", line_count)]
       │
       ├─ _score_file_count(file_list)       → 10-90
       ├─ _score_change_size(line_count)     → 10-90
       ├─ _score_error_complexity("")        → 10
       ├─ _score_keywords(GOAL)              → 10-90
       │
       ▼
[Weighted sum → score 0-100]
       │
       ├─ export PIPELINE_COMPLEXITY_SCORE=$score  (cached for all stages)
       │
       ▼
[For each stage in pipeline:]
       │
       ├─ [ab_test_should_use_classifier()]  ← NEW
       │      ├─ true  → route_model(stage, PIPELINE_COMPLEXITY_SCORE)
       │      └─ false → route_model(stage, 50)  (static/default routing)
       │
       ▼
[route_model(stage, score)]
       │
       ├─ Check config: .routes[stage].model or .default_routing[stage]
       ├─ If no config: apply complexity thresholds
       │      ├─ score < 30  → haiku   ← FIXED (was: sonnet)
       │      ├─ score ≥ 80  → opus
       │      └─ else        → stage-based default (haiku/sonnet/opus)
       ├─ Apply overrides:
       │      ├─ If opus but score < 30 → haiku  ← FIXED (was: sonnet)
       │      └─ If haiku but score ≥ 80 → opus
       │
       ▼
[Execute stage with selected model]
       │
       ├─ On success: record_usage(stage, model, tokens_in, tokens_out)
       └─ On failure: escalate_model(model) → retry with next tier
```

### Error Boundaries

| Component        | Error Scenario                        | Handling                                            | Propagation                        |
| ---------------- | ------------------------------------- | --------------------------------------------------- | ---------------------------------- |
| **Classifier**   | `jq` missing, policy.json malformed   | Use default weights (30/30/20/20)                   | Silent — returns valid score       |
| **Classifier**   | Crash or non-numeric output           | Fall back to score=50 (sonnet tier)                 | Warning logged, pipeline continues |
| **Router**       | Config file missing or unreadable     | Use built-in stage defaults                         | Silent — returns valid model       |
| **Router**       | Invalid stage name                    | Apply complexity-only logic, default sonnet         | Returns valid model                |
| **A/B Test**     | Config missing, `jq` unavailable      | Return 0 (use classifier — experimental group)      | Silent                             |
| **Cost Tracker** | Write failure to JSONL                | Non-blocking, log warning                           | Does not fail the pipeline         |
| **Pipeline**     | Classifier not sourced (file missing) | Skip classification entirely, use template defaults | Warning logged                     |
| **Escalation**   | Already at opus ceiling               | Return opus (no change)                             | Expected behavior                  |

## Alternatives Considered

### 1. External classification service (API-based scorer)

**Pros:** Language-agnostic; could use ML model for better accuracy; centralizable across repos.

**Cons:** Adds network dependency to every pipeline run; latency (100-500ms per call vs ~5ms for local bash); requires infrastructure; overkill for 4-signal heuristic. The local classifier achieves sufficient accuracy for cost routing — it doesn't need to be perfect, just directionally correct (misclassifications are caught by the escalation chain).

**Rejected:** Complexity and latency cost outweigh marginal accuracy gains.

### 2. Per-stage static model assignment only (no classifier)

**Pros:** Simplest possible implementation; zero runtime cost; fully deterministic.

**Cons:** Cannot adapt to task complexity. A documentation PR uses opus for `build` stage (wasteful), while an architecture refactor uses haiku for `intake` (fine, but misses the nuance). The cost-aware template already does static assignment for some stages — the classifier adds the adaptive layer on top.

**Rejected:** Leaves 30-40% of potential savings on the table for complex repos with varied task types.

### 3. Token-budget-based routing (route based on remaining budget, not complexity)

**Pros:** Directly optimizes for the budget constraint; simple mental model ("cheap when budget is low").

**Cons:** Degrades quality unpredictably — early pipeline stages get opus, late stages get haiku regardless of actual need. A failing build loop would keep using haiku because budget is consumed, when it actually needs opus to reason about the failure. Complexity-based routing is semantically correct; budget enforcement is a separate orthogonal concern (and already exists at the pipeline level via `abort_on_budget`).

**Rejected:** Conflates cost control with quality control. These should remain independent mechanisms.

## Implementation Plan

### Files to create

None. All changes modify existing files.

### Files to modify

| File                                                   | Change                                                          | LOC |
| ------------------------------------------------------ | --------------------------------------------------------------- | --- |
| `scripts/sw-model-router.sh:172-173`                   | Fix `sonnet` → `haiku` for complexity < 30                      | 2   |
| `scripts/sw-model-router.sh:190-191`                   | Fix opus downgrade to `haiku` (not `sonnet`) for low complexity | 2   |
| `scripts/sw-model-router.sh:75`                        | Fix comment: "Below this: use haiku" (not sonnet)               | 1   |
| `scripts/sw-model-router.sh:403`                       | Fix dead `awk "BEGIN {}"` → `local cost="0"`                    | 1   |
| `scripts/sw-model-router.sh:~270`                      | Add `ab_test_should_use_classifier()` function (~20 LOC)        | 20  |
| `scripts/sw-model-router.sh:~240`                      | Integrate A/B check into `route_model_auto()`                   | 5   |
| `scripts/sw-pipeline.sh:1703`                          | Replace `"0"` with real `git diff --numstat` line count         | 10  |
| `scripts/sw-model-router-test.sh`                      | Add/update tests for haiku routing + A/B function               | 40  |
| `scripts/skills/generated/cost-aware-model-routing.md` | Update docs to match actual implementation                      | ~50 |
| `templates/pipelines/cost-aware.json`                  | Verify stage model assignments are consistent                   | 0-5 |

### Dependencies

None. No new external dependencies. Uses existing `jq`, `awk`, `git` tooling.

### Risk areas

1. **Haiku routing regression** — Changing the default low-complexity tier from sonnet to haiku means simpler stages may now use a less capable model. **Mitigated by:** the escalation chain (`haiku→sonnet→opus` on failure) and the fact that the cost-aware template already assigns haiku to intake/test/audit/pr stages without issues.

2. **A/B non-determinism** — `RANDOM % 100` in bash is pseudo-random and not cryptographically seeded. For A/B testing purposes this is acceptable (we need statistical distribution, not security). **Mitigated by:** A/B is disabled by default; opt-in only.

3. **Test expectations** — Some existing router tests may assert `sonnet` for low-complexity scenarios and need updating to expect `haiku`. **Mitigated by:** the 91-test safety net will catch exactly which assertions need updating.

4. **`git diff` in detached HEAD / no-repo contexts** — Pipeline may run in environments without a git working tree. **Mitigated by:** all git calls wrapped in `command -v git` checks with `|| true` fallbacks to `"0"`.

## Validation Criteria

- [ ] `route_model "intake" 10` returns `haiku` (not `sonnet`)
- [ ] `route_model "build" 10` returns `haiku` (low complexity overrides built-in opus default)
- [ ] `route_model "build" 90` returns `opus` (high complexity preserved)
- [ ] `route_model "test" 50` returns `sonnet` (mid-range, stage default)
- [ ] `complexity_to_tier 29` returns `haiku` (boundary: just below threshold)
- [ ] `complexity_to_tier 30` returns `sonnet` (boundary: at threshold)
- [ ] `escalate_model "haiku"` returns `sonnet` (upgrade path intact)
- [ ] `ab_test_should_use_classifier` returns 0 when A/B test disabled
- [ ] `ab_test_should_use_classifier` returns 0 or 1 when A/B test enabled at 50%
- [ ] Pipeline classifier call uses real `git diff` line count (not hardcoded `"0"`)
- [ ] All 91+ existing tests pass (with updated expectations where needed)
- [ ] `npm test` full suite passes with no regressions
- [ ] Cost-aware template stages are consistent with new haiku routing logic
- [ ] `record_usage()` no longer spawns an empty `awk` process (line 403 fixed)
