Audited the plan against `scripts/sw-loop.sh:91,129-130`, `config/defaults.json` (`build_test_retries: 3`, `max_iterations: 20`), and `scripts/sw-triage.sh:619-650`. Numbers in the plan match the codebase. Writing the ADR now.

# Design: Reduce build-loop iteration ceiling — current 45/cycle × 3 cycles = 135 invocations is excessive

## Context

The build loop in `scripts/sw-loop.sh` is governed by three multiplicative knobs that compound to a worst-case 140 Claude Code invocations per issue:

| Knob | Location | Current | Effect |
|---|---|---|---|
| `MAX_ITERATIONS` | `scripts/sw-loop.sh:91` | 20 | Per-call base cap |
| `EXTENSION_SIZE` × `MAX_EXTENSIONS` | `scripts/sw-loop.sh:129-130` | 5 × 3 | Adds up to 15 more iterations when progress is non-zero |
| `pipeline.build_test_retries` | `config/defaults.json:28` (read by `scripts/sw-pipeline.sh:822`) | 3 | Self-heal: 1 initial + 3 retry cycles = 4 cycles |

Worst case = `(20 + 3·5) · (1+3) = 140`. Evidence from postmortem run 26006244558 / issue #460: a 4-hour spinning loop ran until GHA's 300-min wall-clock killed it — the internal ceiling never fired because extensions compounded silently.

The cap is also re-derived independently in three other paths that serialize a pipeline spec for the daemon: `scripts/sw-triage.sh:619-650` (heuristic ladder), `scripts/sw-triage.sh:607-610` (recruit-derived fallback), `scripts/sw-recruit.sh:1127-1140` (team sizing), and `scripts/sw-pm.sh:228-307` (PM ladder). Any cap-tightening that misses these paths is silently overridden when daemon mode picks a template.

Constraints:
- Bash 3.2 compatibility (no associative arrays, `${var,,}`, etc.).
- Must not regress genuinely productive runs — `metrics.json` baseline (2026-05-21) shows `test_duration_s: 20`, so productive iteration cost is now low and the wide safety net is no longer justified.
- The change must be observable via existing telemetry (`emit_event "iter_max_reached"` in `scripts/lib/loop-convergence.sh:218`) and existing assertions (`scripts/sw-loop-test.sh:186,311` already pin `MAX_ITERATIONS=20`).

## Decision

Tighten the three multiplicative factors so the worst case is bounded by ~2× a typical productive run, and **realign every path that derives an iteration budget** so the daemon cannot silently re-inflate the cap.

**New ceiling formula:** `(MAX_ITERATIONS=20 + MAX_EXTENSIONS=1 · EXTENSION_SIZE=3) · (build_test_retries=1 + 1) = 23 · 2 = 46` invocations (67% reduction).

**Per-complexity ladder realigned** so triage/pm/recruit emit values consistent with the new global cap:

| Complexity tier | Old `max_iterations` | New | Rationale |
|---|---|---|---|
| `trivial-low` / `simple-low` | 2 | 2 | Already conservative |
| `simple-*` / `moderate-low` | 5 | **10** | "Low" tier |
| `moderate-*` / `complex-low` | 8 | **15** | "Medium" tier |
| `complex-*` / `epic-*` | 15 | **20** | "Full" tier, aligned with global cap |

**PM risk additions clamped to 20** with a bash 3.2-compatible `if/else` (replacing the silent overflow in `scripts/sw-pm.sh:326,333`).

**Data flow (config → loop):**

```
config/defaults.json ─┐
                      ├─► sw-pipeline.sh  ──► spec.build.max_iterations ──► sw-loop.sh
templates/*.json ─────┤                                                       │
                      │                                                       ├─► loop-convergence.sh
sw-triage.sh ─────────┤                                                       │   (extends if progress > 0)
sw-recruit.sh ────────┤                                                       │
sw-pm.sh ─────────────┘                                                       └─► emit_event iter_max_reached
```

Every node in the **upper** stack must agree on the ceiling, otherwise the highest emitter wins.

### Component Diagram

```
┌───────────────────────────┐   reads     ┌──────────────────────────────┐
│ config/defaults.json      │◄────────────│ scripts/sw-pipeline.sh:822   │
│  .pipeline.build_test_    │             │  build_test_retries=1        │
│   retries=1               │             │  ──► retry cycles            │
└───────────────────────────┘             └──────────────┬───────────────┘
                                                         │ spec.json
                                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Iteration Budget Sources (must all agree on ceiling)                 │
│                                                                      │
│  scripts/sw-triage.sh       scripts/sw-recruit.sh   scripts/sw-pm.sh │
│   heuristic ladder           team_max_iterations     PM ladder       │
│   (2/10/15/20)               (10/15/20)              (10/10/15/20)   │
│   + recruit fallback                                 + risk clamp≤20 │
└──────────────────────────────────────────────────────────────────────┘
                                                         │ spec.json
                                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│ scripts/sw-loop.sh                                                   │
│   MAX_ITERATIONS=20                                                  │
│   EXTENSION_SIZE=3, MAX_EXTENSIONS=1                                 │
└──────────────────────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│ scripts/lib/loop-convergence.sh::check_max_iterations                │
│   if progress>0 and EXTENSION_COUNT<MAX_EXTENSIONS:                  │
│       MAX_ITERATIONS += EXTENSION_SIZE                               │
│   else: STATUS=max_iterations                                        │
│   emit_event "iter_max_reached"                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Dependencies point inward: config is the inner layer; each upper component depends on it, never the reverse.

### Interface Contracts

```ts
// config/defaults.json (data contract)
interface DefaultsPipeline {
  max_iterations: 20;       // pinned
  build_test_retries: 1;    // was 3
}

// scripts/sw-loop.sh (env / sourced globals)
declare MAX_ITERATIONS: number;   // default 20, override via SW_MAX_ITERATIONS
declare EXTENSION_SIZE: 3;        // was 5
declare MAX_EXTENSIONS: 1;        // was 3
declare EXTENSION_COUNT: number;  // runtime, 0..MAX_EXTENSIONS

// scripts/lib/loop-convergence.sh
function check_max_iterations(
  current_iter: number,
  progress_lines: number,
): { status: "continue" | "max_iterations"; extended: boolean }
// Postcondition: EXTENSION_COUNT ≤ MAX_EXTENSIONS
// Postcondition: emits iter_max_reached when extending or halting

// scripts/sw-triage.sh / sw-recruit.sh / sw-pm.sh (spec emitters)
interface PipelineRecommendation {
  template: "fast" | "standard" | "full" | "hotfix";
  model: "haiku" | "sonnet" | "opus";
  max_iterations: 2 | 10 | 15 | 20;   // ladder values only
  agents: number;
}
// Invariant: max_iterations ≤ 20 for ALL emitters
// Invariant: max_iterations from PM with risk additions clamped to ≤20
```

Error contracts (unchanged surface):
- `check_max_iterations` returns `status: "max_iterations"` — never throws. Caller (`sw-loop.sh` main loop) treats as terminal.
- Triage/recruit/pm — on bad input fall through to default branch (`max_iterations=10` per new ladder); never emit unbounded value.

## Alternatives Considered

1. **Defaults-only edit (`config/defaults.json` + `sw-loop.sh` only)** —
   - Pros: ~2 files touched; minimal blast radius; fast to ship.
   - Cons: `sw-triage.sh`, `sw-recruit.sh`, `sw-pm.sh`, `sw-self-optimize.sh` each independently derive `max_iterations` and serialize it into the pipeline spec. Under daemon-driven operation (the case that actually matters for #605), the recruit/PM ladders silently override the lowered default — defeating the goal. **Rejected.**

2. **Audit and realign every iteration-budget emitter (chosen)** —
   - Pros: Closes the "ghost cap" gap; every code path agrees on the ceiling; each change is mechanical (single-number swap); existing tests already pin most knobs.
   - Cons: 8-10 files touched; higher review surface; per-path ladders remain duplicated.
   - **Chosen** because the cost is one number per file and the alternative leaves a known correctness hole.

3. **Hierarchical clamp abstraction (`clamp_to_policy_max()` helper)** —
   - Pros: Single source of truth long-term; survives future divergence; cleanest abstraction.
   - Cons: New module + indirection for a tuning change that's expected to be stable; higher risk of regression than 8 single-number edits. **Deferred** to a follow-up if ladders diverge further.

## Implementation Plan

**Files to create:** none.

**Files to modify:**
- `config/defaults.json` — `pipeline.build_test_retries: 3 → 1`
- `config/policy.json` (lines 212-213) — `sweep.retry_max_iterations: 25 → 20`; `sweep.stuck_retry_max_iterations: 30 → 23`
- `scripts/sw-loop.sh` (lines 129-130) — `EXTENSION_SIZE: 5 → 3`; `MAX_EXTENSIONS: 3 → 1`; update inline comment
- `scripts/sw-triage.sh` (lines 619-650 heuristic; 607-610 recruit fallback) — new ladder 2/10/15/20
- `scripts/sw-recruit.sh` (lines 1127-1140) — `team_max_iterations` base `10→15`, ≤2 members `5→10`, ≥5 members `20` (unchanged), security floor `15` (unchanged)
- `scripts/sw-pm.sh` (lines 228-232, 277-307) — heuristic ladder aligned to 10/10/15/20
- `scripts/sw-pm.sh` (lines 326, 333) — bash 3.2-compatible clamp:
  ```bash
  if [[ $((max_iterations + 4)) -gt 20 ]]; then max_iterations=20; else max_iterations=$((max_iterations + 4)); fi
  ```
- `scripts/sw-self-optimize.sh` (lines 602-604) — empty-band ceilings `10/20/30 → 10/15/20`; floors (5/10/15) untouched
- `scripts/sw-loop-test.sh` (lines 186-202, 311-323) — add `EXTENSION_SIZE=3`, `MAX_EXTENSIONS=1` assertions; keep `MAX_ITERATIONS=20`
- `scripts/sw-e2e-smoke-test.sh` — add ceiling-respect assertion computing `(20 + 1·3) · (1+1) = 46` from sourced defaults

**Dependencies:** none new.

**Risk areas:**
- `scripts/sw-pm.sh:326,333` — current `max_iterations=$((max_iterations + 4))` overflows the new 20 cap when complexity=`complex` + risk=`critical`. Clamp logic is the only non-mechanical change.
- `scripts/sw-self-optimize.sh:602-604` — empty-band ceilings interact with conservative floors; only tighten ceilings, leave floors alone to avoid trapping a band at its floor.
- `scripts/lib/loop-convergence.sh:218-235` — extension logic is unchanged but `MAX_EXTENSIONS=1` means the "any non-zero progress extends" rule now only fires once; verify the convergence tests still cover the extend-then-halt path.
- External `.claude/daemon-config.json` in deployed installs may override these — out of scope, but document worst-case math in PR body so operators understand the new floor.
- `scripts/sw-pipeline.sh:830` `SW_PIPELINE_MAX_BUILD_RETRIES` (cycling halt, default 3) is independent of `build_test_retries` and unaffected — flag for reviewer awareness.

### Data Flow

```
defaults.json (build_test_retries=1)
        │
        ▼
sw-pipeline.sh ── reads via _config_get_int ──► spawns build stage with N retries
        │                                                    │
        ▼                                                    ▼
spec.json ◄── max_iterations from triage/recruit/pm    sw-loop.sh sourced
        │                                                    │
        ▼                                                    ▼
sw-loop.sh main loop ──► per-iteration claude call ──► test exec ──► progress check
                                                                          │
                                                                          ├─ progress=0 → halt
                                                                          ├─ iter < MAX → continue
                                                                          └─ iter == MAX and progress>0 and ext<1
                                                                             → MAX += 3, ext=1, continue
                                                                          └─ iter == MAX and ext==1 → STATUS=max_iterations
```

### Error Boundaries

- **`config/defaults.json` parse error** — caught by `_config_get_int` fallback (returns provided default). Tested in existing pipeline tests.
- **Spec missing `max_iterations`** — `sw-loop.sh` falls back to `SW_MAX_ITERATIONS:-20` (line 91). Safe.
- **Extension budget exhausted** — `check_max_iterations` returns `status: "max_iterations"`; main loop emits `loop_halted` event with reason. No exception propagation.
- **PM risk overflow** — new clamp in `sw-pm.sh` is the boundary; downstream consumers (`sw-pipeline.sh`) trust the spec.
- **Self-heal failure after retry=1** — pipeline marks stage failed and surfaces to `error-summary.json`; no further auto-retry.

## Validation Criteria

- [ ] Worst-case ceiling math: shell snippet sources `sw-loop.sh` defaults and reads `config/defaults.json`, computes `(MAX_ITERATIONS + MAX_EXTENSIONS·EXTENSION_SIZE) · (build_test_retries+1)`, asserts result `≤46`
- [ ] `jq -e '.pipeline.build_test_retries == 1' config/defaults.json` exits 0
- [ ] `grep -qE '^EXTENSION_SIZE=3' scripts/sw-loop.sh && grep -qE '^MAX_EXTENSIONS=1' scripts/sw-loop.sh`
- [ ] `bash scripts/sw-loop-test.sh` exits 0 with new `EXTENSION_SIZE=3` / `MAX_EXTENSIONS=1` assertions present
- [ ] `bash scripts/sw-pipeline-test.sh` exits 0 (validates pipeline reads `build_test_retries=1`)
- [ ] `bash scripts/sw-lib-loop-convergence-test.sh` exits 0 — extend-then-halt path covered with `MAX_EXTENSIONS=1`
- [ ] `bash scripts/sw-e2e-smoke-test.sh` exits 0 with end-to-end ceiling-respect assertion
- [ ] `npm test` exits 0
- [ ] `shellcheck scripts/sw-loop.sh scripts/sw-triage.sh scripts/sw-pm.sh scripts/sw-recruit.sh scripts/sw-self-optimize.sh` exits 0
- [ ] Triage emits `max_iterations=20` (not 24, not 19) for `complex-critical`
- [ ] PM emits `max_iterations ≤ 20` for every (complexity, risk) combination — verified by unit assertion over the 4×3 matrix
- [ ] Self-optimize empty-band ceilings are 10/15/20 (not 10/20/30) for an empty sample set
- [ ] PR body documents `(20 + 1·3) · (1+1) = 46` and references `scripts/sw-loop.sh:129-130` and `config/defaults.json` `pipeline.build_test_retries`
- [ ] Cumulative branch diff touches only files in "Files to Modify" — no incidental cleanup
