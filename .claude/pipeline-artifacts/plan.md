# Issue #460 — Upload cost-breakdown.json as GitHub Actions Artifact for Cross-Machine Optimization

## Context Reset

The issue body claims a WIP branch with partial files (`scripts/lib/cost/share.sh`,
`scripts/lib/cost/merge.sh`, `scripts/sw-cost-share-test.sh`, `docs/cost-sharing.md`,
and artifact upload steps in `.github/workflows/shipwright-pipeline.yml`). **None
of these files exist on `shipwright/issue-460`.** The directory
`.claude/pipeline-artifacts/issue-460/` referenced by the issue also does not
exist. This plan therefore starts from scratch — not from the (non-existent) WIP.

What **does** already exist on `main`/this branch:

- `scripts/sw-cost.sh::cost_generate_breakdown` writes `cost-breakdown.json` to
  `<artifacts_dir>` on every pipeline exit path (`scripts/sw-pipeline.sh:1200`).
- The pipeline workflow uploads the entire `.claude/pipeline-artifacts/`
  directory as one combined artifact `pipeline-logs-issue-N-run-X`
  (`.github/workflows/shipwright-pipeline.yml:1302-1313`). Combined uploads are
  not discoverable by name and bundle cost data with logs.
- `.github/workflows/shipwright-optimize.yml` runs weekly and restores per-stage
  baselines from the `shipwright-data` orphan branch. It does **not** currently
  consume cost-breakdown.json artifacts from other machines/runs.
- `scripts/lib/cost/baselines.sh::cost_baseline_update` already knows how to
  fold a single cost-breakdown.json into rolling per-stage baselines.

## Goal (Minimum Viable)

Upload `cost-breakdown.json` as a **separately named, discoverable** GitHub
Actions artifact so the `shipwright-optimize` workflow (and any external
analytics) can fetch cost data from recent pipeline runs across machines
without re-downloading the entire log bundle, and fold them into the shared
baselines.

## Socratic Refinement (Self-Answered)

**Minimum viable change?** A single new `upload-artifact@v4` step in
`shipwright-pipeline.yml` that uploads `cost-breakdown.json` under a
deterministic name (`cost-breakdown-issue-N-run-X`). Everything else
(cross-machine merge, optimize-workflow consumer, helper script) is value-add
on top of the MVP.

**Implicit requirements not in the issue?**
1. The artifact must remain uploaded even when the pipeline fails (use
   `if: always()`), because cost data on failed runs is the most valuable for
   tuning.
2. Retention must outlive the optimize workflow cadence (weekly cron) — set to
   ≥30 days so a single missed Sunday doesn't lose data.
3. The optimize workflow needs a permission/auth path to download artifacts
   from recent runs of the pipeline workflow (`actions: read`).

**Acceptance criteria (derived):**
- After a pipeline run, a dedicated artifact named
  `cost-breakdown-issue-<N>-run-<RUN_ID>` exists with `cost-breakdown.json`
  inside it.
- The optimize workflow can download the N most-recent such artifacts and
  produce a merged baseline update visible in `~/.shipwright/baselines/` on the
  `shipwright-data` branch.
- A new shell-level test exercises the merge logic without touching the
  network or real GH artifacts.
- Documentation explains the contract (artifact name, schema, retention) so
  external tooling can rely on it.

## Design Alternatives Considered

| # | Approach | Pros | Cons | Verdict |
|---|----------|------|------|---------|
| A | **Just add a second `upload-artifact` step** for `cost-breakdown.json` only; no merge/consumer code. | Smallest blast radius; zero new code paths. | Doesn't actually deliver cross-machine *optimization* — only cross-machine *availability*. Issue title explicitly says "for cross-machine optimization." | Necessary but not sufficient. |
| B | **(A) + add a download/merge step inside `shipwright-optimize.yml`** that calls a new `scripts/lib/cost/share.sh::cost_merge_breakdowns` helper. | Delivers the full goal; reuses existing `cost_baseline_update`. | Adds ~150 LOC + a workflow step + tests. | **Chosen.** |
| C | Same as B but push merged baseline back to `main` as a checked-in file. | Visible in PRs. | Causes auto-commits and noisy diffs on every weekly run; baselines already persist on `shipwright-data`. | Rejected. |
| D | Use `gh api` to push cost-breakdown to a third-party telemetry service. | Real-time, queryable. | Adds external dependency, secret management, network coupling, and is way out of scope for #460. | Rejected. |

**Chosen: B.** Smallest implementation that closes the loop the issue asks for
(upload + a consumer that does the cross-machine merge). Reuses the existing
baseline machinery so the new code is glue, not logic.

## Files to Modify

| Path | Action | Purpose |
|------|--------|---------|
| `.github/workflows/shipwright-pipeline.yml` | **Modify** | Add dedicated `upload-artifact` step for `cost-breakdown.json` after the existing "Upload pipeline logs and artifacts" step. |
| `.github/workflows/shipwright-optimize.yml` | **Modify** | Add `actions: read` permission, a `download-artifact` step using `gh run download` (or `actions/download-artifact@v4` with `workflow` filter) for the most-recent N pipeline runs, and a step that invokes `cost_merge_breakdowns`. |
| `scripts/lib/cost/share.sh` | **Create** | New library with `cost_merge_breakdowns <dir-of-json-files> <out-file>` and `cost_apply_merged_to_baselines <merged.json>` functions. Wraps existing `cost_baseline_update`. |
| `scripts/sw-cost-share-test.sh` | **Create** | Hermetic tests that feed crafted cost-breakdown.json fixtures into the merge function and assert the merged output + baseline updates. |
| `scripts/sw-cost.sh` | **Modify** | Source `lib/cost/share.sh` (single `source` line) so `shipwright cost merge` is wired as a subcommand for local debugging. |
| `docs/cost-sharing.md` | **Create** | Documents the artifact-name contract, schema, retention policy, and how external tooling can consume it. |
| `package.json` | **Modify** | Add `sw-cost-share-test.sh` invocation to the `test` script alongside other shell test harnesses (only if the existing pattern bundles them; otherwise skip). |

## Implementation Steps

1. **Read the existing artifact upload block** in
   `.github/workflows/shipwright-pipeline.yml` (lines 1302-1313) and add a new
   step **immediately after** it:
   ```yaml
   - name: Upload cost breakdown (always)
     if: always() && steps.claim_check.outputs.skip != 'true'
     uses: actions/upload-artifact@v4
     with:
       name: cost-breakdown-issue-${{ github.event.inputs.issue_number || github.event.issue.number }}-run-${{ github.run_id }}
       path: .claude/pipeline-artifacts/cost-breakdown.json
       retention-days: 30
       if-no-files-found: ignore
     continue-on-error: true
   ```
   Keep the existing combined log upload — this is additive.

2. **Create `scripts/lib/cost/share.sh`** (Bash 3.2 compatible) following the
   conventions in `scripts/lib/cost/baselines.sh`:
   - Idempotent guard (`_COST_SHARE_LOADED`).
   - `cost_merge_breakdowns(input_dir, out_file)`:
     - Globs `${input_dir}/*/cost-breakdown.json` (one file per downloaded
       artifact subdir).
     - Concatenates `.by_stage` arrays via `jq -s` with `group_by(.stage)` and
       running-sum aggregation on `input_tokens`, `output_tokens`, `cost_usd`,
       `count`.
     - Skips files that fail schema check (must have `.summary.total_cost_usd`).
     - Emits one merged JSON written atomically (tmp + mv).
   - `cost_apply_merged_to_baselines(merged_file)`:
     - Iterates `.by_stage[]` and calls existing
       `cost_baseline_update "$merged_file" ""` once per per-issue if present.
   - Use `info`/`success`/`warn` helpers; emit
     `cost.breakdown_merged` events.

3. **Source the new lib from `scripts/sw-cost.sh`** alongside the existing
   `source "$SCRIPT_DIR/lib/cost/baselines.sh"` line and add a `merge`
   subcommand to the dispatcher so the function is reachable from CLI for
   local debugging. Update the usage block.

4. **Create `scripts/sw-cost-share-test.sh`** mirroring the harness in
   `scripts/sw-cost-test.sh`:
   - `setup_env`: creates a temp dir with 3 fixture subdirs, each containing a
     synthetic `cost-breakdown.json` with overlapping stages.
   - Test 1: merge of 3 files produces correct summed totals.
   - Test 2: merge of 1 malformed file + 2 valid files produces only the valid
     totals (no abort).
   - Test 3: `cost_apply_merged_to_baselines` updates the per-issue baseline
     JSON.
   - Test 4: empty input dir produces an empty-but-valid merged JSON.
   - Test 5: schema validator rejects a file missing `.summary.total_cost_usd`.

5. **Modify `.github/workflows/shipwright-optimize.yml`**:
   - Add `actions: read` to permissions.
   - Between "Restore persistent state" and "Run self-optimization", add:
     ```yaml
     - name: Download recent cost-breakdown artifacts
       run: |
         mkdir -p /tmp/cost-merge
         # Find the 20 most-recent successful pipeline runs and download their
         # cost-breakdown artifact (one per run, ignore missing).
         gh run list \
           --workflow=shipwright-pipeline.yml \
           --branch=main \
           --status=completed \
           --limit=20 \
           --json databaseId \
           --jq '.[].databaseId' | while read -r run_id; do
             gh run download "$run_id" \
               --dir "/tmp/cost-merge/run-$run_id" \
               --pattern 'cost-breakdown-*' 2>/dev/null || true
           done
     - name: Merge cost breakdowns and update baselines
       run: |
         source scripts/lib/cost/share.sh
         cost_merge_breakdowns /tmp/cost-merge ~/.shipwright/baselines/merged-cost-breakdown.json
         cost_apply_merged_to_baselines ~/.shipwright/baselines/merged-cost-breakdown.json
     ```
   - The existing "Persist state to shipwright-data branch" step already pushes
     `~/.shipwright/baselines/` — no change needed there.

6. **Create `docs/cost-sharing.md`** with:
   - Artifact name contract:
     `cost-breakdown-issue-<N>-run-<RUN_ID>` (downloadable for 30 days).
   - JSON schema reference (point at `scripts/sw-cost.sh:667-691`).
   - Consumer pattern (the optimize workflow snippet).
   - How to opt out (skip step via repo variable `SHIPWRIGHT_SKIP_COST_ARTIFACT`).

7. **Add hermetic test harness to test runner.** Check if
   `scripts/sw-pipeline-test.sh` or `package.json::scripts.test` chains the
   per-script harnesses. If `npm test` already discovers `scripts/sw-*-test.sh`,
   nothing to do; otherwise add an explicit hook.

8. **Run validation locally**:
   - `bash scripts/sw-cost-share-test.sh` — new tests must pass.
   - `bash scripts/sw-cost-test.sh` — must still pass (no regression).
   - `npm test` — full suite green.
   - `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh` — clean.
   - YAML lint the two workflow files via `yamllint -d "{rules: {line-length: disable}}"` (best effort).

## Task Checklist

- [ ] Task 1: Add dedicated `upload-artifact` step for `cost-breakdown.json` in `shipwright-pipeline.yml`.
- [ ] Task 2: Create `scripts/lib/cost/share.sh` with `cost_merge_breakdowns` and `cost_apply_merged_to_baselines`.
- [ ] Task 3: Source `lib/cost/share.sh` from `scripts/sw-cost.sh` and add a `merge` subcommand.
- [ ] Task 4: Create `scripts/sw-cost-share-test.sh` with 5 hermetic test cases.
- [ ] Task 5: Add `actions: read` permission + download-and-merge steps to `shipwright-optimize.yml`.
- [ ] Task 6: Create `docs/cost-sharing.md` documenting the artifact contract and consumer pattern.
- [ ] Task 7: Wire `sw-cost-share-test.sh` into `npm test` if needed.
- [ ] Task 8: Run `bash scripts/sw-cost-share-test.sh` — green.
- [ ] Task 9: Run `npm test` — full suite green; no regressions in existing cost tests.
- [ ] Task 10: Run `shellcheck` on new shell files — clean.

**Dependencies:** Task 2 blocks Tasks 3, 4, 5. Task 4 blocks Task 8. Task 7
(if needed) blocks Task 9.

## Risk Analysis

| Risk | What Breaks | Mitigation |
|------|-------------|------------|
| Concurrent pipeline runs upload artifacts with overlapping names. | `upload-artifact@v4` errors on duplicate names within the same run. | The name includes `${{ github.run_id }}` which is unique per workflow run. Cross-run collisions are impossible. |
| `gh run download` rate-limit on optimize cron. | Optimize workflow fails. | Loop uses `|| true` per run and is capped at 20 runs. Falls back silently to existing baselines if all downloads fail. |
| Malformed `cost-breakdown.json` from an old pipeline run poisons the merge. | `jq` aborts → empty merged file → baselines unchanged. | Per-file `try`/`catch` in `cost_merge_breakdowns` (same pattern as `cost_generate_breakdown` at `scripts/sw-cost.sh:619-634`); malformed files are dropped, not fatal. |
| `actions: read` permission propagates more privilege than needed. | Theoretical sensitivity. | Scope it to the optimize job only, not workflow-wide; add comment in YAML linking back to issue #460. |
| Artifact retention default (90 days) wastes storage. | Storage cost. | Pin `retention-days: 30` explicitly. |
| External consumers come to depend on the artifact name; renaming later breaks them. | API contract leak. | Document the contract in `docs/cost-sharing.md` and treat the artifact name as semver-stable. |

## Definition of Done

- [ ] `bash scripts/sw-cost-share-test.sh` exits 0 with all assertions passing {auto:other:bash scripts/sw-cost-share-test.sh}
- [ ] `bash scripts/sw-cost-test.sh` exits 0 — no regression in existing cost tests {auto:other:bash scripts/sw-cost-test.sh}
- [ ] `npm test` exits 0 {auto:tests}
- [ ] `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh` exits 0 {auto:lint}
- [ ] Branch diff shows `upload-artifact` step in `.github/workflows/shipwright-pipeline.yml` with `name: cost-breakdown-issue-...` {auto:other:grep -q 'cost-breakdown-issue-' .github/workflows/shipwright-pipeline.yml}
- [ ] Branch diff shows download/merge steps wired into `shipwright-optimize.yml` {auto:other:grep -q 'cost_merge_breakdowns' .github/workflows/shipwright-optimize.yml}
- [ ] `scripts/lib/cost/share.sh` exports `cost_merge_breakdowns` (sourceable in subshell) {auto:other:bash -c 'source scripts/lib/cost/share.sh && type cost_merge_breakdowns'}
- [ ] `docs/cost-sharing.md` exists and documents the artifact-name contract {auto:other:test -f docs/cost-sharing.md && grep -q 'cost-breakdown-issue-' docs/cost-sharing.md}
- [ ] `scripts/sw-cost.sh` sources the new lib and accepts a `merge` subcommand {auto:other:grep -q 'lib/cost/share.sh' scripts/sw-cost.sh}
- [ ] Cumulative branch diff touches only the files listed in this plan {auto:diff}

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests (5):** All in `scripts/sw-cost-share-test.sh` — exercise
  `cost_merge_breakdowns` and `cost_apply_merged_to_baselines` in isolation
  with synthetic JSON fixtures. No network, no real `gh` CLI.
- **Integration tests (0 new):** The existing `scripts/sw-cost-test.sh`
  baseline tests cover the `cost_baseline_update` path we reuse — re-running
  them validates the integration boundary.
- **E2E tests (0):** GitHub Actions workflows cannot be unit-tested locally
  without `act`/`nektos`. The artifact upload and download steps are validated
  by the first real CI run after merge — covered in PR description, not in
  this DoD.

### Coverage Targets
- 100% branch coverage of `cost_merge_breakdowns` (happy path, malformed file,
  empty dir, single file, multiple files with overlapping stages).
- 100% function coverage of new code in `scripts/lib/cost/share.sh`.
- No new coverage requirement for workflow YAML (untestable locally).

### Critical Paths to Test
1. **Happy path:** 3 valid cost-breakdown.json files with overlapping stages
   → merged output has one entry per unique stage with summed tokens/cost.
2. **Error case A — malformed input:** One file with invalid JSON syntax →
   merge succeeds with the remaining 2 files; warn emitted; no abort.
3. **Error case B — schema violation:** One file missing
   `.summary.total_cost_usd` → file is skipped; merge succeeds.
4. **Edge case A — empty input dir:** No files found → produces a valid empty
   merged JSON with `summary.total_cost_usd == 0`.
5. **Edge case B — baseline application:** After merge, calling
   `cost_apply_merged_to_baselines` updates
   `${HOME}/.shipwright/baselines/stage-costs.json` with new running averages
   for each merged stage.
