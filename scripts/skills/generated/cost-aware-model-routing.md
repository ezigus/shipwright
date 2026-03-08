## Cost-Aware Model Routing

Intelligent model selection based on task complexity to reduce pipeline costs 30-50% without sacrificing success rate.

### Architecture

```
sw-pipeline.sh / sw-loop.sh
        │
        ▼
sw-task-classifier.sh         sw-model-router.sh
  classify_task()    ──────▶   route_model()
  classify_task_from_git()     route_model_auto()
  complexity_to_tier()         ab_test_should_use_classifier()
        │                      is_classifier_enabled()
        │ score 0-100           │
        └──────────────────────▶ haiku | sonnet | opus
```

### Complexity Classification Heuristics

**Simple Tasks** (score < 30 → Haiku)

- Single file edits (1-2 files touched)
- Script generation or template filling
- Documentation updates
- Total change size: <50 lines
- No architecture decisions required

**Medium Tasks** (score 30-80 → Sonnet or stage default)

- Multi-file refactors with clear scope (3-5 files)
- Feature additions within existing patterns
- Bug fixes spanning multiple components
- Total change size: 50-200 lines
- Some interdependency analysis needed

**Complex Tasks** (score > 80 → Opus)

- Architecture redesigns or major refactors
- Multi-component decisions requiring reasoning
- New patterns or abstractions
- Deep dependency analysis needed
- Total change size: >200 lines OR involves 6+ files
- Error context suggests systemic issues

### Routing Rules

**Stage defaults** (when score is in 30-80 range):

- Haiku stages: `intake`, `monitor`, `validate`
- Sonnet stages: `test`, `review`, `pr`, `merge`, `deploy`
- Opus stages: `plan`, `design`, `build`, `compound_quality`

**Complexity overrides** (applied after stage defaults):

- score < 30 → always haiku (even if stage default is opus/sonnet)
- score > 80 → always opus (even if stage default is haiku)

### Classification Score Formula

```
score = (file_count_signal * 0.3) +
        (line_change_signal * 0.3) +
        (error_complexity_signal * 0.2) +
        (dependency_depth_signal * 0.2)
```

Each signal is normalized to 0-100 before weighting. The final score is 0-100.

### Configuration

**Enable classifier** via `config/policy.json`:

```json
{
  "modelRouting": {
    "enabled": true,
    "weights": {
      "fileCount": 0.3,
      "lineChanges": 0.3,
      "errorComplexity": 0.2,
      "dependencyDepth": 0.2
    },
    "thresholds": { "low": 30, "high": 80 }
  }
}
```

**Stage-level routing config** via `~/.shipwright/optimization/model-routing.json`:

```json
{
  "default_routing": {
    "intake": "haiku",
    "plan": "opus",
    "build": "opus",
    "test": "sonnet"
  },
  "complexity_thresholds": { "low": 30, "high": 80 },
  "a_b_test": {
    "enabled": false,
    "percentage": 10,
    "variant": "cost-optimized"
  }
}
```

**Environment override**: `FORCE_MODEL=opus` overrides all routing decisions.

### A/B Testing

The `ab_test_should_use_classifier()` function enables gradual rollout:

- Reads `a_b_test.enabled` and `a_b_test.percentage` from routing config
- Uses `RANDOM % 100 < percentage` for assignment (stateless, per-invocation)
- Returns 0 (true) if this run should use the classifier, 1 (false) for control group
- Enable via: `shipwright model ab-test enable 15 cost-optimized`

**Success criteria**: Cost savings >25% with <2% success rate regression (p < 0.05)

### CLI Commands

```bash
# Route a stage with explicit complexity score
shipwright model route build 45          # → opus (build stage, medium complexity)
shipwright model route build 15          # → haiku (low complexity override)

# Escalate on failure
shipwright model escalate haiku          # → sonnet
shipwright model escalate sonnet         # → opus

# Configure A/B test (15% of pipelines use classifier)
shipwright model ab-test enable 15 cost-optimized

# Estimate pipeline cost
shipwright model estimate standard 50

# View usage report
shipwright model report
```

### Integration Points

- **Pipeline**: `sw-pipeline.sh` calls `classify_task()` once per pipeline with goal + real git diff line count. Score cached in `PIPELINE_COMPLEXITY_SCORE`.
- **Loop**: `sw-loop.sh` calls `classify_task_from_git()` to detect complexity from recent git changes.
- **Cost tracking**: `record_usage()` writes to `~/.shipwright/optimization/model-usage.jsonl`.
- **Monitoring**: `shipwright model report` shows per-model cost breakdown.

### Validation Checklist

- [x] Classifier returns numeric score 0-100
- [x] `route_model()` routes score < 30 → haiku, score > 80 → opus
- [x] Complexity overrides apply even when routing config specifies different model
- [x] `ab_test_should_use_classifier()` respects enabled flag and percentage
- [x] Pipeline uses real git diff line count (not hardcoded 0)
- [x] Score cached in `PIPELINE_COMPLEXITY_SCORE` to avoid re-computation
- [x] 96 tests passing (56 router + 40 classifier)
