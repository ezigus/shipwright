# Plan — Issue #460: Upload cost-breakdown.json as GHA Artifact for Cross-Machine Optimization

## Current State (verified, not assumed)

The WIP branch `shipwright/issue-460` already contains the bulk of the
implementation. Inventory at the start of this run:

| Path | Status | Lines |
|---|---|---|
| `scripts/lib/cost/share.sh` | ✅ present | 264 |
| `scripts/sw-cost-share-test.sh` | ✅ present | 311 |
| `scripts/sw-cost.sh` | ✅ modified (sources share.sh, `merge` subcommand) | +73 |
| `.github/workflows/shipwright-pipeline.yml` | ✅ modified (dedicated upload step) | +14 |
| `.github/workflows/shipwright-optimize.yml` | ✅ modified (download + merge job) | +54 net |
| `docs/cost-sharing.md` | ✅ present | 117 |
| `scripts/lib/test-helpers.sh` | ✅ modified (+6) | |
| `scripts/sw-gha-pipeline-test.sh` | ✅ modified (asserts 2 upload-artifact steps) | |
| `scripts/sw-pipeline-test.sh`, `scripts/sw-lib-pipeline-stages-test.sh` | ✅ touched | |

The previous pipeline attempt (run `26068114437`) failed at the **test** stage
after build/test self-healing exhausted. The implementation is on disk; the
remaining work is **verification + fixing whatever the test stage flagged**,
not greenfield construction. This plan therefore optimizes for resume-from-build,
not start-from-scratch.

## Goal (Minimum Viable, re-stated for this run)

Land the existing WIP cleanly: every Definition-of-Done verification tag in
`.claude/pipeline-artifacts/issue-460/dod.md` must exit 0, with no regression
in the existing cost test suite.

## Socratic Refinement (Self-Answered)

**Minimum viable change for this run?** Run the existing test harnesses,
diagnose any failures from the prior test-stage exit, fix only those, and
re-validate. No new files. Do not re-architect.

**Implicit requirements?**
1. `npm test` must remain green. The previous run's failure note says
   "build→test self-healing exhausted" — at least one test was failing at
   exit. Read the failing test names from the iteration log, fix the code or
   the test (preferring code), and re-verify.
2. New shell files must pass `shellcheck` because the existing CI runs it on
   `scripts/lib/cost/**.sh` (verified via `grep -r shellcheck scripts/` if
   needed).
3. The dedicated upload step MUST coexist with the existing combined
   `pipeline-logs-*` upload — purely additive, no removal of the old step.
   `sw-gha-pipeline-test.sh` was updated in commit `9f5743b` to assert 2
   upload-artifact steps; do not undo that.
4. Bash 3.2 compatibility (no `declare -A`, no `readarray`, no `${var,,}`).

**Acceptance criteria (derived from DoD already on disk):** see DoD section
below — copied verbatim from `.claude/pipeline-artifacts/issue-460/dod.md`
with verification tags preserved.

## Design Alternatives Considered

| # | Approach | Pros | Cons | Verdict |
|---|---|---|---|---|
| A | **Resume from build using existing WIP** — run tests, fix failures, ship. | Smallest blast radius; reuses 692 lines already written and reviewed across multiple prior loop iterations; honors the issue's explicit "should resume from build" directive. | Inherits any latent design flaws in the WIP. | **Chosen.** |
| B | Discard WIP and re-implement following the existing `issue-460/plan.md`. | Clean slate. | Throws away ~700 LOC of working code; ignores the issue's resume directive; doubles the cost. | Rejected. |
| C | Merge the dedicated-artifact upload only (skip the optimize-side consumer). | Smaller change. | Doesn't deliver the cross-machine *optimization* the issue title demands; the consumer is already written. | Rejected — would regress committed work. |

## Files to Modify (in this run)

Conservative — only touch what's needed to drive DoD checks to green. The
implementation files below are **already present** on the branch; this run
modifies them only if test/lint failures point at them.

| Path | Action | Trigger |
|---|---|---|
| `scripts/lib/cost/share.sh` | Modify (only if shellcheck/test failures) | DoD `auto:lint` or `auto:other:bash scripts/sw-cost-share-test.sh` fails |
| `scripts/sw-cost-share-test.sh` | Modify (only if assertions misaligned with `share.sh`) | Same as above |
| `scripts/sw-cost.sh` | Modify (only if `merge` subcommand misdispatches) | DoD grep check fails |
| `scripts/sw-gha-pipeline-test.sh` | Modify (only if it asserts the wrong count of upload steps) | `sw-gha-pipeline-test.sh` fails |
| `scripts/sw-lib-pipeline-stages-test.sh` | Modify (only if regression there) | `npm test` regression |
| `docs/cost-sharing.md` | Modify (only if `cost-breakdown-issue-` marker absent) | DoD grep check fails |
| `.github/workflows/shipwright-pipeline.yml` | Leave as-is unless build-time validation flags | DoD grep already passes (1 match) |
| `.github/workflows/shipwright-optimize.yml` | Leave as-is unless build-time validation flags | DoD grep already passes (1 match) |

**Hard rule:** the cumulative branch diff at PR time must touch only files
listed in `.claude/pipeline-artifacts/issue-460/plan.md` **plus** the prior
WIP commits' files (already permitted). No surprise files.

## Implementation Steps

1. **Inspect the failure note**
   (`.claude/pipeline-artifacts/issue-460/failure-note.md`) and any
   `error-summary.json` / `progress.md` left over from run 26068114437.
   Identify the precise failing test name(s).
2. **Run the targeted test first**, not the full suite — start with
   `bash scripts/sw-cost-share-test.sh`, then `bash scripts/sw-cost-test.sh`,
   then whatever specific suite the failure note named (typically
   `scripts/sw-gha-pipeline-test.sh` or `scripts/sw-pipeline-test.sh`).
3. **Diagnose and fix the code path** the failing test exercises. Preference
   order: fix the production code; fix the test only if its assertion was
   wrong (e.g., off-by-one in expected upload-artifact step count).
4. **Re-run the targeted test** until green. Then run the full `npm test`
   suite once to confirm no regression elsewhere.
5. **Run `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh`.**
   If any warnings, fix them (these are the new shell files; the rest of the
   tree is out of scope).
6. **Run each DoD `{auto:other:...}` command literally** to confirm the
   verification harness will report PASS. Specifically:
   - `bash -c 'source scripts/lib/cost/share.sh && type cost_merge_breakdowns'`
   - `grep -q 'cost-breakdown-issue-' .github/workflows/shipwright-pipeline.yml`
   - `grep -q 'cost_merge_breakdowns' .github/workflows/shipwright-optimize.yml`
   - `test -f docs/cost-sharing.md && grep -q 'cost-breakdown-issue-' docs/cost-sharing.md`
   - `grep -q 'lib/cost/share.sh' scripts/sw-cost.sh`
7. **Inspect the cumulative diff** vs `origin/main` and confirm it only
   touches files listed in the inventory table above. If any unexpected file
   appears (e.g., a stray `.claude/helpers/*` modification from the resume
   bookkeeping), either revert it or explicitly justify it as scope.
8. **Hand off to compound_quality / PR stages** with all DoD signals green.

## Task Checklist

- [ ] Task 1: Read failure-note.md and any test logs from run 26068114437; record which test(s) failed last.
- [ ] Task 2: Run `bash scripts/sw-cost-share-test.sh` standalone; record PASS/FAIL.
- [ ] Task 3: Run `bash scripts/sw-cost-test.sh` standalone; verify no regression.
- [ ] Task 4: Run `bash scripts/sw-gha-pipeline-test.sh` standalone (this is the test edited for the dedicated upload-artifact step).
- [ ] Task 5: For each failing test, fix the underlying code (or test if the test was wrong); re-run only that suite to green.
- [ ] Task 6: Run `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh`; resolve any new warnings.
- [ ] Task 7: Run `npm test` once end-to-end; confirm full suite green.
- [ ] Task 8: Execute every `{auto:other:...}` DoD command literally; confirm each exits 0.
- [ ] Task 9: `git diff --stat origin/main...HEAD` — confirm file list matches the inventory table; no surprise files.
- [ ] Task 10: Update PR description / progress comment with summary of what was verified.

**Dependencies:** Task 1 blocks Tasks 2-5. Task 5 blocks Task 7. Task 7 blocks Task 8.

## Risk Analysis

| Risk | What Breaks | Mitigation |
|---|---|---|
| Previous test-stage failure is rooted in a still-broken test fixture in `sw-cost-share-test.sh`. | `npm test` stays red; loop exhausts. | Read the actual failure output before changing code. Fix the most-specific failing assertion first; do not blanket-rewrite the test harness. |
| `sw-gha-pipeline-test.sh` was updated to expect 2 upload-artifact steps; a future workflow refactor could drop one. | False positive failure of an already-green test. | Re-run that exact test first and compare actual vs expected step count before touching anything. |
| Loop-iteration uncommitted changes (the `.claude/helpers/*` modifications shown in `git status`) drift into the PR. | Diff balloons; scope guardrail trips. | Inspect uncommitted files; if they are pipeline bookkeeping (state snapshots, intelligence cache), discard or keep as `[skip ci]` chore commits rather than mixing into the feature commit. |
| Shellcheck flags pre-existing issues in `scripts/lib/cost/baselines.sh` (not modified by this issue). | False scope creep. | Run shellcheck only against the **new** files (`share.sh`, `sw-cost-share-test.sh`); ignore warnings from files we did not touch. |
| GHA `actions: read` permission missing on optimize job → `gh run download` fails in real CI. | Cross-machine merge silently does nothing. | Verify the optimize workflow YAML has `permissions: { actions: read }` scoped to the right job. Cannot fully test locally without `act`; document as a post-merge validation in PR description. |
| Concurrency: two pipelines on different machines for different issues both upload artifacts. | None — names include `${{ github.run_id }}` which is globally unique. | No mitigation needed; documented. |

## Definition of Done

(Copied verbatim from `.claude/pipeline-artifacts/issue-460/dod.md` so the
auto-validator can find them in this canonical location too. Bounded to 10
items per harness contract.)

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
- **Unit tests (~5, already written):** `scripts/sw-cost-share-test.sh` — exercises `cost_merge_breakdowns`, `cost_apply_merged_to_baselines`, `cost_share_validate_breakdown` against synthetic fixtures. Hermetic, no network, no real `gh` CLI.
- **Integration tests (existing, reused):** `scripts/sw-cost-test.sh` validates the baseline-update path the new code reuses. `scripts/sw-gha-pipeline-test.sh` validates the YAML structure of the upload-artifact step.
- **E2E tests (0 new, by design):** GitHub Actions workflows are validated by the first real CI run after merge; documented in PR description, not in DoD. `act`/`nektos` not introduced as a dep for this issue.

### Coverage Targets
- 100% branch coverage of `cost_merge_breakdowns` (happy path, malformed JSON, schema violation, empty dir, single file, multiple files with overlapping stages) — already met by the 5 cases in `sw-cost-share-test.sh`.
- No new coverage requirement for YAML (untestable locally without `act`).
- No new coverage requirement for code outside `scripts/lib/cost/share.sh`.

### Critical Paths to Test
1. **Happy path:** 3 valid `cost-breakdown.json` files with overlapping stages → merged output sums tokens and cost_usd per stage.
2. **Error case A — invalid JSON:** one file is malformed → merge succeeds with the remaining valid files; `warn` emitted; no abort.
3. **Error case B — schema violation:** one file missing `.summary.total_cost_usd` → skipped; merge succeeds.
4. **Edge case A — empty input dir:** no files found → emits a valid empty merged JSON.
5. **Edge case B — baseline application:** `cost_apply_merged_to_baselines` updates rolling baseline JSON for each merged stage.

## Alternatives Considered (summary)

See the "Design Alternatives Considered" table above. **A (resume from existing
WIP)** chosen over **B (re-implement)** to honor the issue directive and avoid
discarding committed work, and over **C (upload-only, skip consumer)** because
the cross-machine *optimization* phrasing in the issue title requires the
consumer side to exist.
