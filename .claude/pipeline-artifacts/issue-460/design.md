WIP verified on disk. Producing the ADR now.

# Design: Upload cost-breakdown.json as GitHub Actions artifact for cross-machine optimization

## Context

Each shipwright pipeline run generates `.claude/pipeline-artifacts/cost-breakdown.json` (per-stage token/cost telemetry), but today it is bundled into the omnibus `pipeline-logs-*` artifact and never read back. The `shipwright-optimize` workflow runs on a different machine/clock and only sees the local `~/.shipwright/baselines/` for that runner — so cost baselines drift per-runner and the system has no cross-run, cross-machine view of where tokens are being spent. Issue #460 asks for a dedicated, discoverable artifact channel so the optimize job can aggregate breakdowns across runs and feed merged stats back into rolling baselines.

Constraints we have to respect:
- **Bash 3.2 compatibility** (`scripts/lib/*` runs on macOS default bash) — no `declare -A`, no `readarray`, no `${var,,}`. Confirmed in `.ai-standards/generated/claude-instructions.md` and `scripts/lib/cost/baselines.sh`.
- **Additive workflow change** — `sw-gha-pipeline-test.sh` was tightened (commit `9f5743b`) to assert **two** `upload-artifact` steps; the existing `pipeline-logs-*` upload must stay.
- **Artifact name must be globally unique** — keyed on `${{ github.run_id }}` and the issue number so concurrent pipelines on different issues/machines cannot collide.
- **Hermetic local tests** — no `act`, no network, no real `gh`. The optimize-side download path is validated structurally (grep on YAML), not end-to-end.
- **DoD already declared on disk** at `.claude/pipeline-artifacts/issue-460/dod.md` (10 items, every implementation file in scope already exists).
- **Resume-from-build directive** — `run 26068114437` failed in the test stage after build/test self-heal exhausted; the implementation is on disk, the work is to verify and fix the specific failing assertion, not to re-implement.

## Decision

**Resume the existing WIP (Alternative A in the plan), do not re-architect.** The branch already carries the full design:

**Data flow (memorize this; it is the contract the tests pin):**

```
pipeline run on machine X
  → scripts/sw-cost.sh writes .claude/pipeline-artifacts/cost-breakdown.json
  → shipwright-pipeline.yml step "Upload cost-breakdown artifact" uploads as
        cost-breakdown-issue-<N>-run-<run_id>
  ─ (artifacts retained per GHA default) ─
shipwright-optimize.yml run on machine Y (scheduled / dispatch)
  → gh run download with pattern "cost-breakdown-issue-*"
  → sources scripts/lib/cost/share.sh
  → cost_merge_breakdowns <dir> <out.json>
        (validates each file with cost_share_validate_breakdown; skips invalid;
         sums tokens + cost_usd per stage across files)
  → cost_apply_merged_to_baselines <merged.json>
        (writes per-stage rolling baselines into ~/.shipwright/baselines/)
```

**Library boundary:** all merge/validation logic lives in `scripts/lib/cost/share.sh` and is exercised by the hermetic suite `scripts/sw-cost-share-test.sh`. The CLI surface is `scripts/sw-cost.sh merge <dir> <out>` which sources the lib and dispatches — keeping the workflow YAML thin and testable.

**Error handling — degrade-don't-abort:** a malformed JSON file or a schema violation in one downloaded breakdown must not fail the merge; `cost_share_validate_breakdown` returns non-zero, `cost_merge_breakdowns` `warn`s and skips it. Empty input directory produces a valid empty merged JSON. This is the contract the unit test pins.

**Concurrency:** artifact names embed `${{ github.run_id }}` (globally unique), so two pipelines on different machines for different issues cannot collide. No locking needed.

**Permissions:** the optimize job must declare `permissions: { actions: read }` to use `gh run download` across the workflow boundary — not fully testable locally; flagged as a post-merge validation in the PR description rather than blocking DoD.

## Alternatives Considered

1. **Resume from existing WIP (chosen).** — Pros: zero greenfield, reuses ~700 LOC already written and reviewed across prior loop iterations, honors the issue's explicit resume directive, smallest blast radius. Cons: inherits latent design flaws in the WIP; mitigated by running the full DoD harness literally before PR.
2. **Discard WIP, re-implement from plan.** — Pros: clean slate, no inherited bugs. Cons: throws away committed work, doubles cost, ignores the resume directive, and the failing signal (test-stage assertion) is cheaper to fix than to recreate.
3. **Upload-only, skip the optimize-side consumer.** — Pros: smallest possible diff. Cons: doesn't deliver the "cross-machine *optimization*" the issue title demands; `cost_merge_breakdowns` is already written and tested — leaving the producer half-wired would regress committed work.
4. **Stash everything in `~/.shipwright/costs.json` and skip artifacts entirely.** — Pros: no GHA dependency. Cons: that file is per-runner; "cross-machine" is exactly what artifacts solve. Rejected on first principles.

## Implementation Plan

**Files to create:** none. All implementation files are already present on `shipwright/issue-460`:
- `scripts/lib/cost/share.sh` (264 lines — exports `cost_share_validate_breakdown`, `cost_merge_breakdowns`, `cost_apply_merged_to_baselines`)
- `scripts/sw-cost-share-test.sh` (311 lines — 5 hermetic cases: happy path, invalid JSON, schema violation, empty dir, baseline application)
- `docs/cost-sharing.md` (117 lines — artifact-name contract + permissions note)

**Files to modify (only if a DoD check flags them — conservative, demand-driven):**
- `scripts/sw-cost.sh` — already sources `lib/cost/share.sh` and adds the `merge` subcommand; touch only if dispatch grep fails.
- `.github/workflows/shipwright-pipeline.yml` — already has the dedicated upload step at line 1304/1321 with name `cost-breakdown-issue-${issue}-run-${run_id}`; leave as-is.
- `.github/workflows/shipwright-optimize.yml` — already wires `cost_merge_breakdowns /tmp/cost-merge ~/.shipwright/baselines/merged-cost-breakdown.json` (line 100); leave as-is.
- `scripts/sw-gha-pipeline-test.sh` — already asserts 2 upload-artifact steps; touch only if the count assertion is off.
- `scripts/sw-cost-share-test.sh` — modify only to align an assertion that points at a real bug in `share.sh`; prefer fixing the lib.

**Hard scope rule:** the cumulative diff vs `origin/main` at PR time touches only the files in the inventory table in the plan. Any stray `.claude/helpers/*` or pipeline bookkeeping edits get either reverted or split into a separate `[skip ci]` chore commit before PR.

**Dependencies:** none new. `jq` is already a project dependency (used in `scripts/lib/cost/baselines.sh`). `gh` is provided by the GHA runner. No new npm packages.

**Risk areas:**
- **`cost_merge_breakdowns` JSON aggregation** — bash + `jq` reduce loops are easy to get wrong on edge inputs (empty dir, single file, overlapping stage names). Mitigated by the 5 explicit unit cases.
- **YAML drift** — a future workflow refactor could drop one of the two `upload-artifact` steps and break `sw-gha-pipeline-test.sh`. Mitigated by running that suite first in this run before touching anything.
- **GHA `actions: read` permission** — required for cross-workflow `gh run download`; missing this fails silently in real CI (returns empty dir, merge produces empty output, optimize is a no-op). Cannot be reproduced locally; documented as a post-merge smoke check.
- **Build-loop bookkeeping leaks** — `git status` shows uncommitted modifications in `.claude/helpers/*` and `.claude/pipeline-state.md`. These must not land in the feature PR; either revert or commit separately as `[skip ci]`.
- **Bash 3.2 trap** — easy to regress to bash-4-isms when editing `share.sh`. Mitigated by `shellcheck` on the two new files (it doesn't catch all bash-4-isms but catches most associative-array usage).

## Validation Criteria

Every item below is `auto:`-tagged in `.claude/pipeline-artifacts/issue-460/dod.md`; the harness will run each command literally.

- [ ] `bash scripts/sw-cost-share-test.sh` exits 0 — all 5 hermetic cases pass (happy, invalid JSON, schema violation, empty dir, baseline application).
- [ ] `bash scripts/sw-cost-test.sh` exits 0 — no regression in the pre-existing cost suite.
- [ ] `bash scripts/sw-gha-pipeline-test.sh` exits 0 — workflow YAML still has exactly 2 `upload-artifact` steps and the new one is named `cost-breakdown-issue-*`.
- [ ] `npm test` exits 0 end-to-end.
- [ ] `shellcheck scripts/lib/cost/share.sh scripts/sw-cost-share-test.sh` exits 0 (only the new files; the rest of the tree is out of scope).
- [ ] `bash -c 'source scripts/lib/cost/share.sh && type cost_merge_breakdowns'` exits 0 — function is sourceable and exported.
- [ ] `grep -q 'cost-breakdown-issue-' .github/workflows/shipwright-pipeline.yml` exits 0 — dedicated upload step present with correct name pattern.
- [ ] `grep -q 'cost_merge_breakdowns' .github/workflows/shipwright-optimize.yml` exits 0 — consumer-side merge wired in.
- [ ] `test -f docs/cost-sharing.md && grep -q 'cost-breakdown-issue-' docs/cost-sharing.md` exits 0 — artifact-name contract documented.
- [ ] `grep -q 'lib/cost/share.sh' scripts/sw-cost.sh` exits 0 — CLI sources the lib.
- [ ] `git diff --stat origin/main...HEAD` touches only the files listed in the plan inventory table — no surprise files from loop bookkeeping.

**Out-of-band post-merge check (not in DoD, documented in PR):** first real `shipwright-optimize.yml` run on `main` produces a non-empty `merged-cost-breakdown.json` in the job artifacts, confirming the `actions: read` permission is correctly scoped.
