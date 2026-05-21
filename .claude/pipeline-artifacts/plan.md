# Plan — Issue #605: Reduce build-loop iteration ceiling

## Goal
Cap the build-loop worst case at ~50 Claude Code invocations per issue (down from 135) by tightening per-complexity iteration ceilings, shrinking auto-extension, and reducing self-heal retry cycles.

## Current State (audit results)

The issue description partially mismatches what's in `main`. Audited values:

| Knob | Issue claims | Actually in `main` | Source |
|---|---|---|---|
| `MAX_ITERATIONS` (loop default) | 30 | **20** | `scripts/sw-loop.sh:91` |
| Triage `max_iterations` for `complex/epic-*` | 30 | **15** | `scripts/sw-triage.sh:640` |
| `EXTENSION_SIZE` | 5 | 5 | `scripts/sw-loop.sh:129` |
| `MAX_EXTENSIONS` | 3 | 3 | `scripts/sw-loop.sh:130` |
| `BUILD_TEST_RETRIES` | 2 | **3** | `config/defaults.json:28` (read by `sw-pipeline.sh:822`) |
| Per-cycle ceiling | 45 | **35** (20 + 3×5) | derived |
| Cycles | 3 | **4** (1 + 3 retries) | derived |
| Worst case | 135 | **140** | derived |

Triage already has a per-complexity ladder (trivial=2, simple/moderate-low=5, moderate=8, complex/epic=15). Pipeline templates set build.max_iterations: fast/hotfix/ios-fast=10, others=20. So the floor work is largely already done; the remaining levers are: align `complex/epic` triage tier with the loop default (15→20), shrink extensions, and cut self-heal retries.

The issue's framing of "low=10, medium=15, full=20" maps onto triage tiers (simple/moderate-low → moderate-medium → complex/epic).

## Target State

| Knob | New value | Rationale |
|---|---|---|
| Loop `MAX_ITERATIONS` default | 20 (unchanged) | Already at target ceiling |
| Triage `trivial-low`/`simple-low` | 2 (unchanged) | Already conservative |
| Triage `simple-*`/`moderate-low` | **10** (was 5) | Align "low" complexity tier |
| Triage `moderate-*`/`complex-low` | **15** (was 8) | Align "medium" complexity tier |
| Triage `complex-*`/`epic-*` | **20** (was 15) | Align "full" tier with global cap |
| `EXTENSION_SIZE` | **3** (was 5) | Smaller extension granularity |
| `MAX_EXTENSIONS` | **1** (was 3) | One extension only |
| `BUILD_TEST_RETRIES` | **1** (was 3) | One self-heal cycle |
| `pipeline.max_iterations` (defaults.json) | 20 (unchanged) | Already at target |
| Per-cycle ceiling | **23** (20 + 1×3) | 51% reduction from 45 |
| Self-heal cycles total | **2** (initial + 1 retry) | 50% reduction from 4 |
| **Worst case** | **46** invocations | 67% reduction from 140 |

Targeted-fix cycles (per separate plan item T2.1) use `MAX_ITERATIONS=5` with no extensions — that work is out of scope here.

## Brainstorming / Socratic Review

**Minimum viable change**: lower three defaults (`EXTENSION_SIZE`, `MAX_EXTENSIONS`, `BUILD_TEST_RETRIES`) plus one triage tier (`complex/epic`). That alone hits the ~50-invocation target.

**Implicit requirements**: the issue requires the change land in *all* paths that derive iteration budgets — triage, recruit, pm, templates — otherwise a daemon-driven run will reset the cap via its picked template/recruit recommendation.

**Acceptance criteria** (since none in issue): (a) per-cycle ceiling derived from defaults computes to ≤23; (b) self-heal cycles ≤2; (c) end-to-end smoke run on fixture issue completes within new caps; (d) existing tests updated and passing.

### Design Alternatives

| # | Approach | Complexity | Blast radius | Maintainability |
|---|---|---|---|---|
| A — Lower defaults in `config/defaults.json` + `sw-loop.sh` only | Low | Small (config-only) | High — single source of truth, but triage/recruit/pm hardcoded values silently raise the cap when they run |
| **B (chosen) — Lower defaults + audit & realign all derivative paths (triage, recruit, pm, self-optimize floors)** | Medium | Medium (8-10 files) | Best — every code path agrees; each change is mechanical (single number) |
| C — Add a hard hierarchical cap that clamps any caller-supplied max to `pipeline.max_iterations_default` | High | High (new clamp logic everywhere) | Cleanest long-term but introduces new abstraction for a config problem |

**Choice: B** — A leaves silent overrides that defeat the cap; C is over-engineered for a tuning change. B is one number per file with existing tests.

### Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Genuinely productive runs truncated by tighter cap | Medium | Medium | Smoke gate (DoD) validates a real fixture issue completes; `--max-iterations` CLI escape hatch remains for ad-hoc overrides |
| Self-optimize floors (5/10/15) interact with tighter ceiling and trap a band at its floor | Low | Low | Floors are conservative and only apply when there's insufficient data; tighten only the empty-band ceilings (10/20/30 → 10/15/20) |
| Test assertions in `sw-loop-test.sh:186, 311` already pin to 20 — won't drift | n/a | n/a | Update only assertions for changed defaults |
| `sw-pipeline-test.sh:3301` pins `MAX_ITERATIONS=10` via template — independent, unaffected | Low | Low | No change needed |
| External configs (`.claude/daemon-config.json` in deployed installs) override these | Medium | Low | Defaults are the *floor*; user overrides are intentional and out of scope |
| `sw-pipeline.sh:830` `SW_PIPELINE_MAX_BUILD_RETRIES` (cycling halt, default 3) interacts with `BUILD_TEST_RETRIES=1` | Low | Low | Cycling halt counts cross-invocation; tightening per-invocation retries doesn't conflict |
| PM risk-tier additions (`+4` for critical, `+2` for high) overflow the new 20 cap | Medium | Low | Add bash 3.2-compatible if/else clamp to ≤20 |

### Dependency Analysis

- `sw-pipeline.sh:822` reads `pipeline.build_test_retries` from `config/defaults.json` — single source.
- `sw-loop.sh:91, 129, 130` are inline defaults; tests in `sw-loop-test.sh:186, 311` assert these.
- `sw-triage.sh:622-646` heuristic mapping; `sw-triage.sh:607-610` recruit-derived fallback.
- `sw-recruit.sh:1127, 1131, 1134, 1139` `team_max_iterations` ladder used by triage when recruit is active.
- `sw-pm.sh:228, 277, 287, 297, 307, 326, 333` parallel mapping for PM-recommended teams.
- `templates/pipelines/*.json` build stage `max_iterations` — set per template; already at 10 or 20.
- `scripts/lib/loop-convergence.sh:177-240` `check_max_iterations` reads `EXTENSION_SIZE`/`MAX_EXTENSIONS` from sw-loop globals.

No circular dependency; flow is `defaults.json → sw-pipeline.sh → spec/template → sw-loop.sh`.

### Simplicity Check

Can't be done with fewer files: each path (triage, recruit, pm) independently decides max_iterations and gets serialized into a per-issue pipeline spec. Skipping one means a daemon-driven run silently reverts the cap.

## Files to Modify

1. **`config/defaults.json`** — `pipeline.build_test_retries: 3 → 1`
2. **`scripts/sw-loop.sh`** (lines 129-130) — `EXTENSION_SIZE: 5 → 3`, `MAX_EXTENSIONS: 3 → 1`; update inline comment
3. **`scripts/sw-triage.sh`** (lines 619-650) — heuristic tier values: `simple-*/moderate-low: 5→10`, `moderate-*/complex-low: 8→15`, `complex-*/epic-*: 15→20`; default branch `5→10`
4. **`scripts/sw-triage.sh`** (lines 607-610) — recruit-derived fallback: agents≥4 `15→20`, agents≥3 `8→15`, agents≤1 `2→10`, else `5→10`
5. **`scripts/sw-recruit.sh`** (lines 1127-1140) — `team_max_iterations`: base `10→15`, ≤2 members `5→10`, ≥5 members `20` (unchanged), security floor `15` (unchanged)
6. **`scripts/sw-pm.sh`** (lines 228-232, 277, 287, 297, 307) — heuristic ladder: simple-bugfix `3→10`, small-feature `5→10`, medium-feature `6→15`, complex `8→20`; recruit branch parallel
7. **`scripts/sw-pm.sh`** (lines 326, 333) — clamp risk additions to ≤20 via bash 3.2-compatible if/else (current `max_iterations=$((max_iterations + 4))` overflows new cap)
8. **`scripts/sw-self-optimize.sh`** (lines 602-604) — empty-band defaults: `10/20/30 → 10/15/20` (ceilings); leave floors (5/10/15) alone
9. **`config/policy.json`** (lines 212-213) — `sweep.retry_max_iterations: 25→20`, `sweep.stuck_retry_max_iterations: 30→23` (align with per-cycle ceiling)
10. **`scripts/sw-loop-test.sh`** (lines 186-202, 311-323) — assertions already match `MAX_ITERATIONS=20`; add new assertions for `EXTENSION_SIZE=3`, `MAX_EXTENSIONS=1`
11. **`scripts/sw-e2e-smoke-test.sh`** — add a smoke assertion validating new ceiling values are respected end-to-end on a fixture issue

## Implementation Steps

1. Update `config/defaults.json`: `pipeline.build_test_retries: 3 → 1`.
2. Update `scripts/sw-loop.sh`: `EXTENSION_SIZE=5 → 3`, `MAX_EXTENSIONS=3 → 1` (lines 129-130). Update inline comment to reflect "1 extension × 3 iterations = 23 per-cycle max".
3. Update `scripts/sw-triage.sh` heuristic mapping (lines 619-650): renumber per-complexity ladder.
4. Update `scripts/sw-triage.sh` recruit-derived fallback (lines 607-610).
5. Update `scripts/sw-recruit.sh` `team_max_iterations` derivation (lines 1125-1140).
6. Update `scripts/sw-pm.sh` heuristic ladder (lines 270-311). For risk-tier additions (lines 322-336), replace `max_iterations=$((max_iterations + 4))` with bash 3.2-compatible if/else: `if [[ $((max_iterations + 4)) -gt 20 ]]; then max_iterations=20; else max_iterations=$((max_iterations + 4)); fi` (and same pattern for `+2`).
7. Update `scripts/sw-pm.sh` recruit-derived block (lines 228-232) parallel to triage.
8. Update `scripts/sw-self-optimize.sh` band defaults for empty samples (lines 602-604).
9. Update `config/policy.json` sweep defaults (lines 212-213).
10. Update `scripts/sw-loop-test.sh` assertions (lines 186-202, 311-323): keep `MAX_ITERATIONS=20`; add checks for `EXTENSION_SIZE=3` and `MAX_EXTENSIONS=1`.
11. Add smoke validation in `scripts/sw-e2e-smoke-test.sh`: assert that sourcing defaults yields `BUILD_TEST_RETRIES=1` and that a fixture build loop's spec computes per-cycle ceiling ≤23.
12. Run: `bash scripts/sw-loop-test.sh`, `bash scripts/sw-pipeline-test.sh`, `bash scripts/sw-e2e-smoke-test.sh`, `bash scripts/sw-lib-loop-convergence-test.sh`, `npm test`.

## Task Checklist

- [ ] Task 1: Lower `pipeline.build_test_retries` 3→1 in `config/defaults.json`
- [ ] Task 2: Lower `EXTENSION_SIZE` 5→3 and `MAX_EXTENSIONS` 3→1 in `scripts/sw-loop.sh`
- [ ] Task 3: Update per-complexity `max_iterations` ladder in `scripts/sw-triage.sh` (heuristic + recruit-derived branches)
- [ ] Task 4: Update `team_max_iterations` derivation in `scripts/sw-recruit.sh`
- [ ] Task 5: Update heuristic ladder and recruit branch in `scripts/sw-pm.sh`
- [ ] Task 6: Clamp PM risk additions to ≤20 (bash 3.2-compatible if/else)
- [ ] Task 7: Tighten empty-sample ceilings in `scripts/sw-self-optimize.sh` (10/15/20 instead of 10/20/30)
- [ ] Task 8: Lower `sweep.retry_max_iterations` 25→20 and `sweep.stuck_retry_max_iterations` 30→23 in `config/policy.json`
- [ ] Task 9: Add `EXTENSION_SIZE=3` / `MAX_EXTENSIONS=1` assertions in `scripts/sw-loop-test.sh`
- [ ] Task 10: Add smoke check in `scripts/sw-e2e-smoke-test.sh` verifying new ceilings end-to-end
- [ ] Task 11: Run loop/pipeline/convergence/smoke tests and verify they pass
- [ ] Task 12: Hand-verify worst-case math: `20 + 1×3 = 23` per cycle, `1+1 = 2` cycles, `23×2 = 46` invocations

## Testing Approach

- **Unit / config tests**: `bash scripts/sw-loop-test.sh` (assertions for `MAX_ITERATIONS=20`, new `EXTENSION_SIZE=3`, `MAX_EXTENSIONS=1`); `bash scripts/sw-pipeline-test.sh` (validates pipeline reads `BUILD_TEST_RETRIES=1` from defaults); `bash scripts/sw-lib-loop-convergence-test.sh` (validates `check_max_iterations` extends at most once with new caps).
- **Integration**: `bash scripts/sw-e2e-smoke-test.sh` — new assertion builds a fixture issue, verifies completion in ≤23 iterations per cycle, ≤2 cycles total.
- **Math verification**: shell snippet that sources `sw-loop.sh` defaults, reads `config/defaults.json` via `_config_get_int`, and computes `(MAX_ITERATIONS + MAX_EXTENSIONS*EXTENSION_SIZE) * (BUILD_TEST_RETRIES+1)`. Expected: `23 * 2 = 46`.
- **Regression**: `npm test` for the full Node test suite.
- **Manual smoke (PR body, not auto)**: trigger `shipwright pipeline start --issue 605 --worktree --dry-run` to confirm planned spec emits build.max_iterations=20 and new caps appear in rendered context.

### Test Pyramid Breakdown
- **Unit (existing + 2 new)**: defaults assertions in `sw-loop-test.sh` (`EXTENSION_SIZE=3`, `MAX_EXTENSIONS=1`).
- **Integration (1 new)**: `sw-e2e-smoke-test.sh` end-to-end ceiling validation on fixture issue.
- **Coverage targets**: 100% of changed config knobs have at least one assertion that pins the new value.

### Critical Paths to Test
- **Happy path**: a productive loop completes in ≤23 iterations and reports success.
- **Error case 1**: a non-productive loop hits the cap, applies its single extension (3 iterations), then halts with `STATUS=max_iterations`.
- **Error case 2**: tests fail in cycle 1, pipeline self-heals once, tests fail in cycle 2, pipeline halts (not 4 cycles).
- **Edge case 1**: triage with `complex-critical` returns `max_iterations: 20` (not 19, not 24).
- **Edge case 2**: PM with `critical` risk + `complex` complexity clamps additions and returns ≤20.

## Definition of Done

- [ ] `bash scripts/sw-loop-test.sh` exits 0 with new `EXTENSION_SIZE=3` and `MAX_EXTENSIONS=1` assertions present {auto:other:bash scripts/sw-loop-test.sh}
- [ ] `bash scripts/sw-pipeline-test.sh` exits 0 {auto:other:bash scripts/sw-pipeline-test.sh}
- [ ] `bash scripts/sw-lib-loop-convergence-test.sh` exits 0 {auto:other:bash scripts/sw-lib-loop-convergence-test.sh}
- [ ] `bash scripts/sw-e2e-smoke-test.sh` exits 0 with ceiling-respect assertion {auto:other:bash scripts/sw-e2e-smoke-test.sh}
- [ ] `npm test` exits 0 {auto:tests}
- [ ] `jq -e '.pipeline.build_test_retries == 1' config/defaults.json` exits 0 {auto:other:jq -e '.pipeline.build_test_retries == 1' config/defaults.json}
- [ ] `EXTENSION_SIZE=3` and `MAX_EXTENSIONS=1` present in `scripts/sw-loop.sh` {auto:other:bash -c "grep -qE '^EXTENSION_SIZE=3' scripts/sw-loop.sh && grep -qE '^MAX_EXTENSIONS=1' scripts/sw-loop.sh"}
- [ ] `shellcheck scripts/sw-loop.sh scripts/sw-triage.sh scripts/sw-pm.sh scripts/sw-recruit.sh scripts/sw-self-optimize.sh` exits 0 {auto:lint}
- [ ] Cumulative branch diff touches only the files in "Files to Modify" {auto:diff}
- [ ] PR body documents worst-case math `(20 + 1*3) * (1+1) = 46` {manual}

## Alternatives Considered

**A. Defaults-only change** — Lowest blast radius (2-3 files), but daemon/recruit/pm paths silently emit higher caps via their hardcoded ladders, defeating the goal under realistic operation. Rejected.

**B. Audit & realign all paths (chosen)** — 8-10 files touched, each a single-number edit. Higher maintenance burden upfront but eliminates "ghost cap" risk. Existing tests already pin most defaults, so regression risk is low.

**C. Hierarchical clamp abstraction** — New `clamp_to_policy_max()` helper in `scripts/lib/policy.sh` consumed by triage/recruit/pm. Cleanest long-term and survives future divergence, but introduces a new abstraction and indirection for a tuning change expected to be stable. Reserve for a follow-up if per-path ladders need to diverge further.

## Performance Skill Required Outputs

### Baseline Metrics
- Theoretical worst case in `main`: **140 Claude Code invocations / issue** (loop=20 + 3×5 extensions × 4 cycles)
- Postmortem evidence (run 26006244558, issue #460): 4-hour spinning run before GHA 300-min timeout halted it
- 10-min heartbeat keeps the 45-min silence watchdog dormant, so today the only real ceiling is GHA wall-clock

### Optimization Targets
- Worst case ≤50 invocations (target from issue) — plan achieves **46** (67% reduction)
- Per-cycle ceiling ≤25 — plan achieves **23**
- Self-heal cycles ≤2 — plan achieves **2**
- No regression in genuinely productive runs — validated by smoke gate

### Profiling Strategy
- Static analysis: derive ceiling from sourced defaults (no runtime profiling needed for config change)
- Empirical: run smoke fixture, count `iteration-*.log` files in `LOG_DIR`, cross-check against `EXTENSION_COUNT` in `events.jsonl`
- Telemetry already in place: `emit_event "iter_max_reached"` in `loop-convergence.sh` records actual extension applications

### Benchmark Plan
- **Before**: derive `(20 + 3×5) × 4 = 140` from current code; record in PR body
- **After**: derive `(20 + 1×3) × 2 = 46` from changed code; assert via shell snippet in smoke test
- **Realistic-data check**: smoke gate runs a small fixture issue and verifies the loop completes within new caps; if it can't, the caps are too tight

## Systematic Debugging — Root Cause Summary

(No prior failed stage attempt for this issue per artifacts.) Applying root-cause framing to the underlying problem:

### Root Cause Hypothesis
1. **Iteration ceilings were sized for worst-case agent confusion, not productive work** (most likely) — confirmed by triage default of 15 for `complex/epic` even though productive runs complete in <10 iterations (per metrics.json baseline data).
2. **Extensions compound silently** — `check_max_iterations` extends by 5 up to 3 times whenever progress isn't *zero*, so a steadily-stuck loop trickles past the cap.
3. **Self-heal multiplies the cap** — `BUILD_TEST_RETRIES=3` means 4 full cycles, each independently subject to extensions, so the cap is multiplicative not additive.

### Evidence Gathered
- `scripts/sw-loop.sh:91` `MAX_ITERATIONS=20`
- `scripts/sw-loop.sh:129-130` `EXTENSION_SIZE=5`, `MAX_EXTENSIONS=3`
- `scripts/lib/loop-convergence.sh:218-235` extension logic (extends on any non-zero progress)
- `config/defaults.json:28` `build_test_retries=3`
- `scripts/sw-pipeline.sh:822` reads same key
- `scripts/sw-triage.sh:622-650` per-complexity ladder
- Run 26006244558 postmortem (issue context): 4-hour failure → GHA wall-clock saved it, not internal cap

### Fix Strategy
Tighten three multiplicative factors (per-call cap, extension budget, retry cycles) so the worst case is bounded by ≤2× the typical productive run, not ≥10×. This is the *root cause* fix: the loop's safety net was wider than the productive workload required.

### Verification Plan
- Smoke test on fixture issue confirms productive work fits in 23 iterations × 2 cycles
- Math snippet in PR body documents the new worst-case derivation
- Existing convergence tests (`sw-lib-loop-convergence-test.sh`) validate the extension logic still triggers correctly under tighter caps
