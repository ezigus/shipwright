# Tasks — [Ruflo MCP 1.5] Benchmark and acceptance validation — confirm ≥10× subprocess reduction

## Status: Deliverable 1 ✅ done · Deliverable 2 🚧 foundation landed
Pipeline: autonomous | Branch: test/-ruflo-mcp-1-5-benchmark-and-acceptance-504

---

## Deliverable 1 — MCP Benchmark (≥10× subprocess reduction) ✅

- [x] `SW_RUFLO_BACKEND=cli|mcp` selectable (#503)
- [x] Both backends produce 0 errors with `--tool ping` and `memory_search`
- [x] Benchmark harness `scripts/benchmark-ruflo-backends.sh` measures per-call latency, unique transient PIDs, errors
- [x] 200ms cadence process sampling during workload (sampler in `run_backend`)
- [x] Acceptance ratio gate `BENCH_REDUCTION_RATIO ≥ 10`
- [x] `--orphan-runs N` multi-cycle sentinel for #441 leak check
- [x] Validated baseline documented in `docs/ruflo-mcp-transport.md` § "Validated baseline (2026-05-03)"
- [x] CHANGELOG entry under `[Unreleased]`
- [x] Process leak detection: `ps` sampling + orphan-runs sentinel = 0 orphans across 3 cycles
- [x] Benchmark results persisted to `.claude/pipeline-artifacts/benchmarks/{benchmark-{cli,mcp},orphan-runs,summary}-<ts>.{json,md}`

### Validated Results (2026-05-03)
- CLI: 66 unique transient node PIDs, p95=513 ms, 0 errors
- MCP: 2 unique transient node PIDs (one pre-existing host daemon), p95=9 ms, 0 errors
- Reduction ratio: **33×** (#504 acceptance bar is ≥10× — comfortable pass)
- #441 sentinel: 0 orphans across 3 consecutive bridge start/bench/stop cycles
- Raw artifacts: `.claude/pipeline-artifacts/benchmarks/{benchmark-{cli,mcp},orphan-runs}-20260503T231332Z.json`

---

## Deliverable 2 — Per-Stage Cost Summary Table 🚧

### Foundation (this iteration) ✅
- [x] `scripts/lib/cost/baselines.sh` — rolling per-stage baselines (all-issues + per-issue)
- [x] `scripts/lib/cost/table-render.sh` — fixed-width ASCII table with HIGH/LOW flags + ANSI colors
- [x] `sw cost breakdown ... --render | --render-plain` flags wired in `sw-cost.sh`
- [x] `sw cost breakdown-update-baseline <file> [issue]` internal hook for pipeline completion
- [x] Bootstrap guard — n<3 returns NORMAL (avoids alarm fatigue on first runs)
- [x] Sliding-window rolling avg, capped at `BASELINE_MAX_N=50` to prevent skew
- [x] Input validation — rejects negative cost, non-numeric cost, stage names with non-ident chars
- [x] Edge case: first run (all "new" flag, no comparison)
- [x] Edge case: missing breakdown.json (graceful warn, exit non-zero)
- [x] Tests in `sw-cost-test.sh` (12 new test cases — all 68 pass)
- [x] Comparison baseline file created: `~/.shipwright/baselines/stage-costs.json` (and per-issue)
- [x] HIGH (>1.5× avg) and LOW (<0.5× avg) flags display correctly (verified by test)

### Pipeline integration (next iteration) ⏳
- [ ] Hook `cost_baseline_update` into `sw-pipeline.sh` cleanup (after `cost_generate_breakdown`)
- [ ] Render `--render-plain` table at end of pipeline run (terminal output)
- [ ] Post `--render-plain` table as GitHub comment when PR is opened
- [ ] Acceptance: table rendered correctly for ≥5 historical runs (manual verification)
- [ ] (Optional) GitHub comment posting with retry/backoff

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
- Generated from pipeline plan at 2026-05-04T09:47:19Z; updated by iteration 1 (this run).
