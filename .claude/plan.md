# Implementation Plan: Cost-Aware Model Routing (Issue #65)

## Executive Summary

**Status**: ~80% complete. Core infrastructure exists: task classifier (40 tests), model router (51 tests), pipeline/loop integration. Remaining: complete A/B testing framework, fix routing edge cases, update documentation.

**Target Outcome**: Reduce pipeline costs 30-50% by intelligently routing simple tasks (intake, testing) to Haiku, complex tasks (planning, design) to Opus, with deterministic complexity scoring and escalation on failure.

---

## Brainstorming: Challenge Assumptions

### Requirements Clarity

**Minimum viable change**: The classifier, router, and pipeline wiring are solid. We need to:

1. Fix the `route_model()` function to prefer Haiku (not Sonnet) for low-complexity tasks
2. Ensure pipeline passes actual line_count to classifier (currently passes "0")
3. Complete A/B testing implementation with outcome recording
4. Document complexity heuristics and configuration

**Implicit requirements discovered**:

- The cost-aware template hardcodes Haiku on intake/test/audit/pr, but these should be configurable overrides
- Budget enforcement exists but may need refinement for concurrent pipelines
- A/B testing should be opt-in by default with clear rollout controls

### Design Alternatives

**Approach A: Incremental Bug Fixes + Complete A/B Testing** (CHOSEN)

- Pros: Builds on solid existing work, minimal blast radius (~200 LOC), all tests already in place
- Cons: Leaves some configuration optimizations for future work
- Blast radius: 4-5 files, low risk to existing functionality

**Approach B: Full Rewrite with Unified Config Schema**

- Pros: Cleaner configuration, unified routing rules across all stages
- Cons: Scope creep, risks breaking existing integrations, overkill for P3 issue
- Rejected: Can be a follow-up improvement

**Approach C: ML-based Classifier with Feature Engineering**

- Pros: Learns from historical data, improves over time
- Cons: Requires training data bootstrap, adds Python dependency to shell project
- Rejected: Issue explicitly asks for heuristic approach

**Decision Rationale**: Approach A minimizes risk while delivering full functionality. The existing classifier is well-designed; we just need to polish the edges and complete the A/B framework.

### Risk Assessment

1. **Changing low-complexity routing from sonnet→haiku**
   - Risk: Could break downstream code that depends on sonnet being the minimum tier
   - Mitigation: Escalation mechanism (haiku→sonnet→opus on failure) handles fallback. Cost-aware template already assigns haiku to multiple stages. Tests validate the entire flow.
   - Impact: LOW

2. **Pipeline line_count detection adding latency**
   - Risk: Running `git diff --stat` on every pipeline start adds ~50ms
   - Mitigation: Already cached via `PIPELINE_COMPLEXITY_SCORE` env var. Runs once per pipeline, not per stage.
   - Impact: NEGLIGIBLE

3. **A/B test randomness in deterministic pipelines**
   - Risk: Non-deterministic assignment could make pipeline behavior unpredictable
   - Mitigation: A/B testing is opt-in (disabled by default). When enabled, it's stateless per-invocation (respects seed if needed for reproducibility). Results are logged for post-analysis.
   - Impact: LOW (controlled)

4. **Budget enforcement blocking critical stages**
   - Risk: Nearly-exhausted budget prevents review stage from using Opus
   - Mitigation: `FORCE_MODEL=opus` env override with clear warning. Budget checks emit events for operator awareness.
   - Impact: MEDIUM (mitigated)

5. **Concurrent pipeline file writes to cost log**
   - Risk: Multiple worktree pipelines writing to `model-usage.jsonl` simultaneously could corrupt data
   - Mitigation: Use atomic write pattern (tmp + mv) per project conventions. JSONL format is append-safe.
   - Impact: LOW (well-understood pattern)

### Dependency Analysis

**What depends on this change**:

- `sw-pipeline.sh` — calls classifier and routes stages
- `sw-loop.sh` — calls classifier for build iterations
- `sw-cost.sh` — reads model usage logs for budget enforcement
- Cost tracking infrastructure — consumes model assignments
- A/B testing dashboards — analyze cost/success metrics

**What this depends on**:

- `sw-task-classifier.sh` — already exists, well-tested (40 tests)
- `config/policy.json` — already has `modelRouting` section
- `jq` — for config parsing (already required by project)
- Existing escalation mechanism — already implemented

**Circular dependencies**: None identified. Data flows in one direction: task → classifier → router → cost tracking.

### Simplicity Check

- Can this be solved with fewer files? Already at minimum (6 scripts + 1 config update + 2 docs)
- Is there existing infrastructure we can reuse? Yes — classifier, router, cost tracking, escalation all exist
- Would a simpler approach work for 90% of cases? The heuristic classifier handles the core value prop; ML refinement is future-work

---

## Architecture Decision Record

### Component Decomposition

```
┌─────────────────────────────────────────────────────────────────┐
│                   Pipeline Orchestrator                         │
│                     (sw-pipeline.sh)                            │
│  ┌─────────┐  ┌────────────┐  ┌──────────────┐                 │
│  │  Stage  │→ │ Classifier │→ │ Cost/Budget  │                 │
│  │  Exec   │  │ (optional) │  │  Enforcement │                 │
│  └─────────┘  └────────────┘  └──────────────┘                 │
└─────────────────────────────────────────────────────────────────┘
         ↓                ↓                    ↓
    ┌─────────────────────────────────────────────────┐
    │  Model Router (sw-model-router.sh)              │
    │  route_model() → model_id (haiku|sonnet|opus)  │
    │  escalate_model() → next_tier on failure        │
    └──────────┬──────────────────────────────────────┘
               ↓
    ┌─────────────────────────────────────────────────┐
    │  Cost Tracking (sw-cost.sh)                     │
    │  record_model_usage()                           │
    │  validate_budget()                              │
    │  A/B outcome recording                          │
    └─────────────────────────────────────────────────┘
               ↓
    ┌─────────────────────────────────────────────────┐
    │  Configuration Layer                            │
    │  config/policy.json (repo)                      │
    │  ~/.shipwright/optimization/model-routing.json  │
    │  FORCE_MODEL env (override)                     │
    └─────────────────────────────────────────────────┘
```

### Interface Contracts

**Task Classifier** (`sw-task-classifier.sh`)

```bash
classify_task(<issue_body> <file_list> <error_context> [line_count])
  → Returns: 0-100 complexity score
  → Error: Returns 50 (medium) on invalid input

classify_task_from_git()
  → Returns: 0-100 complexity score from recent git diff
  → Error: Returns 50 on git failure
```

**Model Router** (`sw-model-router.sh`)

```bash
route_model(<stage> <complexity_score>)
  → Returns: haiku|sonnet|opus
  → Error: Returns sonnet (fallback) on config failure

escalate_model(<current_model>)
  → Returns: next tier (haiku→sonnet→opus)
  → Error: Returns opus (max tier) on invalid input

route_model_auto(<stage> <issue_body> [file_list] [error_context] [line_count])
  → Combines classifier + router
  → Returns: model_id with caching
```

**Cost Integration** (`sw-cost.sh`)

```bash
record_model_usage(<model> <stage> <input_tokens> <output_tokens>)
  → Appends to model-usage.jsonl
  → Atomic write (tmp+mv)

validate_budget(<stage> <model>)
  → Returns: 0 (ok) if within budget, 1 (exceeded) if over
  → Emits: budget_exceeded event if triggered

record_ab_test_outcome(<test_variant> <success> <cost_delta>)
  → Appends to ab-results.jsonl
```

### Data Flow

```
Issue/Goal Input
    ↓
┌──────────────────────────┐
│ classify_task()          │
│  • Count files changed   │
│  • Count line changes    │
│  • Analyze error context │
│  • Check keywords        │
└──────────┬───────────────┘
           │ score: 0-100
           ↓
┌──────────────────────────────────┐
│ route_model(stage, score)        │
│  • Apply complexity thresholds   │
│  • Check stage defaults          │
│  • Honor FORCE_MODEL override    │
└──────────┬───────────────────────┘
           │ model: haiku|sonnet|opus
           ↓
┌──────────────────────────────────┐
│ Pipeline Stage Execution         │
│  • Set MODEL env var             │
│  • Call Claude with --model flag │
│  • Capture token counts          │
└──────────┬───────────────────────┘
           │ tokens, success/failure
           ↓
┌──────────────────────────────────┐
│ Cost Tracking                    │
│  • Record usage to JSONL         │
│  • Check budget                  │
│  • Escalate on failure           │
│  • Log A/B outcome               │
└──────────────────────────────────┘
```

### Error Boundaries

| Error                        | Handling                                                      |
| ---------------------------- | ------------------------------------------------------------- |
| Classifier input empty       | Returns score 50 (medium), routes to Sonnet                   |
| Git diff unavailable         | Returns score 50, falls back to stage defaults                |
| Config file missing          | Auto-creates default on first run                             |
| jq parsing failure           | Falls back to built-in thresholds (no external config needed) |
| Budget exceeded              | Emits event, blocks next stage unless `FORCE_MODEL` set       |
| Stage fails on cheap model   | `escalate_model()` retries with next tier (haiku→sonnet→opus) |
| A/B randomness not available | Defaults to treatment group (use classifier)                  |
| Concurrent file writes       | Atomic pattern (tmp + mv) prevents corruption                 |

---

## Task Decomposition

### Phase 1: Fix Core Routing Logic (3 tasks)

**Task 1: Fix route_model() low-complexity threshold**

- Current: Returns `sonnet` for complexity < 30 (line 184 fallback)
- Fix: Return `haiku` for complexity < 30
- Files: `scripts/sw-model-router.sh` (line 177-186)
- Dependencies: None
- Test coverage: Existing tests validate (sw-model-router-test.sh)

**Task 2: Pipeline line_count detection**

- Current: `sw-pipeline.sh:1703` passes "0" as line_count to classifier
- Fix: Use `git diff --stat` to get actual change count
- Files: `scripts/sw-pipeline.sh` (around line 1700-1710)
- Dependencies: Task 1 (routing must work first)
- Test coverage: Add test for classifier with real line count

**Task 3: Cost-aware template model assignments**

- Current: Hardcodes `model: "claude-haiku-4-5-20251001"` on several stages
- Fix: Document as intentional overrides, consider making optional
- Files: `templates/pipelines/cost-aware.json`
- Dependencies: None
- Test coverage: Verify template composition works with routing

### Phase 2: Complete A/B Testing (2 tasks)

**Task 4: A/B test outcome recording**

- Current: `ab_test_should_use_classifier()` exists but outcomes not logged
- Fix: Implement `record_ab_test_outcome()` in `sw-cost.sh`
- Files: `scripts/sw-cost.sh` (new function)
- Dependencies: Cost tracking infrastructure exists
- Test coverage: Unit tests for outcome calculation

**Task 5: A/B test reporting CLI**

- Current: No `shipwright model ab-test report` command
- Fix: Implement CLI subcommand to analyze A/B results
- Files: `scripts/sw-model-router.sh` (add `ab-test` subcommand)
- Dependencies: Task 4 (outcome logging)
- Test coverage: Snapshot tests for report output

### Phase 3: Documentation (2 tasks)

**Task 6: Update model routing user guide**

- Current: `docs/model-routing.md` exists but may be outdated
- Fix: Document complexity scoring, threshold overrides, CLI commands
- Files: `docs/model-routing.md` (update)
- Dependencies: All code tasks complete
- Test coverage: Verify examples are accurate

**Task 7: Update A/B testing operations guide**

- Current: No guide for running A/B tests
- Fix: Document how to enable, monitor, interpret results
- Files: `docs/cost-aware-routing.md` (new or update)
- Dependencies: All code tasks complete
- Test coverage: Verify examples match implementation

### Phase 4: Validation & Integration (2 tasks)

**Task 8: Integration test: classifier→router→cost→escalation**

- Current: Unit tests exist but no end-to-end test
- Fix: Write integration test simulating full pipeline execution
- Files: `scripts/sw-model-router-test.sh` (add integration section)
- Dependencies: All Phase 1-2 tasks
- Test coverage: Full path test with failure+escalation

**Task 9: A/B test validation in pipeline**

- Current: A/B logic exists but untested in pipeline context
- Fix: Add test pipeline that exercises A/B split and records outcomes
- Files: `scripts/sw-pipeline-test.sh` (add A/B section)
- Dependencies: Task 4-5 complete
- Test coverage: Verify A/B assignment is stateless, outcomes recorded

---

## Implementation Steps

### Step 1: Fix route_model() low-complexity logic (File: sw-model-router.sh)

**Location**: Lines 177-186
**Current code**:

```bash
elif [[ "$stage" =~ $HAIKU_STAGES ]]; then
    model="haiku"
elif [[ "$stage" =~ $SONNET_STAGES ]]; then
    model="sonnet"
elif [[ "$stage" =~ $OPUS_STAGES ]]; then
    model="opus"
else
    model="sonnet"   # ← This should be "haiku" for unknown stages
fi
```

**Fix**: Change line 184 from `model="sonnet"` to `model="haiku"`

**Rationale**: For unknown stages with no complexity score yet, defaulting to Haiku (cheapest) is safer. Escalation mechanism handles failures.

---

### Step 2: Pipeline line_count detection (File: sw-pipeline.sh)

**Location**: Around line 1703 where classifier is called
**Current**: `classify_task "$issue_body" "$file_list" "$error_context" "0"`
**Fix**: Calculate actual line count before calling classifier

```bash
# Get actual line count from git diff
local line_count=0
if git diff --quiet 2>/dev/null; then
    line_count=$(git diff --stat | tail -1 | awk '{print $NF}' | tr -d '+')
    [[ ! "$line_count" =~ ^[0-9]+$ ]] && line_count=0
fi
classify_task "$issue_body" "$file_list" "$error_context" "$line_count"
```

---

### Step 3: A/B outcome recording (File: sw-cost.sh)

**New function**:

```bash
record_ab_test_outcome() {
    local variant="$1" success="$2" cost_delta="$3"
    local ab_results="${HOME}/.shipwright/ab-results.jsonl"

    mkdir -p "$(dirname "$ab_results")"

    local outcome
    outcome=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg variant "$variant" \
        --arg success "$success" \
        --arg cost_delta "$cost_delta" \
        '{ts: $ts, variant: $variant, success: $success, cost_delta: $cost_delta}')

    # Atomic write
    local tmp_file="${ab_results}.tmp.$$"
    echo "$outcome" >> "$tmp_file"
    mv "$tmp_file" "$ab_results" 2>/dev/null || true
}
```

---

### Step 4: A/B test report CLI (File: sw-model-router.sh)

**New subcommand**: `sw model ab-test report`

```bash
ab_test_report() {
    local ab_results="${HOME}/.shipwright/ab-results.jsonl"

    if [[ ! -f "$ab_results" ]]; then
        warn "No A/B test results found"
        return 0
    fi

    info "A/B Test Results"

    # Calculate success rates and cost difference
    # (Use jq to aggregate results)
    jq -s 'group_by(.variant) | map({
        variant: .[0].variant,
        count: length,
        success_rate: ((map(select(.success=="true")) | length) / length * 100),
        avg_cost_delta: (map(.cost_delta | tonumber) | add / length)
    })' "$ab_results" 2>/dev/null || warn "Failed to parse results"
}
```

---

### Step 5: Documentation updates

**File: docs/model-routing.md**

```markdown
# Cost-Aware Model Routing

## Quick Start

Enable model routing in `config/policy.json`:
\`\`\`json
{
"modelRouting": {
"enabled": true,
"classify_complexity": true
}
}
\`\`\`

## Complexity Scoring

The classifier scores tasks 0-100 based on:

- **File count** (30%): More files = more complex
- **Line changes** (30%): Larger diffs = more complex
- **Error complexity** (20%): Error context signals difficulty
- **Keywords** (20%): Refactor, architecture keywords → complex

## Routing Rules

| Score  | Model  | Cost (per 1M tokens) |
| ------ | ------ | -------------------- |
| 0-29   | Haiku  | $0.80 / $4.00        |
| 30-79  | Sonnet | $3.00 / $15.00       |
| 80-100 | Opus   | $15.00 / $75.00      |

## Stage Defaults

Certain stages have hardcoded minimums:

- **intake, monitor**: Always Haiku
- **test, review**: Sonnet/Opus
- **plan, design, build**: Complexity-routed

## Escalation

When a stage fails on a cheap model, it escalates:

- Haiku fails → retry with Sonnet
- Sonnet fails → retry with Opus
- Opus fails → propagate error

This ensures quality while maximizing cost savings.

## Configuration Overrides

### Per-stage override

Edit `~/.shipwright/optimization/model-routing.json`:
\`\`\`json
{
"default_routing": {
"build": "sonnet"
}
}
\`\`\`

### Force all stages

\`\`\`bash
export FORCE_MODEL=opus
shipwright pipeline start --issue 42
\`\`\`

## A/B Testing

### Enable A/B test

\`\`\`bash
shipwright model ab-test enable 15 cost-optimized
\`\`\`

This puts 15% of pipelines in treatment group (use classifier), 85% in control (Opus everywhere).

### View results

\`\`\`bash
shipwright model report
\`\`\`
```

---

## Testing Approach

### Unit Tests (existing, passing)

- Task classifier: 40 tests (file count, line changes, error signals, keywords)
- Model router: 51 tests (routing, escalation, config parsing, A/B draw)

### Integration Tests (new)

1. **Classifier → Router → Cost**: Run classifier, get score, route model, verify token cost recorded
2. **Failure → Escalation**: Route to Haiku, inject failure, verify escalates to Sonnet
3. **Budget enforcement**: Set low budget, verify blocks stage, `FORCE_MODEL` override works
4. **A/B test split**: Enable A/B at 50%, run 100 pipelines, verify ~50 in treatment, outcomes logged

### Regression Tests

- All existing pipeline tests continue to pass
- All existing cost tracking tests continue to pass
- Config parsing fallbacks still work when jq unavailable

### Coverage Targets

- Classifier: 100% (40 tests)
- Router: 100% (51 tests)
- Cost integration: 95%+ (new outcome recording)
- A/B report: 90%+ (new CLI)

---

## Definition of Done

### Code Complete

- [ ] Task 1: `route_model()` returns `haiku` for complexity < 30
- [ ] Task 2: Pipeline passes actual `git diff --stat` line count to classifier
- [ ] Task 3: Cost-aware template documented, tested
- [ ] Task 4: `record_ab_test_outcome()` records to `ab-results.jsonl`
- [ ] Task 5: `sw model ab-test report` command implemented
- [ ] Task 6: User guide updated with examples
- [ ] Task 7: Operations guide updated
- [ ] Task 8: Integration test covers full path
- [ ] Task 9: A/B test validation in pipeline test suite

### Tests Passing

- [ ] `npm test` passes all 91+ existing tests
- [ ] New integration tests pass (classifier→router→cost)
- [ ] New A/B tests pass (split, outcome recording)
- [ ] Regression: existing pipelines unaffected

### Documentation

- [ ] `docs/model-routing.md` updated with complexity examples
- [ ] `docs/cost-aware-routing.md` (or integrated) with A/B guide
- [ ] CLI help text accurate (`sw model help`)
- [ ] Code comments explain threshold choices

### Acceptance Criteria (from Issue #65)

- ✅ Task complexity classifier (simple/medium/complex) based on file count, change size, error context
- ✅ Model routing configuration in `config/policy.json` (overridable per stage)
- ✅ Integration with cost tracking (`~/.shipwright/costs.json`)
- ✅ Pipeline stages annotated with recommended model tier
- ✅ A/B testing mode to validate cost savings vs success rate impact
- ✅ Budget enforcement respects model routing decisions
- ✅ Documentation on complexity heuristics and override options

---

## Alternatives Considered

### Alternative 1: Full Rewrite with Unified Config Schema

**Trade-offs**:

- ✅ Cleaner, more consistent configuration
- ✅ Easier to extend for future model tiers
- ❌ High refactoring risk
- ❌ Breaks backward compatibility
- ❌ Scope creep for P3 issue

### Alternative 2: ML-based Classifier with Training Pipeline

**Trade-offs**:

- ✅ Learns from historical data
- ✅ Improves accuracy over time
- ❌ Requires Python/ML dependencies (against shell-native Shipwright)
- ❌ Requires training data bootstrap (100+ examples)
- ❌ Black-box decisions harder to debug

### Alternative 3: Static Per-Stage Model Assignment Only

**Trade-offs**:

- ✅ Simplest implementation
- ✅ Zero runtime overhead
- ❌ Cannot adapt within a stage
- ❌ Misses core value prop (route simple builds to Haiku)

**Chosen**: Incremental fixes to existing heuristic classifier. Proven design, low risk, delivers full functionality.

---

## Risk Mitigation Summary

| Risk                        | Mitigation                            | Impact     |
| --------------------------- | ------------------------------------- | ---------- |
| Haiku underperforms         | Escalation path (haiku→sonnet→opus)   | LOW        |
| Line count latency          | Cached in `PIPELINE_COMPLEXITY_SCORE` | NEGLIGIBLE |
| A/B non-determinism         | Opt-in, stateless per-invocation      | LOW        |
| Budget blocks critical work | `FORCE_MODEL` override with warnings  | MEDIUM     |
| Concurrent file corruption  | Atomic write pattern (tmp+mv)         | LOW        |

---

## Success Metrics

1. **Cost Reduction**: 30-50% pipeline cost decrease (measured via A/B test)
2. **Success Rate**: No degradation (target: <2% regression, p < 0.05)
3. **Test Coverage**: 90%+ of new code covered by tests
4. **Documentation**: All configuration options documented with examples
5. **Adoption**: Cost-aware template used as default for budget-conscious pipelines

---

## Files to Modify

1. **scripts/sw-model-router.sh** — Fix low-complexity routing, add A/B report CLI
2. **scripts/sw-pipeline.sh** — Pass actual line_count to classifier
3. **scripts/sw-cost.sh** — Add `record_ab_test_outcome()` function
4. **docs/model-routing.md** — Update with complexity examples, configuration
5. **templates/pipelines/cost-aware.json** — Document hardcoded model choices
6. **scripts/sw-model-router-test.sh** — Add integration tests
7. **scripts/sw-pipeline-test.sh** — Add A/B validation tests

---

## Next Steps

1. **Execute Phase 1** (Core routing fixes) — 1-2 hours, low risk
2. **Execute Phase 2** (A/B testing) — 2-3 hours, medium risk
3. **Execute Phase 3** (Documentation) — 1 hour
4. **Execute Phase 4** (Validation) — 1-2 hours, all tests pass
5. **Create PR**, request review, merge to main

**Total Estimated Effort**: 6-9 hours (breakdown: 3 code, 2 tests, 1 docs, 0-1 unforeseen)

---

## Questions Answered

**Q: What if Haiku fails on a simple task?**
A: The escalation mechanism retries with Sonnet. The pipeline succeeds, just at higher cost for that stage.

**Q: How do we know the classifier's score is accurate?**
A: We validate via A/B test — 10% of pipelines run as control (Opus everywhere), 90% use classifier. If control and treatment have same success rate but treatment costs 30-50% less, we've validated the approach.

**Q: Can we override routing per-stage?**
A: Yes, via `~/.shipwright/optimization/model-routing.json` (user config) or `FORCE_MODEL` env (immediate override).

**Q: What happens if budget is exhausted mid-pipeline?**
A: The `validate_budget()` function checks before each stage. If exceeded, it emits `budget_exceeded` event and blocks next stage unless `FORCE_MODEL` is set.

**Q: Are the classifier weights tuned?**
A: The current weights (30% file count, 30% line changes, 20% error complexity, 20% keywords) are reasonable heuristics. A/B test will show if they're optimal. Future work can refine based on outcome data.

---

## Appendices

### Appendix A: Current Implementation Status

- [x] Task classifier (sw-task-classifier.sh) — 40 tests passing
- [x] Model router (sw-model-router.sh) — 51 tests passing
- [x] Policy config (config/policy.json) — modelRouting section added
- [x] Pipeline integration (sw-pipeline.sh) — classifier called at stage boundaries
- [x] Loop integration (sw-loop.sh) — classify_task_from_git() implemented
- [x] Cost-aware template (templates/pipelines/cost-aware.json) — exists
- [x] Cost tracking infrastructure (sw-cost.sh) — exists, working
- [ ] A/B test outcome recording — function exists but not integrated
- [ ] A/B test report CLI — needs implementation
- [ ] Documentation — needs update

### Appendix B: Scoring Formula

```
complexity_score =
    (file_count_signal * 0.3) +
    (line_change_signal * 0.3) +
    (error_complexity_signal * 0.2) +
    (keywords_signal * 0.2)
```

Each signal is normalized to 0-100 before weighting. Final score is 0-100.

**File count signal**:

- 1-3 files: 0-25
- 4-10 files: 25-50
- 11-20 files: 50-75
- 21+ files: 75-100

**Line changes signal**:

- 1-10 lines: 0-25
- 11-50 lines: 25-50
- 51-200 lines: 50-75
- 201+ lines: 75-100

**Error complexity signal**:

- No errors: 0
- Simple errors (syntax, typos): 25
- Logic errors: 50
- Architecture/design errors: 75
- Multiple error types: 100

**Keywords signal**:

- No special keywords: 0
- One of: refactor, migrate, redesign: 50
- Multiple or: architecture, security, performance: 75-100
