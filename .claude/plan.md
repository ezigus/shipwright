# Implementation Plan: Cost-Aware Model Routing

## Brainstorming: Design Analysis

### Requirements Clarity
**Minimum viable change**: A task complexity classifier that scores tasks based on file count, change size, and error context, then feeds that score into the existing `route_model()` function. The existing model router, A/B testing, cost tracking, and cost-aware template already exist — the missing piece is **dynamic complexity classification at runtime**.

**Implicit requirements**:
- The classifier must run fast (< 1s) — it's called before every stage
- Must not break existing pipelines that don't use cost-aware routing
- Must integrate with the existing `INTELLIGENCE_COMPLEXITY` variable used by `pipeline-intelligence.sh`

### Alternatives Considered

**Approach A: Enhance existing `route_model()` with inline classifier**
- Pros: Single file change, minimal blast radius
- Cons: Mixes concerns (routing + classification), harder to test independently
- Blast radius: 1 file

**Approach B: Separate classifier module + policy config integration** (CHOSEN)
- Pros: Clean separation of concerns, testable independently, configurable via policy.json, reusable by other systems (triage, intelligence)
- Cons: 2-3 new files, slightly more complexity
- Blast radius: 3-4 files modified, 2 new files created

**Approach C: LLM-powered classifier (use Claude to assess complexity)**
- Pros: Most accurate classification
- Cons: Adds latency, costs money to classify (defeats purpose), requires API key
- Rejected: Too expensive and slow for a cost-saving feature

**Decision**: Approach B — separate classifier module that `route_model()` calls when no explicit complexity is provided.

### Risk Analysis
1. **Misclassification routes complex tasks to Haiku → failures**: Mitigated by escalation on failure (already exists), and uncertainty threshold routing to next tier up
2. **Breaking existing pipelines**: Mitigated by making classifier opt-in via `cost_aware_mode` flag (already in config)
3. **Performance overhead of file analysis**: Mitigated by caching classifier results per pipeline run
4. **Bash 3.2 compatibility**: Must avoid associative arrays, `readarray`, etc.

---

## Architecture Decision Record

### Component Diagram

```
┌─────────────────────┐     ┌──────────────────────┐
│  Pipeline / Loop     │────▶│  Task Classifier      │
│  (sw-pipeline.sh)    │     │  (sw-task-classifier.sh)│
└──────┬──────────────┘     └──────┬───────────────┘
       │                           │ complexity score
       ▼                           ▼
┌─────────────────────┐     ┌──────────────────────┐
│  Model Router        │◀───│  Policy Config        │
│  (sw-model-router.sh)│     │  (config/policy.json) │
└──────┬──────────────┘     └──────────────────────┘
       │ model selection
       ▼
┌─────────────────────┐
│  Cost Tracker        │
│  (sw-cost.sh)        │
└─────────────────────┘
```

### Data Flow

1. Pipeline starts → intake stage extracts issue metadata
2. **Classifier** analyzes: file count, line changes, error context, keywords → outputs complexity score (0-100)
3. **Router** receives (stage, complexity) → selects model tier (haiku/sonnet/opus)
4. Pipeline runs stage with selected model
5. **Cost tracker** records actual tokens + model used
6. On failure → **escalation** bumps model tier and retries

### Interface Contracts

```typescript
// Task Classifier
classify_task(issue_body: string, file_list?: string, error_context?: string): number // 0-100

// Model Router (existing, enhanced)
route_model(stage: string, complexity?: number): "haiku" | "sonnet" | "opus"

// Policy Config (new section in policy.json)
interface ModelRoutingPolicy {
  enabled: boolean;
  complexity_thresholds: { low: number; high: number };
  stage_overrides: Record<string, "haiku" | "sonnet" | "opus">;
  confidence_threshold: number; // below this, route to next tier up
  classifier_weights: {
    file_count: number;
    line_changes: number;
    error_complexity: number;
    keywords: number;
  };
}
```

### Error Boundaries
- Classifier errors → fall back to default complexity (50), log warning
- Router errors → fall back to sonnet (safe middle ground)
- Cost tracking errors → non-blocking, log and continue

---

## Files to Modify

### New Files
1. **`scripts/sw-task-classifier.sh`** — Task complexity classifier module
2. **`scripts/sw-task-classifier-test.sh`** — Tests for classifier

### Modified Files
3. **`scripts/sw-model-router.sh`** — Integrate classifier into route_model, add auto-classify mode
4. **`scripts/sw-model-router-test.sh`** — Add tests for classifier integration
5. **`config/policy.json`** — Add `modelRouting` section with classifier config
6. **`templates/pipelines/cost-aware.json`** — Add `classify_complexity: true` to stage configs
7. **`scripts/sw-pipeline.sh`** — Call classifier during stage execution, pass complexity to model router
8. **`scripts/lib/loop-iteration.sh`** — Pass classified complexity when selecting model for loop iterations

---

## Implementation Steps

### Task 1: Create Task Complexity Classifier (`sw-task-classifier.sh`)
**Dependencies**: None

Create `scripts/sw-task-classifier.sh` with:

```bash
# classify_task <issue_body> [file_list] [error_context]
# Returns: complexity score 0-100
```

**Scoring heuristics** (weighted, configurable via policy.json):
- **File count signal** (weight 0.3): 1-2 files → 10, 3-5 → 40, 6-10 → 70, 10+ → 90
- **Change size signal** (weight 0.3): <50 lines → 10, 50-200 → 40, 200-500 → 70, 500+ → 90
- **Error complexity signal** (weight 0.2): no error → 10, syntax error → 20, logic error → 50, systemic → 80
- **Keyword/dependency signal** (weight 0.2): docs/chore → 10, fix/feature → 40, refactor → 60, architecture/redesign → 90

Functions to implement:
- `classify_task()` — main entry point
- `_score_file_count()` — score based on number of files
- `_score_change_size()` — score based on line count
- `_score_error_complexity()` — score based on error context
- `_score_keywords()` — score based on issue body keywords
- `_load_classifier_weights()` — load weights from policy.json (with defaults)
- `classify_task_from_git()` — convenience: classify from current git diff

### Task 2: Add `modelRouting` section to `config/policy.json`
**Dependencies**: None (parallel with Task 1)

Add to policy.json:
```json
"modelRouting": {
  "enabled": true,
  "classify_complexity": true,
  "confidence_threshold": 0.7,
  "complexity_thresholds": {
    "low": 30,
    "high": 80
  },
  "classifier_weights": {
    "file_count": 0.3,
    "line_changes": 0.3,
    "error_complexity": 0.2,
    "keywords": 0.2
  },
  "stage_overrides": {},
  "fallback_model": "sonnet"
}
```

### Task 3: Integrate classifier into `sw-model-router.sh`
**Dependencies**: Task 1

Modify `route_model()` to:
1. Accept optional `--auto-classify` flag
2. When complexity is not provided AND auto-classify is enabled, call `classify_task()` with available context
3. Cache classification result in env var (`CLASSIFIED_COMPLEXITY`) to avoid re-running per stage
4. Log classification decision to model usage log

Add new function:
```bash
route_model_auto(stage, issue_body, file_list, error_context)
# Classifies task, then routes based on result
```

### Task 4: Wire classifier into pipeline execution (`sw-pipeline.sh`)
**Dependencies**: Task 3

In the stage execution loop:
1. Source `sw-task-classifier.sh` alongside model router
2. After intake, run classifier on the issue body + detected files
3. Store result in pipeline state (`PIPELINE_COMPLEXITY_SCORE`)
4. Pass complexity to `route_model()` for each subsequent stage
5. Log complexity classification event

### Task 5: Wire classifier into loop iteration (`lib/loop-iteration.sh`)
**Dependencies**: Task 3

In the loop iteration model selection:
1. When `ESCALATE_MODEL` is not set, use classifier to determine complexity
2. Use git diff to count files changed and lines modified for runtime classification
3. Pass dynamic complexity to `route_model()`

### Task 6: Update cost-aware template (`cost-aware.json`)
**Dependencies**: Task 2

Add to each stage config:
```json
"classify_complexity": true
```

Remove hardcoded model assignments from stages that should use dynamic routing. Keep explicit model overrides only for review (opus) and audit (haiku) stages.

### Task 7: Enhance A/B testing for classifier validation
**Dependencies**: Tasks 1, 3

Add to `sw-model-router.sh`:
- `ab_test_should_use_classifier()` — returns true/false based on A/B test config percentage
- When A/B test is active: control group uses static routing, experimental uses classifier
- Log which group each pipeline run belongs to in `ab-results.jsonl`

### Task 8: Create classifier tests (`sw-task-classifier-test.sh`)
**Dependencies**: Task 1

Test cases:
- Simple task (1 file, <50 lines, docs keywords) → score < 30
- Medium task (3-5 files, 100 lines, feature keywords) → score 30-80
- Complex task (10+ files, 500 lines, architecture keywords) → score > 80
- Error context escalation (systemic error → higher score)
- Weight configuration from policy.json
- Fallback when policy.json missing
- `classify_task_from_git()` with mock git output
- Edge cases: empty input, missing fields

### Task 9: Update model-router tests for integration
**Dependencies**: Tasks 3, 8

Add to `sw-model-router-test.sh`:
- Test `route_model_auto()` with mock classifier
- Test that classifier result caching works
- Test fallback when classifier fails

### Task 10: Document complexity heuristics and overrides
**Dependencies**: All above

Update `scripts/skills/generated/cost-aware-model-routing.md` with:
- Classifier scoring formula with weights
- How to override per-stage model in policy.json
- How to tune classifier weights
- A/B testing setup instructions
- How to view routing decisions in cost reports

---

## Task Checklist

- [ ] Task 1: Create `scripts/sw-task-classifier.sh` with classify_task() and scoring functions
- [ ] Task 2: Add `modelRouting` config section to `config/policy.json`
- [ ] Task 3: Integrate classifier into `sw-model-router.sh` route_model_auto()
- [ ] Task 4: Wire classifier into `sw-pipeline.sh` stage execution
- [ ] Task 5: Wire classifier into `scripts/lib/loop-iteration.sh` model selection
- [ ] Task 6: Update `templates/pipelines/cost-aware.json` with dynamic routing
- [ ] Task 7: Enhance A/B testing in model router for classifier validation
- [ ] Task 8: Create `scripts/sw-task-classifier-test.sh` with comprehensive tests
- [ ] Task 9: Update `scripts/sw-model-router-test.sh` with integration tests
- [ ] Task 10: Update documentation in `scripts/skills/generated/cost-aware-model-routing.md`

---

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests** (8 tests): Classifier scoring functions individually, weight loading, edge cases
- **Integration tests** (6 tests): Classifier → Router pipeline, A/B test variant selection, policy.json loading
- **E2E tests** (2 tests): Full pipeline with cost-aware template verifying model selection per stage

### Coverage Targets
- Classifier module: 90% branch coverage (all scoring paths, weight combinations)
- Router integration: 80% (existing tests + new auto-classify paths)
- Critical paths: simple/medium/complex classification boundaries, escalation on failure, fallback on classifier error

### Critical Paths to Test
- **Happy path**: Issue with 2 files, 30 lines → classifier scores < 30 → haiku selected → stage succeeds
- **Error case 1**: Classifier crashes → falls back to complexity 50 → sonnet selected
- **Error case 2**: Haiku fails on misclassified task → escalation to sonnet → retry succeeds
- **Edge case 1**: Empty issue body → defaults to medium complexity
- **Edge case 2**: 100+ files changed → caps at complexity 100

### Test Command
```bash
npm test                                    # Full suite (vitest)
bash scripts/sw-task-classifier-test.sh    # Classifier unit tests
bash scripts/sw-model-router-test.sh       # Router + integration tests
```

---

## Definition of Done

- [ ] Task complexity classifier correctly scores tasks as simple/medium/complex based on file count, change size, error context, and keywords
- [ ] Model routing uses classifier scores to select haiku/sonnet/opus (verified by unit tests)
- [ ] Configuration in `config/policy.json` allows overriding thresholds, weights, and per-stage models
- [ ] Cost-aware pipeline template uses dynamic classification instead of only hardcoded models
- [ ] Integration with existing cost tracking records which model was selected and why
- [ ] A/B testing mode allows comparing classifier-routed vs static-routed pipelines
- [ ] Budget enforcement respects model routing decisions (existing — verify no regression)
- [ ] All existing tests pass (`npm test` + shell test scripts)
- [ ] New tests cover classifier accuracy at classification boundaries
- [ ] Documentation updated with heuristics, override options, and tuning guide
- [ ] Bash 3.2 compatible (no associative arrays, readarray, etc.)

---

## Endpoint Specification

*Not applicable — this is an internal CLI/library change, not an API endpoint.*

## Rate Limiting

*Not applicable — internal pipeline orchestration.*

## Versioning

Scripts use `VERSION="3.2.4"` — the new classifier will match this version. No breaking changes to existing CLI commands.
