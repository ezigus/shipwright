# Design: Cost-aware model routing: Haiku for simple tasks, Opus for complex

## Context

Shipwright pipelines currently select Claude models via static per-stage assignments in `templates/pipelines/cost-aware.json` (e.g., intake→haiku, build→sonnet, review→opus) or through manual `complexity` parameters passed to `route_model()` in `scripts/sw-model-router.sh`. This means a trivial 2-file documentation fix runs through the same sonnet/opus stages as a 30-file architecture refactor.

The infrastructure is 70% complete: `sw-model-router.sh` already implements `route_model(stage, complexity)` with threshold-based tier selection (low<30→sonnet, high>80→opus), `escalate_model()` for failure recovery, A/B testing scaffolding, and cost estimation. `sw-cost.sh` provides full token-level cost tracking with budget enforcement. What's missing is a **runtime task complexity classifier** that dynamically scores tasks based on actual signals instead of relying on static stage mappings or a hardcoded default of `complexity=50`.

**Constraints:**

- Bash 3.2 compatible (no associative arrays, `readarray`, `${var,,}`)
- Classifier must execute in <1s (called before every stage)
- Must not break pipelines that don't use cost-aware routing
- Must integrate with existing `INTELLIGENCE_COMPLEXITY` from `scripts/lib/pipeline-intelligence.sh`
- Model cost ratios: Haiku is ~12x cheaper than Sonnet, ~60x cheaper than Opus

## Decision

Introduce a **separate classifier module** (`scripts/sw-task-classifier.sh`) that scores task complexity 0-100 using a weighted heuristic formula, then integrate it into the existing model router as an automatic classification path.

### Architecture

```
┌─────────────────────┐     ┌──────────────────────────┐
│  Pipeline / Loop     │────▶│  Task Classifier           │
│  (sw-pipeline.sh)    │     │  (sw-task-classifier.sh)   │
└──────┬──────────────┘     └──────┬───────────────────┘
       │                           │ complexity score (0-100)
       ▼                           ▼
┌─────────────────────┐     ┌──────────────────────────┐
│  Model Router        │◀───│  Policy Config             │
│  (sw-model-router.sh)│     │  (config/policy.json)      │
└──────┬──────────────┘     └──────────────────────────┘
       │ model selection (haiku|sonnet|opus)
       ▼
┌─────────────────────┐
│  Cost Tracker        │
│  (sw-cost.sh)        │
└─────────────────────┘
```

### Scoring Formula

```
score = (file_count_score × 0.3) + (line_changes_score × 0.3)
      + (error_complexity_score × 0.2) + (keyword_score × 0.2)
```

Each sub-score maps to 0-100:

| Signal           | 0-10 (simple) | 40 (medium)  | 70 (high)     | 90 (complex)           |
| ---------------- | ------------- | ------------ | ------------- | ---------------------- |
| File count       | 1-2 files     | 3-5 files    | 6-10 files    | 10+ files              |
| Line changes     | <50 lines     | 50-200 lines | 200-500 lines | 500+ lines             |
| Error complexity | none / syntax | —            | logic error   | systemic / multi-file  |
| Keywords         | docs, chore   | fix, feature | refactor      | architecture, redesign |

Weights and thresholds are configurable via `config/policy.json` under a new `modelRouting` section.

### Routing Tiers

| Complexity Score | Model Tier | Rationale                                     |
| ---------------- | ---------- | --------------------------------------------- |
| 0-29             | haiku      | Simple tasks: docs, config, single-file fixes |
| 30-79            | sonnet     | Medium tasks: features, multi-file fixes      |
| 80-100           | opus       | Complex tasks: architecture, large refactors  |

### Data Flow

1. **Pipeline intake** extracts issue body, detects changed files via `git diff --name-only`
2. **Classifier** (`classify_task()`) scores the 4 signals → weighted sum → 0-100
3. Result cached in `PIPELINE_COMPLEXITY_SCORE` env var (avoids re-computation per stage)
4. **Router** (`route_model()`) uses cached score for tier selection at each stage
5. **Cost tracker** records model used + tokens consumed
6. On stage failure → existing `escalate_model()` bumps tier and retries

### Error Handling

- **Classifier crashes** → fall back to `complexity=50` (sonnet), log warning via `warn()`
- **Misclassification** (haiku fails on complex task) → existing escalation chain handles it (haiku→sonnet→opus)
- **Missing policy.json section** → use hardcoded defaults for all weights and thresholds
- **Empty inputs** (no issue body, no file list) → default to medium complexity (50)
- **Cost tracking errors** → non-blocking, log and continue

### Interface Contract

```bash
# Task Classifier (new)
classify_task <issue_body> [file_list] [error_context]
# Returns: integer 0-100 via stdout

classify_task_from_git
# Convenience: classify from current working tree git diff

# Model Router (enhanced existing)
route_model <stage> [complexity]
# Enhanced: when complexity omitted and PIPELINE_COMPLEXITY_SCORE is set, uses cached score

route_model_auto <stage> <issue_body> [file_list] [error_context]
# New: classifies then routes in one call
```

```json
// New section in config/policy.json
{
  "modelRouting": {
    "enabled": true,
    "classify_complexity": true,
    "confidence_threshold": 0.7,
    "complexity_thresholds": { "low": 30, "high": 80 },
    "classifier_weights": {
      "file_count": 0.3,
      "line_changes": 0.3,
      "error_complexity": 0.2,
      "keywords": 0.2
    },
    "stage_overrides": {},
    "fallback_model": "sonnet"
  }
}
```

### A/B Testing Integration

The existing A/B framework in `sw-model-router.sh` is extended with `ab_test_should_use_classifier()`. When active:

- **Control group**: static per-stage model assignments (current behavior)
- **Experimental group**: classifier-routed model selection
- Results logged to `ab-results.jsonl` with group tag for cost/success-rate comparison

## Alternatives Considered

1. **Inline classifier in `route_model()`** — Pros: single-file change, minimal blast radius / Cons: mixes routing and classification concerns, harder to unit test scoring logic independently, harder to reuse classifier from other callers (daemon triage, intelligence). Rejected for testability and separation of concerns.

2. **LLM-powered classifier (use Claude to assess complexity)** — Pros: most accurate classification, understands semantic complexity / Cons: adds 2-5s latency per classification call, costs money to classify (defeats the cost-saving purpose), requires API key availability. Rejected because spending tokens to decide how to save tokens is self-defeating.

3. **Reuse daemon triage scoring (`triage_score_issue()`)** — Pros: already exists in `scripts/lib/daemon-triage.sh` / Cons: optimized for daemon prioritization (inverted scale where higher=simpler), doesn't analyze git diffs or error context, couples pipeline routing to daemon internals. Rejected because the scoring signals and scale are wrong for model routing.

## Implementation Plan

### Files to create

- `scripts/sw-task-classifier.sh` — Task complexity classifier module (~200 LOC)
- `scripts/sw-task-classifier-test.sh` — Classifier test suite (~150 LOC)

### Files to modify

- `config/policy.json` — Add `modelRouting` section
- `scripts/sw-model-router.sh` — Add `route_model_auto()`, source classifier, integrate cached score
- `scripts/sw-model-router-test.sh` — Add integration tests for auto-classify path
- `scripts/sw-pipeline.sh` — Source classifier, run after intake, cache `PIPELINE_COMPLEXITY_SCORE`
- `scripts/lib/loop-iteration.sh` — Use `classify_task_from_git()` for dynamic model selection
- `templates/pipelines/cost-aware.json` — Replace hardcoded models with `classify_complexity: true`
- `scripts/skills/generated/cost-aware-model-routing.md` — Document scoring formula, tuning guide

### Dependencies

- No new external dependencies. Uses existing `jq` for JSON parsing.

### Risk areas

- **`sw-pipeline.sh` integration** (Task 4): This is the most trafficked script. Sourcing the classifier must be guarded by `cost_aware_mode` check to avoid impacting non-cost-aware pipelines.
- **Bash 3.2 compatibility**: Scoring logic must avoid associative arrays. Use positional `case` statements and arithmetic `$(( ))` instead.
- **Cache invalidation**: `PIPELINE_COMPLEXITY_SCORE` is set once after intake. If the task scope changes mid-pipeline (unlikely but possible with dynamic file detection), the cached score becomes stale. Acceptable tradeoff for <1s performance.
- **Weight tuning**: Initial weights (0.3/0.3/0.2/0.2) are heuristic. A/B testing (Task 7) validates these empirically.

## Validation Criteria

- [ ] `classify_task "fix typo in README" "README.md" ""` returns score < 30 (routes to haiku)
- [ ] `classify_task "add auth feature" "src/auth.js src/middleware.js src/routes.js src/tests/auth.test.js" ""` returns score 30-80 (routes to sonnet)
- [ ] `classify_task "redesign pipeline architecture" "$(seq 1 15 | xargs -I{} echo file{}.sh)" "systemic failure across modules"` returns score > 80 (routes to opus)
- [ ] Classifier errors (invalid input, missing jq) fall back to complexity=50 without crashing the pipeline
- [ ] Existing pipelines without `cost_aware_mode` are completely unaffected (no behavior change)
- [ ] `route_model_auto()` caches result — calling it twice with same input doesn't re-run classification
- [ ] A/B test mode correctly splits pipelines into control (static) and experimental (classified) groups
- [ ] `policy.json` weight overrides are respected (change `file_count` weight to 0.0, verify file count is ignored)
- [ ] All existing tests pass: `npm test` + `bash scripts/sw-model-router-test.sh`
- [ ] New classifier tests pass: `bash scripts/sw-task-classifier-test.sh` (8+ test cases covering boundaries)
- [ ] Cost-aware template pipeline selects different models for simple vs complex tasks in the same stage

---

## Skill-Required Sections

### Schema Changes

**Not applicable.** This feature uses flat JSON files (`policy.json`, `ab-results.jsonl`, `costs.json`) and environment variables — no database schema involved. The only structural change is adding a `modelRouting` key to the existing `config/policy.json`, which is additive and backwards-compatible (existing consumers ignore unknown keys).

### Data Flow Diagram

```
                        ┌─────────────────┐
                        │  GitHub Issue    │
                        │  (body, labels)  │
                        └────────┬────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  Pipeline Intake Stage   │
                    │  (sw-pipeline.sh)        │
                    │  Extracts: issue_body,   │
                    │  file_list via git diff   │
                    └────────────┬────────────┘
                                 │
              ┌──────────────────▼──────────────────┐
              │  Task Classifier                      │
              │  (sw-task-classifier.sh)               │
              │                                        │
              │  ┌──────────┐  ┌──────────────┐       │
              │  │file_count│  │ line_changes  │       │
              │  │ score×0.3│  │  score×0.3    │       │
              │  └────┬─────┘  └──────┬───────┘       │
              │       │               │                │
              │  ┌────┴────┐  ┌──────┴───────┐       │
              │  │error_ctx│  │  keywords     │       │
              │  │score×0.2│  │  score×0.2    │       │
              │  └────┬────┘  └──────┬───────┘       │
              │       └───────┬──────┘                │
              │               ▼                        │
              │     weighted_sum → 0-100               │
              │  ⚠ FAILURE POINT: jq missing,         │
              │    bad input → fallback to 50           │
              └──────────────────┬──────────────────┘
                                 │ PIPELINE_COMPLEXITY_SCORE (cached)
                                 ▼
              ┌──────────────────────────────────────┐
              │  Model Router                          │
              │  (sw-model-router.sh)                  │
              │                                        │
              │  score < 30 → haiku                    │
              │  30 ≤ score < 80 → sonnet              │
              │  score ≥ 80 → opus                     │
              │  ⚠ FAILURE POINT: router error         │
              │    → fallback to sonnet                │
              └──────────────────┬──────────────────┘
                                 │ selected model
                                 ▼
              ┌──────────────────────────────────────┐
              │  Stage Execution                       │
              │  ⚠ FAILURE POINT: model fails task    │
              │    → escalate_model() bumps tier       │
              └──────────────────┬──────────────────┘
                                 │ tokens consumed
                                 ▼
              ┌──────────────────────────────────────┐
              │  Cost Tracker (sw-cost.sh)             │
              │  Records: model, tokens, cost          │
              │  Checks: daily budget enforcement      │
              │  ⚠ FAILURE POINT: write error          │
              │    → non-blocking, log and continue    │
              └──────────────────────────────────────┘
```

### Idempotency Strategy

- **Classification caching**: `PIPELINE_COMPLEXITY_SCORE` env var is set once after intake. Subsequent `route_model()` calls within the same pipeline read the cached value. Re-running the classifier with identical inputs produces identical output (pure function over static signals).
- **No side effects during classification**: The classifier only reads inputs and produces a score. It writes nothing to disk. Side effects (cost recording, A/B logging) happen downstream in the router and cost tracker.
- **Pipeline restart safety**: If a pipeline restarts from a checkpoint, the classifier re-runs on the same inputs and produces the same score. No deduplication needed.

### Rollback Plan

1. **Feature flag**: Set `"modelRouting": { "enabled": false }` in `config/policy.json` → all classification is skipped, router falls back to existing static behavior.
2. **Template rollback**: Revert `cost-aware.json` to hardcoded model assignments (restore `"model": "haiku"` etc. per stage).
3. **Code rollback**: The classifier is a standalone module sourced conditionally. Removing the `source sw-task-classifier.sh` lines from `sw-pipeline.sh` and `loop-iteration.sh` restores prior behavior with zero impact.
4. **No data migration needed**: The classifier writes no persistent state. A/B test results in `ab-results.jsonl` are append-only and can be ignored.

### Baseline Metrics

- **Current model cost distribution** (static routing via cost-aware.json): ~40% haiku stages (intake, test, audit, pr), ~40% sonnet stages (plan, build, compound_quality), ~20% opus stages (review). Average pipeline cost tracked in `~/.shipwright/costs.json`.
- **Current success rate**: Tracked per-pipeline in cost efficiency metrics (`cost_show_efficiency()`). Baseline to capture before enabling classifier.
- **Classification latency**: Target <100ms (pure bash arithmetic + jq on small JSON). Current `route_model()` latency is ~10ms.

### Optimization Targets

- **Cost reduction**: 30-50% reduction in average pipeline cost by routing simple tasks (estimated 60% of daemon-processed issues) to haiku instead of sonnet/opus. Based on model pricing: haiku input=$0.25/MTok vs sonnet input=$3.00/MTok (12x cheaper).
- **Success rate impact**: <2% degradation. Misclassifications are caught by the existing escalation mechanism — a haiku failure triggers automatic retry with sonnet.
- **Classification overhead**: <100ms added latency per pipeline (one-time at intake, cached for all stages).

### Profiling Strategy

- **A/B testing** (Task 7): Split pipelines into control (static) and experimental (classifier) groups. Compare cost-per-pipeline and success rate across groups over 50+ runs.
- **Cost dashboard**: `shipwright cost show` already provides per-model and per-pipeline cost breakdowns. Compare before/after enabling classifier.
- **Event log analysis**: Classification decisions logged to `events.jsonl`. Query for `classifier_score`, `model_selected`, `stage_outcome` to validate accuracy.

### Benchmark Plan

1. **Before**: Run 10 pipelines with static cost-aware template. Record total cost, per-stage model, success/failure.
2. **After**: Run 10 pipelines with classifier-enabled template on similar issue complexity distribution. Record same metrics.
3. **Success criteria**:
   - Average pipeline cost decreases by ≥20%
   - Pipeline success rate remains within 2% of baseline
   - No pipeline takes >10% longer due to classification overhead
4. **A/B validation**: Run 50+ pipelines with A/B testing enabled. Statistical comparison of cost and success rate between groups.
