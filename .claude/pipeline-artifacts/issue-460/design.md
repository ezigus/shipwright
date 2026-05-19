Verification complete. The plan's claims hold except for one naming error: the existing baseline-update function is `baseline_update_from_breakdown` (not `cost_baseline_update`), and it already handles the per-stage iteration. I'll flag that in the ADR.

# Design: Upload cost-breakdown.json as GitHub Actions artifact for cross-machine optimization

## Context

`scripts/sw-cost.sh::cost_generate_breakdown` already writes `cost-breakdown.json` into `.claude/pipeline-artifacts/` on every pipeline exit path (`scripts/sw-pipeline.sh:1200`). Today the only way that JSON leaves the runner is via the single combined upload step at `.github/workflows/shipwright-pipeline.yml:1302-1313`, which packages the entire `.claude/pipeline-artifacts/` directory plus `/tmp/pipeline.log` and `events.jsonl` into one artifact named `pipeline-logs-issue-<N>-run-<RUN_ID>` with `retention-days: 7`.

Two consequences:

1. **Not discoverable by name.** Any consumer that just wants cost data has to download a multi-MB log bundle and rummage. The `shipwright-optimize.yml` cron (Sunday 03:00 UTC) currently doesn't try — it only restores baselines from the `shipwright-data` orphan branch (`shipwright-optimize.yml:35-52`).
2. **7-day retention is shorter than the optimizer's 7-day cadence.** A single missed Sunday loses everything.

The reuse opportunity is real: `scripts/lib/cost/baselines.sh::baseline_update_from_breakdown` already folds one `cost-breakdown.json` into per-stage rolling averages under `~/.shipwright/baselines/`, which the optimize workflow already persists to `shipwright-data`. Cross-machine optimization is therefore one upload step + one download/merge step away.

Constraints from the repo: Bash 3.2 compatibility (no associative arrays, no `${var,,}`), `set -euo pipefail`, atomic `tmp + mv` writes, `jq` for all JSON, no network in tests, `info`/`success`/`warn` helpers, `emit_event` for observability.

The implementation plan as written is mostly sound but contains one inaccuracy: it refers to `cost_baseline_update` as the reuse target. The actual function is `baseline_update_from_breakdown` (and the per-stage primitive is `baseline_update_stage`). The merge layer should call `baseline_update_from_breakdown` per merged input — not invent a new wrapper.

## Decision

Adopt **Alternative B** from the plan with one refinement: the merge step calls the existing `baseline_update_from_breakdown` directly on each downloaded file, instead of synthesizing a single merged breakdown and re-applying. This preserves per-pipeline provenance (each run's stages get folded with their own weight) and avoids a second JSON schema we'd have to maintain.

**Data flow:**

```
pipeline run (any machine)
  └─ writes .claude/pipeline-artifacts/cost-breakdown.json
       └─ new step uploads it as `cost-breakdown-issue-<N>-run-<RUN_ID>` (retention 30d, always)
            └─ stays additive — combined logs upload is untouched

shipwright-optimize.yml (weekly cron)
  └─ gh run list → top 20 successful pipeline runs on main
       └─ gh run download --pattern 'cost-breakdown-*' → /tmp/cost-merge/run-<id>/
            └─ scripts/lib/cost/share.sh::cost_merge_apply
                 ├─ for each cost-breakdown.json found:
                 │    ├─ schema check: jq -e '.summary.total_cost_usd' (numeric)
                 │    └─ baseline_update_from_breakdown <file> ""
                 └─ emits cost.breakdown_merged event with count
                      └─ existing "Persist state to shipwright-data" step pushes baselines
```

**Error handling pattern:** identical to `cost_generate_breakdown` (`scripts/sw-cost.sh:619-634`) — per-file `try`/`catch` in `jq`, malformed files dropped with a `warn`, never fatal. `gh run download` is wrapped in `|| true` per run. `if-no-files-found: ignore` on the upload so pipelines that skip cost tracking don't trigger upload warnings (this addresses the prior "upload-artifact warns on missing files" failure pattern surfaced in historical context).

**Artifact name as semver contract:** `cost-breakdown-issue-<N>-run-<RUN_ID>`. Documented in `docs/cost-sharing.md` so external tooling can rely on it.

**Permissions:** add `actions: read` to the optimize job (not workflow-wide). This is the minimum scope needed for `gh run download` to pull artifacts from the pipeline workflow.

## Alternatives Considered

1. **Just upload, no consumer (Plan's Alt A)** — Pros: smallest blast radius, ~10 LOC in YAML. Cons: doesn't deliver "cross-machine optimization" from the issue title; baselines remain machine-local until someone manually downloads. *Rejected as insufficient.*

2. **Upload + synthesize a single merged JSON, then apply (Plan's Alt B as written)** — Pros: produces a human-inspectable merged artifact. Cons: invents a second JSON schema (`merged-cost-breakdown.json`) with its own aggregation semantics we'd have to keep in sync with `cost_generate_breakdown`; doubles the maintenance surface. *Rejected in favor of refined B.*

3. **Upload + apply per-file via existing `baseline_update_from_breakdown` (chosen)** — Pros: no new schema; reuses the function that already powers single-machine baselines so behavior stays identical; per-pipeline updates compose naturally via the existing rolling average. Cons: no single merged-snapshot file for human inspection (mitigation: emit a summary line + event with counts). *Chosen.*

4. **Push merged baseline as a checked-in file on main (Plan's Alt C)** — Pros: visible in PRs. Cons: noisy auto-commits every Sunday; baselines already live on `shipwright-data`. *Rejected.*

5. **Stream to a third-party telemetry service (Plan's Alt D)** — Out of scope, adds secret management and external coupling. *Rejected.*

## Implementation Plan

**Files to create:**
- `scripts/lib/cost/share.sh` — Bash 3.2 lib with `_COST_SHARE_LOADED` guard. Exposes `cost_merge_apply <input_dir>` which globs `${input_dir}/*/cost-breakdown.json`, validates `.summary.total_cost_usd` is numeric via `jq -e`, calls `baseline_update_from_breakdown` per valid file, emits a `cost.breakdown_merged` event with `files_total=`/`files_applied=` keys. Uses `info`/`success`/`warn` from the standard helpers.
- `scripts/sw-cost-share-test.sh` — hermetic harness mirroring `scripts/sw-cost-test.sh`. Overrides `baseline_dir()` via env to a temp dir so no `$HOME` writes leak. Fixtures live in a temp dir, never the repo.
- `docs/cost-sharing.md` — documents the artifact-name contract (`cost-breakdown-issue-<N>-run-<RUN_ID>`), schema reference pointing at `scripts/sw-cost.sh:667-691`, retention (30 days), consumer pattern, and opt-out via repo variable `SHIPWRIGHT_SKIP_COST_ARTIFACT`.

**Files to modify:**
- `.github/workflows/shipwright-pipeline.yml` — insert a new `upload-artifact@v4` step immediately after the existing line 1313 with `if: always() && steps.claim_check.outputs.skip != 'true'`, `path: .claude/pipeline-artifacts/cost-breakdown.json`, `retention-days: 30`, `if-no-files-found: ignore`, `continue-on-error: true`. Combined upload stays.
- `.github/workflows/shipwright-optimize.yml` — add `actions: read` to the `optimize` job's `permissions:` block (job-scoped, not workflow-scoped); add a "Download recent cost-breakdown artifacts" step using `gh run list --workflow=shipwright-pipeline.yml --branch=main --status=completed --limit=20` piped to `gh run download --pattern 'cost-breakdown-*' || true`; add a "Merge cost breakdowns into baselines" step that sources `scripts/lib/cost/share.sh` and calls `cost_merge_apply /tmp/cost-merge`. Insert both between current "Restore persistent state" (line 35) and "Run self-optimization" (line 54). The existing "Persist state to shipwright-data branch" step (line 70) needs no changes.
- `scripts/sw-cost.sh` — add `source "$SCRIPT_DIR/lib/cost/share.sh"` near the existing baselines source line; add `merge <dir>` subcommand to the CLI dispatcher and update the usage block. Strictly for local debugging.

**Files NOT in the plan that may need touching (check during implementation):**
- `package.json::scripts.test` — only if `sw-cost-share-test.sh` isn't auto-discovered. The repo's pattern is per-script harnesses chained from `npm test`; mirror whatever `sw-cost-test.sh` does.

**Dependencies:** none new. Uses `jq`, `gh` CLI (already installed on `ubuntu-latest`), existing helpers.

**Risk areas:**
- *Concurrent runs / artifact name collisions:* Mitigated — `${{ github.run_id }}` is unique per workflow run.
- *Malformed `cost-breakdown.json` from old runs:* Per-file `jq -e` schema check; drops with `warn`, never aborts. Same pattern as `cost_generate_breakdown:619-634`.
- *`gh run download` rate limits or partial failures:* `|| true` per run, hard cap at 20 runs/week. Worst case: optimize falls back to existing baselines.
- *`actions: read` privilege creep:* Scope to the `optimize` job only with an inline comment referencing #460.
- *Storage cost of 30-day retention:* `cost-breakdown.json` is small (~1-10 KB); 30d × weekly pipelines is well under 1 MB total. Acceptable.
- *External consumers depending on artifact name later:* Documented in `docs/cost-sharing.md` as a stable contract.
- *Past failure pattern "upload-artifact warns on missing files":* Addressed by `if-no-files-found: ignore` (this is the specific value that suppresses the warn, not `warn` or `error`).

## Validation Criteria

- [ ] `bash scripts/sw-cost-share-test.sh` exits 0 with all assertions passing — covers happy path (3 files, summed correctly), malformed-JSON drop, schema-violation drop, empty input dir, and verification that `baseline_update_from_breakdown` is invoked exactly once per valid file (assert via a stub that increments a counter file).
- [ ] `bash scripts/sw-cost-test.sh` exits 0 — no regression in existing cost tests.
- [ ] `npm test` exits 0.
- [ ] `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh` exits 0.
- [ ] `grep -q 'cost-breakdown-issue-' .github/workflows/shipwright-pipeline.yml` succeeds.
- [ ] `grep -q 'cost_merge_apply' .github/workflows/shipwright-optimize.yml` succeeds.
- [ ] `grep -q 'actions: read' .github/workflows/shipwright-optimize.yml` succeeds and the permission is job-scoped (under `jobs.optimize.permissions`, not top-level).
- [ ] `bash -c 'source scripts/lib/cost/share.sh && type cost_merge_apply'` reports a function.
- [ ] `test -f docs/cost-sharing.md && grep -q 'cost-breakdown-issue-' docs/cost-sharing.md` succeeds.
- [ ] First post-merge pipeline run produces a discoverable artifact named `cost-breakdown-issue-<N>-run-<RUN_ID>` (verify in Actions UI; cannot be tested locally).
- [ ] First post-merge optimize cron logs `cost.breakdown_merged` with `files_applied >= 1` and the resulting baseline diff appears on the `shipwright-data` branch.
- [ ] Cumulative branch diff touches only: `.github/workflows/shipwright-pipeline.yml`, `.github/workflows/shipwright-optimize.yml`, `scripts/lib/cost/share.sh`, `scripts/sw-cost-share-test.sh`, `scripts/sw-cost.sh`, `docs/cost-sharing.md`, and optionally `package.json`.
