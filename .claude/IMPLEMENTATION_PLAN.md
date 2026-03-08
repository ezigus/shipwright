# Design: Cost-aware model routing: Haiku for simple tasks, Opus for complex

## Context

Shipwright pipelines currently use a single Claude model (typically Opus) for all stages regardless of task complexity. This is wasteful: simple tasks like intake triage, PR creation, and test running don't need Opus-level reasoning. Issue #65 targets 30-50% cost reduction by routing tasks to the cheapest capable model.

**Codebase constraints:**

- Shell-based orchestration (Bash 3.2 compatible, `set -euo pipefail`)
- Pipeline stages execute sequentially via `sw-pipeline.sh` → `sw-loop.sh` → `loop-iteration.sh`
- Model selection happens in `build_claude_flags()` which reads `$MODEL` env var
- Configuration layered: `config/policy.json` (repo) → `~/.shipwright/optimization/model-routing.json` (user) → `FORCE_MODEL` env (override)
- 96 existing tests (56 router + 40 classifier) already pass

**What already exists (implemented):**

- `scripts/sw-task-classifier.sh` — Weighted heuristic scorer (file count 30%, line changes 30%, error complexity 20%, keywords 20%)
- `scripts/sw-model-router.sh` — Score-to-model mapping with escalation and A/B test gating
- `config/policy.json` `modelRouting` section — Thresholds, weights, stage overrides
- `templates/pipelines/cost-aware.json` — Per-stage model assignments

**What remains (this design covers):**

- Cost tracking integration and budget enforcement
- A/B testing validation framework
- CLI command group (`sw model`)
- End-to-end integration tests
- Documentation

## Decision

### Approach: Embedded heuristic classifier with tiered routing

Use a deterministic, weighted-score classifier embedded directly in the pipeline shell scripts. No external services, no ML models. The classifier runs at pipeline start and per-stage, producing a 0-100 complexity score that maps to a model tier.

### Routing Rules

| Complexity Score | Model             | Cost (input/output per 1M tokens) |
| ---------------- | ----------------- | --------------------------------- |
| 0-29 (low)       | claude-haiku-4-5  | $0.80 / $4.00                     |
| 30-79 (medium)   | claude-sonnet-4-6 | $3.00 / $15.00                    |
| 80-100 (high)    | claude-opus-4-6   | $15.00 / $75.00                   |

### Stage-Level Overrides

Certain stages have hardcoded model minimums regardless of complexity score (defined in `cost-aware.json` template):

- **intake, test, audit, pr**: Always Haiku (these are mechanical/template-driven)
- **review**: Always Opus (quality-critical gate)
- **plan, design, build, compound_quality**: Complexity-routed (use classifier score)

### Escalation Path

When a stage fails, `escalate_model()` bumps to the next tier (haiku→sonnet→opus) and retries. This prevents cheap-model failures from blocking the pipeline.

### Budget Enforcement

- `validate_budget(stage, model)` checks accumulated cost against `max_cost_per_pipeline` before each stage
- On budget exceeded: emit warning event, block stage unless `FORCE_MODEL` is set
- Cost data persisted to `~/.shipwright/optimization/model-usage.jsonl` (append-only JSONL)

### A/B Testing

- 10% of pipelines (configurable) run as control group with Opus-everywhere
- Outcomes recorded to `~/.shipwright/ab-results.jsonl`
- `ab_test_report()` calculates cost delta and success rate delta with p-value

### Data Flow

```
Issue/Goal
    │
    ▼
┌─────────────────────┐
│  classify_task()     │  ← issue_body, file_list, error_context, line_count
│  sw-task-classifier  │
└────────┬────────────┘
         │ complexity_score (0-100)
         ▼
┌─────────────────────┐     ┌──────────────────────┐
│  route_model()       │────▶│  Configuration Layer  │
│  sw-model-router     │     │  policy.json          │
└────────┬────────────┘     │  model-routing.json   │
         │ model_id          │  FORCE_MODEL env      │
         ▼                   └──────────────────────┘
┌─────────────────────┐
│  Pipeline Stage      │
│  (build_claude_flags)│──▶ claude --model $MODEL
└────────┬────────────┘
         │ token counts (input, output)
         ▼
┌─────────────────────┐
│  record_model_usage()│──▶ model-usage.jsonl
│  validate_budget()   │──▶ budget check → abort or continue
│  sw-cost-integration │
└─────────────────────┘
```

### Error Handling

| Failure Mode                        | Behavior                                                                                      |
| ----------------------------------- | --------------------------------------------------------------------------------------------- |
| Classifier receives empty input     | Returns score 50 (medium), routes to Sonnet                                                   |
| `jq` unavailable for config parsing | Falls back to built-in defaults (Sonnet)                                                      |
| Budget exceeded mid-pipeline        | Emits `budget_exceeded` event, blocks next stage, operator can `FORCE_MODEL=opus` to override |
| A/B random draw fails               | Defaults to treatment group (use classifier)                                                  |
| Model routing config file missing   | Creates default config on first run                                                           |
| Stage fails on cheap model          | `escalate_model()` retries with next tier                                                     |

## Alternatives Considered

1. **Separate routing microservice** — Pros: Clean separation, language-agnostic, independently deployable / Cons: Process overhead, requires IPC, adds infrastructure complexity for a CLI tool, violates Shipwright's shell-native architecture
2. **ML-based classifier (embeddings + logistic regression)** — Pros: Learns from historical data, improves over time / Cons: Requires training data bootstrap (~100+ labeled examples), black-box decisions harder to debug, adds Python/ML dependency to a shell project, issue explicitly asks for heuristic approach
3. **Static per-stage model assignment only (no classifier)** — Pros: Simplest implementation, zero runtime overhead / Cons: Cannot adapt to task complexity within a stage, misses the core value proposition of routing simple builds to Haiku

## Implementation Plan

### Files to create

- `scripts/sw-cost-integration.sh` — Budget enforcement (`validate_budget`, `record_model_usage`) and A/B outcome recording
- `scripts/sw-cost-test.sh` — Test suite for cost integration (budget, A/B recording)
- `tests/integration/model-routing.test.sh` — E2E integration tests (classifier→router→cost)
- `docs/model-routing.md` — User guide (complexity scoring, configuration)
- `docs/cost-aware-routing.md` — Operations guide (budgeting, A/B testing)

### Files to modify

- `scripts/sw-pipeline.sh` — Wire in budget checks at stage boundaries, A/B outcome recording at pipeline completion
- `scripts/sw-model-router.sh` — Add `sw model` CLI dispatcher, `route`/`escalate`/`config`/`estimate`/`ab-test` subcommands
- `scripts/lib/loop-iteration.sh` — Call `record_model_usage()` after each Claude invocation
- `scripts/lib/pipeline-stages-build.sh` — Pass complexity score to loop harness

### Dependencies

- None new. Uses existing `jq` (already required), `bc` (for A/B significance calc, already available)

### Risk areas

- **Classifier underestimation**: A complex refactor scored as simple gets routed to Haiku, which may fail or produce low-quality output. Mitigation: escalation on failure + A/B validation to catch systematic underscoring.
- **Budget enforcement blocking critical work**: A nearly-exhausted budget prevents the review stage from using Opus. Mitigation: `FORCE_MODEL` env override, clear error messages with budget status.
- **Atomic file writes for cost logging**: Under `pipefail`, concurrent pipelines (worktrees) writing to the same `model-usage.jsonl` could corrupt data. Mitigation: use tmp file + `mv` pattern per project conventions.
- **Bash 3.2 compatibility**: New cost integration code must avoid associative arrays, `readarray`, `${var,,}`. Existing test harness validates this.

## Component Diagram

```
┌──────────────────────────────────────────────────────────┐
│              Pipeline Orchestrator                        │
│              (sw-pipeline.sh)                             │
│                                                          │
│  For each stage:                                         │
│    1. classify_task() → score                            │
│    2. validate_budget() → ok/abort                       │
│    3. route_model(stage, score) → model                  │
│    4. execute stage with $MODEL                          │
│    5. record_model_usage(stage, model, tokens)           │
│  On completion:                                          │
│    6. ab_test_record_outcome(run_id, variant, result)    │
└────────────┬──────────┬──────────┬───────────────────────┘
             │          │          │
     ┌───────▼──┐  ┌────▼─────┐  ┌▼──────────────┐
     │Classifier│  │  Router  │  │Cost Tracker    │
     │          │  │          │  │                │
     │score()   │  │route()   │  │record_usage()  │
     │          │  │escalate()│  │validate_budget()│
     │          │  │ab_gate() │  │ab_record()     │
     └───────┬──┘  └────┬─────┘  └┬──────────────┘
             │          │          │
             └──────────┼──────────┘
                        │
              ┌─────────▼─────────┐
              │  Configuration    │
              │                   │
              │ policy.json       │  repo-level defaults
              │ model-routing.json│  user-level overrides
              │ cost-aware.json   │  template stage models
              │ FORCE_MODEL env   │  runtime override
              └───────────────────┘
```

**Dependencies point inward**: Pipeline → {Classifier, Router, Cost Tracker} → Configuration. No component depends on the Pipeline orchestrator. Classifier and Router are independent of each other (Pipeline composes them).

## Interface Contracts

### Task Classifier (`scripts/sw-task-classifier.sh`)

```typescript
// classify_task(issue_body: string, file_list: string, error_context: string, line_count: string): number
// Returns: 0-100 complexity score
// Error contract: returns 50 on any invalid/empty input (safe middle-ground)
// Side effects: emits "classifier" event to events.jsonl
// Precondition: none (handles all degenerate inputs)
// Postcondition: output is integer in [0, 100]

// Internal scoring functions (not public API, but testable):
// _score_file_count(file_list: string): number      // 0-100
// _score_change_size(line_count: string): number     // 0-100
// _score_error_complexity(error_ctx: string): number // 0-100
// _score_keywords(issue_body: string): number        // 0-100
```

### Model Router (`scripts/sw-model-router.sh`)

```typescript
// route_model(stage: string, complexity: number): "haiku" | "sonnet" | "opus"
// Precondition: stage is valid pipeline stage name, complexity in [0, 100]
// Error contract: returns "sonnet" if config unreadable or inputs invalid
// Priority: FORCE_MODEL env > stage_override in config > complexity-based routing

// escalate_model(current: "haiku" | "sonnet" | "opus"): "haiku" | "sonnet" | "opus"
// Returns next tier up; opus→opus (ceiling)

// route_model_auto(): "haiku" | "sonnet" | "opus"
// Calls classify_task() internally, then route_model()

// ab_test_should_use_classifier(): 0 | 1
// 0 = use classifier (treatment), 1 = use Opus everywhere (control)
```

### Cost Tracker (`scripts/sw-cost-integration.sh`) — NEW

```typescript
// record_model_usage(stage: string, model: string, input_tokens: number, output_tokens: number): void
// Appends JSON line to ~/.shipwright/optimization/model-usage.jsonl
// Error contract: silently skips on write failure (non-blocking)
// Uses atomic write (tmp + mv) for crash safety

// validate_budget(stage: string, model: string): 0 | 1
// 0 = within budget, 1 = budget exceeded
// Reads max_cost_per_pipeline from config, sums model-usage.jsonl for current run
// Error contract: returns 0 (allow) if config missing or unreadable

// ab_test_record_outcome(run_id: string, variant: "treatment" | "control", success: boolean, cost: number, duration: number): void
// Appends to ~/.shipwright/ab-results.jsonl

// ab_test_report(): void
// Prints aggregated cost savings, success rates, and p-value to stdout
```

### CLI (`sw model` subcommands) — NEW

```typescript
// sw model route <stage> [--complexity <score>]  → prints selected model
// sw model escalate <current_model>              → prints next tier
// sw model config [--set key=value]              → show/modify routing config
// sw model estimate [--template <name>]          → per-stage cost estimate
// sw model ab-test [--report | --configure <pct>] → A/B test management
```

## Error Boundaries

| Component    | Errors It Handles                                             | Propagation                                             |
| ------------ | ------------------------------------------------------------- | ------------------------------------------------------- |
| Classifier   | Empty/malformed input → returns 50                            | Never fails pipeline; always produces a score           |
| Router       | Missing config → falls back to Sonnet; invalid stage → Sonnet | Never fails pipeline; always produces a model           |
| Cost Tracker | Write failures → silent skip; missing config → allow all      | Budget exceeded → returns exit code 1, pipeline decides |
| Pipeline     | Budget exceeded → emits event, blocks stage                   | Operator override via `FORCE_MODEL`; `--force` flag     |
| CLI          | Invalid subcommand → usage help; missing args → error message | Exit code 1 with descriptive message                    |

## Validation Criteria

- [ ] `classify_task()` returns integer 0-100 for any combination of inputs (including empty strings)
- [ ] `route_model("build", 15)` returns "haiku"; `route_model("build", 85)` returns "opus"
- [ ] `route_model("review", 10)` returns "opus" (stage override takes precedence over low score)
- [ ] `escalate_model("haiku")` returns "sonnet"; `escalate_model("opus")` returns "opus"
- [ ] `FORCE_MODEL=opus` overrides all routing decisions regardless of score or stage
- [ ] `validate_budget()` returns 1 when accumulated cost exceeds configured limit
- [ ] `record_model_usage()` produces valid JSONL readable by `jq`
- [ ] A/B control group uses Opus everywhere; treatment group uses classifier routing
- [ ] `ab_test_report()` calculates cost delta percentage and success rate delta
- [ ] `sw model route build --complexity 20` prints "haiku" to stdout
- [ ] All new code passes `shellcheck` with no warnings
- [ ] Full test suite passes (`npm test`) including 96 existing + new integration tests
- [ ] No Bash 3.2 incompatibilities (no associative arrays, readarray, or case-modification expansions)
