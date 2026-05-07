# Tasks — [Ruflo MCP 1.5] Benchmark and acceptance validation — confirm ≥10× subprocess reduction

## Status: Deliverable 1 ✅ done · Deliverable 2 ✅ done (foundation + pipeline wiring)
Pipeline: autonomous | Branch: feature/504-acceptance-validation

---

## Deliverable 1 — MCP Benchmark (≥10× subprocess reduction) ✅

- [x] `SW_RUFLO_BACKEND=cli|mcp` selectable (#503)
- [x] Both backends produce 0 errors with `--tool ping` and `memory_search`
- [x] Benchmark harness `scripts/benchmark-ruflo-backends.sh` measures per-call latency, unique transient PIDs, errors
- [x] 200ms cadence process sampling during workload (sampler in `run_backend`)
- [x] Acceptance ratio gate `BENCH_REDUCTION_RATIO ≥ 10`
- [x] `--orphan-runs N` multi-cycle sentinel for #441 leak check
- [x] Validated baseline documented in `docs/ruflo-mcp-transport.md` § "Validated baseline (2026-05-05)"
- [x] CHANGELOG entry under `[Unreleased]`
- [x] Process leak detection: `ps` sampling + orphan-runs sentinel = 0 orphans across 3 cycles
- [x] Benchmark results persisted to `.claude/pipeline-artifacts/benchmarks/{benchmark-{cli,mcp},orphan-runs,summary}-<ts>.{json,md}`

### Validated Results (2026-05-05)
- CLI: 62 unique transient node PIDs, p95=8 ms, 0 errors
- MCP: 2 unique transient node PIDs (one pre-existing host daemon), p95=8 ms, 0 errors
- Reduction ratio: **31×** (#504 acceptance bar is ≥10× — comfortable pass)
- #441 sentinel: 0 orphans across 3 consecutive bridge start/bench/stop cycles
- Raw artifacts: `.claude/pipeline-artifacts/benchmarks/{benchmark-{cli,mcp},orphan-runs}-20260505T174025Z.json`

---

## Deliverable 2 — Per-Stage Cost Summary Table ✅

### Foundation ✅
- [x] `scripts/lib/cost/baselines.sh` — rolling per-stage baselines (all-issues + per-issue)
- [x] `scripts/lib/cost/table-render.sh` — fixed-width ASCII table with HIGH/LOW flags + ANSI colors
- [x] `sw cost breakdown ... --render | --render-plain` flags wired in `sw-cost.sh`
- [x] `sw cost breakdown-update-baseline <file> [issue]` internal hook for pipeline completion
- [x] Bootstrap guard — n<3 returns NORMAL (avoids alarm fatigue on first runs)
- [x] Sliding-window rolling avg, capped at `BASELINE_MAX_N=50` to prevent skew
- [x] Input validation — rejects negative cost, non-numeric cost, stage names with non-ident chars
- [x] Edge case: first run (all "new" flag, no comparison)
- [x] Edge case: missing breakdown.json (graceful warn, exit non-zero)
- [x] 12 new tests in `sw-cost-test.sh` (all 68 cost tests pass)

### Pipeline integration ✅
- [x] **T1** — `cost_baseline_update` + `render_cost_table_plain` wired into `cleanup_on_exit` (sw-pipeline.sh:~983) after `cost_generate_breakdown`. Render-first-then-update ordering matches `cost_breakdown_command` so HIGH/LOW flags compare vs PRIOR runs.
- [x] **T2** — Cost-table GitHub comment posted from PR stage (pipeline-stages-delivery.sh:~520) as a fenced code block follow-up to the "PR created" comment. Failure is non-fatal.
- [x] **T3** — Defensive `source lib/cost/{table-render,baselines}.sh` in pipeline-stages-delivery.sh covers standalone-load path (daemon-triage.sh).
- [x] **T4** — 3 new tests in `sw-pipeline-test.sh`: wiring assertion for cleanup, wiring assertion for PR comment, hermetic functional test against staged `cost-breakdown.json`. All 88 pipeline tests pass.
- [x] **T5** — HIGH/LOW flag accuracy verified across ≥5 historical breakdowns. 4 new hermetic tests in `sw-cost-test.sh` build a baseline of 5 runs (0.10..0.50, rolling avg=0.30, n=5), then classify a 6th run at 2× as HIGH, at 0.33× as LOW, and at exactly avg as NORMAL — all pass with a real n=5 baseline (no bootstrap shortcut). 72/72 cost tests pass.
- [x] **T6** — Regression suites green: sw-cost-test (72/72), sw-pipeline-test (88/88), sw-loop-test (269/269), sw-lib-pipeline-stages-test (105/105), sw-lib-pipeline-stages-review-test (31/31), sw-repo-dir-project-root-test (75/75).
- [x] **T8** — CHANGELOG `[Unreleased]` updated with D2 wiring entry.

---

## Notes
- Bench tool selectable: `--tool memory_search` (production) or `--tool ping` (transport-only;
  works even when host has broken ruflo memory I/O — used for current CI baseline due to ONNX
  runtime mismatch on this runner).
- Per-call PID cap (`MCP_MAX_PIDS=1`) is soft-warn only; ratio check (cli/mcp ≥ 10×) is the
  load-bearing acceptance gate.
- Cost baseline files at `~/.shipwright/baselines/{stage-costs.json, issue-<N>-costs.json}` —
  override with `SW_BASELINE_DIR` for tests.
- HIGH = >1.5× rolling avg; LOW = <0.5×; NEW = no baseline yet; NORMAL = within range.
- Generated from pipeline plan at 2026-05-04T09:47:19Z; D2 wiring landed 2026-05-05.
