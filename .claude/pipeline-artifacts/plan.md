# Implementation Plan — Issue #460

**Goal:** Upload `cost-breakdown.json` as a GitHub Actions artifact for cross-machine cost-history sharing (UCB1 / adaptive routing / trend analysis).

---

## Brainstorming — Socratic Refinement (auto-answered)

### Requirements Clarity

- **Minimum viable change:** Add one dedicated `actions/upload-artifact@v4` step to `.github/workflows/shipwright-pipeline.yml` that uploads `cost-breakdown.json` (plus its source-of-truth sidecar `stage-costs.jsonl`) and the rolling `~/.shipwright/baselines/` directory under a queryable artifact name. Update existing GHA workflow test to assert the new step exists. No new scripts; no changes to local pipeline logic (`cost-breakdown.json` already lives in `${ARTIFACTS_DIR}` thanks to #87).
- **Implicit requirements:**
  - The artifact must be queryable across runs (so `gh api .../actions/artifacts?name=...` can return a series). Name pattern: `cost-breakdown-issue-<N>-run-<RUN_ID>`.
  - The upload must run on every exit path (success **and** failure) — the data has equal value for forensics. Matches existing `if: always()` pattern.
  - Must not double-upload data already in `pipeline-logs-*`. We accept a small overlap (cost-breakdown.json is ~5–20KB) in exchange for a clean, longer-retention cost artifact that does **not** carry the noisier 7-day pipeline-logs bundle.
  - Retention: 90 days (issue text + GHA default) — long enough for monthly trend analysis without hitting GHA storage caps.
- **Acceptance criteria** (none stated → defined here):
  1. `shipwright-pipeline.yml` contains a second `upload-artifact@v4` step named "Upload cost-breakdown artifact (always)".
  2. Artifact name follows `cost-breakdown-issue-<issue>-run-<run_id>` so `gh api` queries can match by prefix.
  3. Artifact body includes `.claude/pipeline-artifacts/cost-breakdown.json`, `.claude/pipeline-artifacts/stage-costs.jsonl`, and (best-effort) `~/.shipwright/baselines/`.
  4. `retention-days: 90`, `if-no-files-found: warn`, `continue-on-error: true`, `if: always() && steps.claim_check.outputs.skip != 'true'`.
  5. The upload step is positioned **before** the "Propagate pipeline exit code" gatekeeper (mirrors existing log-upload ordering), so the artifact persists even when the job fails.
  6. `scripts/sw-gha-pipeline-test.sh` updated to assert the new step and new total upload-count (2).
  7. `website/src/content/docs/guides/cost.mdx` documents the artifact name pattern and a one-liner `gh` query example.
  8. All existing tests pass; `./scripts/sw-gha-pipeline-test.sh` exits 0; `./scripts/sw-cost-test.sh` exits 0.

### Design Alternatives

1. **Dedicated second `upload-artifact` step (chosen).**
   - Cost data gets its own retention window and its own clean artifact for cross-machine consumers.
   - Trade-off: marginal duplication with `pipeline-logs-*` (under 50KB). Net new YAML: ~15 lines.
   - Blast radius: workflow-only. No script changes.
2. **Extend the existing `pipeline-logs-*` upload to include baselines.**
   - Smaller diff (1 line) but couples cost retention to log retention (7 days), defeats queryability (no dedicated name), and forces cost consumers to download the whole bloated artifact.
3. **PR comment summary instead of artifact.**
   - Human-readable; not machine-readable; cannot feed UCB1. Rejected for MVP — issue explicitly prioritizes machine consumption. Listed as future work in this plan.
4. **Both (artifact + PR comment).**
   - Out of scope for MVP. Comment generation requires PR context only available in `stage_pr` and is non-trivial in shell; deserves its own issue.

**Chosen:** Alternative 1. It is the minimal change that fully resolves the stated goal, has the lowest blast radius (workflow + one test + one doc page), and leaves room for #2/#3/#4 follow-ups.

### Risk Assessment

| Risk | What breaks | Mitigation |
|------|------------|------------|
| Workflow YAML syntax error | Whole pipeline workflow fails to parse → all PRs blocked. | Run `actionlint` (already in `sw-gha-pipeline-test.sh`) plus a YAML parse via `yq` in test. |
| `~/.shipwright/baselines/` not present on fresh CI runner | `upload-artifact` warns; artifact still produced with just `.claude/pipeline-artifacts/cost-breakdown.json`. | `if-no-files-found: warn` (non-blocking). Acceptable — baselines accrue across runs. |
| Artifact name length exceeds GHA's 255-char limit | Upload step errors. | Issue + run-id is ≤30 chars; well under limit. |
| Test asserts `UPLOAD_COUNT == 1` (currently) fails after adding step | `sw-gha-pipeline-test.sh` red. | Update assertion to `== 2` and add positive checks for the new step in the same patch. |
| Cost-breakdown contains issue numbers / branch names; private repo expectation | None for public artifacts — already public. For private repos, GHA artifacts inherit repo visibility. | No PII in cost-breakdown.json (stage names, model names, token counts, USD figures). Documented in `cost.mdx`. |
| Two upload steps running concurrently on `always()` | GHA serializes steps within a job → no race. | N/A (sequential by design). |

### Dependency Analysis

- **Depends on:** `cost_generate_breakdown` (#87, already merged — `scripts/sw-cost.sh:599`) which produces `${ARTIFACTS_DIR}/cost-breakdown.json` in `cleanup_on_exit` (`scripts/sw-pipeline.sh:1185-1206`).
- **Depended on by (future):** UCB1 model selector (`scripts/sw-self-optimize.sh:905`), adaptive routing, cross-machine baseline merge — none of which are touched in this MVP. Their cross-machine consumption is Phase 2.
- **Circular risks:** None — the change is downstream of cost generation only.

### Simplicity Check

- **Can be solved with fewer files?** Workflow change is unavoidable. Test update is required by existing CI gate. Doc update is a one-paragraph addition — keeping it makes the artifact discoverable. No further trim possible without leaving stale tests or undocumented behavior.
- **Existing infrastructure reused?** Yes — `actions/upload-artifact@v4` is already proven in the same workflow; `cost-breakdown.json` is already produced unconditionally; the test harness already validates upload-artifact steps.
- **90% case:** A single dedicated upload covers the 90% case (CI run on GHA). Local-only runs, self-hosted runners, and forked-PR runs degrade gracefully via `continue-on-error: true`.

---

## Architecture Design — ADR

### Component Diagram

```
┌────────────────────────────┐
│ scripts/sw-pipeline.sh     │  cleanup_on_exit() writes:
│  cleanup_on_exit (line     │   .claude/pipeline-artifacts/cost-breakdown.json
│  1185-1206)                │   .claude/pipeline-artifacts/stage-costs.jsonl
└──────────────┬─────────────┘   ~/.shipwright/baselines/<file>.json
               │ (produces)
               ▼
┌─────────────────────────────────────────────────────────────┐
│ .github/workflows/shipwright-pipeline.yml                   │
│   ┌────────────────────────────┐                            │
│   │ Step: Upload pipeline logs │  (existing, retention 7d) │
│   │  → pipeline-logs-issue-N-… │                            │
│   └────────────────────────────┘                            │
│   ┌──────────────────────────────────┐  NEW                 │
│   │ Step: Upload cost-breakdown      │                      │
│   │  → cost-breakdown-issue-N-run-…  │  retention 90d       │
│   └──────────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
               │ (consumed by, future, NOT this PR)
               ▼
┌─────────────────────────────────────────────────────────────┐
│ Cross-machine consumers (Phase 2 — out of scope):           │
│  - UCB1 model selector (sw-self-optimize.sh)                │
│  - Adaptive model routing                                   │
│  - Trend dashboard (dashboard/src/views/metrics.ts)         │
└─────────────────────────────────────────────────────────────┘
```

### Interface Contracts

This is a workflow-only change. The "interface" is the artifact contract.

```typescript
// Artifact: cost-breakdown-issue-<issue>-run-<run_id>
// Retention: 90 days
// Contents (paths inside artifact zip):
interface CostArtifact {
  ".claude/pipeline-artifacts/cost-breakdown.json": CostBreakdownJson;   // produced by cost_generate_breakdown
  ".claude/pipeline-artifacts/stage-costs.jsonl":   StageCostsJsonl;     // raw sidecar (allows re-aggregation)
  ".shipwright/baselines/stage-costs.json"?:        BaselineJson;        // rolling average, all-issues
  ".shipwright/baselines/issue-<N>-costs.json"?:    BaselineJson;        // rolling average, per-issue
}

// Schemas reproduced for clarity (defined in scripts/lib/cost/stage.sh, scripts/lib/cost/baselines.sh):
interface CostBreakdownJson {
  pipeline_id: string;
  issue: string;
  generated_at: string;          // ISO8601
  summary: {
    total_input_tokens: number;
    total_output_tokens: number;
    total_cost_usd: number;
    iteration_count: number;
    stage_count: number;
  };
  by_stage: Array<{
    stage: string;
    input_tokens: number;
    output_tokens: number;
    cost_usd: number;
    count: number;
    models: string[];
  }>;
  by_iteration: Array<{ iteration: number; input_tokens: number; output_tokens: number; cost_usd: number; }>;
}
```

### Data Flow

```
Pipeline run (any exit path)
   └─→ scripts/sw-pipeline.sh:cleanup_on_exit
         └─→ cost_generate_breakdown(ARTIFACTS_DIR, pipeline_id, issue)
               └─→ writes cost-breakdown.json + maintains stage-costs.jsonl sidecar
         └─→ baseline_update_from_breakdown
               └─→ writes ~/.shipwright/baselines/*.json
GitHub Actions runner reaches final steps
   ├─→ Existing "Upload pipeline logs" step  → pipeline-logs-issue-N-run-X (7d)
   └─→ NEW "Upload cost-breakdown artifact"  → cost-breakdown-issue-N-run-X (90d)
                                                    ↑
                            future: `gh api repos/{}/actions/artifacts?name=cost-breakdown-*`
                            future: bulk download into ~/.shipwright/baselines/ before next run
```

### Error Boundaries

| Component | Errors it handles | How errors propagate |
|-----------|-------------------|---------------------|
| `cost_generate_breakdown` | Missing sidecar, malformed JSON line → returns empty array, never fails. | Already tested in #87; not in scope here. |
| New upload-artifact step | Missing files → `if-no-files-found: warn`. Network/upload failure → `continue-on-error: true`. | Never fails the workflow; matches existing pipeline-logs step. |
| GHA artifact retention | Auto-pruned after 90 days. | Downstream consumers must tolerate missing history — UCB1 is robust to sparse data by design. |

### Design Decisions

1. **Why a separate upload step instead of extending the existing one?**
   - Context: Cost data is small, high-value, long-retention; pipeline logs are large, low-value, short-retention. Bundling forces the same retention.
   - Decision: Two steps, two artifact names.
   - Alternatives: Single bundle (rejected — loses queryability + forces 7d retention; or forces 90d on logs which inflates storage cost).
   - Consequences: ~15 extra lines of YAML. Two artifacts per run instead of one. Storage cost negligible (cost-breakdown.json + baselines < 50KB compressed).

2. **Why include `stage-costs.jsonl` in the artifact?**
   - Context: `cost-breakdown.json` is a summarized snapshot; the raw sidecar enables re-aggregation under different assumptions (e.g., excluding retries, grouping differently).
   - Decision: Include both. They're tiny.
   - Alternative: cost-breakdown.json only (rejected — irreversible aggregation).

3. **Why include `~/.shipwright/baselines/` (best-effort)?**
   - Context: Baselines are the rolling-average state that UCB1 and the cost table consume. Cross-machine merge needs them.
   - Decision: Include with `if-no-files-found: warn` — never fail.
   - Alternative: Skip baselines (rejected — without them, every machine bootstraps from zero; defeats the point of "cross-machine optimization").

4. **Why 90-day retention?**
   - Context: GHA default is 90; team quarterly cadence; UCB1 benefits from more samples.
   - Decision: Explicit `retention-days: 90` (don't rely on org-level default which can be changed).

5. **Why automatic upload, not opt-in flag?**
   - Context: Cost is already produced. Upload is near-zero-cost. The open question listed "opt-in vs automatic" — for a piece of data we already write to disk for free, gating on a flag adds friction without benefit.
   - Decision: Automatic. Matches the existing automatic upload of pipeline logs.

---

## Data Pipeline — Schema & Compatibility

- **No new database schema.** Files only. Schemas already defined in `scripts/lib/cost/stage.sh` (sidecar line schema) and `scripts/sw-cost.sh:cost_generate_breakdown` (rolled-up schema).
- **Schema versioning:** `cost-breakdown.json` does not currently carry a schema version field. **Not addressed in this MVP** — adding a version field is a #87 follow-up. Consumers (future) should treat missing keys as `null`/`0` and check `generated_at`. Documented as known-gap in `cost.mdx`.
- **Idempotency:** Re-uploading the same artifact name on a retried run is fine — GHA produces a new artifact ID per upload. No deduplication required.
- **Rollback plan:** Revert the workflow patch (no migration, no data changes). Existing artifacts persist 90 days then auto-prune. Zero-risk rollback.
- **Backfill:** Not applicable — historic runs cannot be re-uploaded. New artifacts accrue from merge forward.

---

## API / Artifact "Endpoint" Specification

This change does not add HTTP endpoints. The closest analogue is the **GHA artifact contract**:

| "Endpoint" | Method | "Path" / Name | "Request" / Trigger | "Response" / Body |
|----------|--------|------|--------|-----|
| Produce artifact | implicit | `cost-breakdown-issue-{N}-run-{run_id}` | Workflow run completion (always) | Zip containing the four files in `CostArtifact` interface above. |
| List artifacts | `GET` (via `gh api`) | `/repos/{owner}/{repo}/actions/artifacts?name=cost-breakdown-issue-{N}*` | Manual / future Phase-2 consumers | GHA standard artifact list JSON. |
| Download artifact | `GET` (via `gh run download`) | n/a | `gh run download <run_id> -n cost-breakdown-issue-{N}-run-{run_id}` | Files extracted to cwd. |

- **Error codes:** N/A — GHA handles upload errors. We swallow with `continue-on-error: true`.
- **Rate limiting:** N/A — one upload per pipeline run.
- **Versioning:** Artifact name carries no version. Schema version is a #87 follow-up (see Known Gaps in doc update).

---

## Files to Modify

| File | Change |
|------|--------|
| `.github/workflows/shipwright-pipeline.yml` | Add new `actions/upload-artifact@v4` step right after the existing "Upload pipeline logs and artifacts" step (~line 1313) and before "Propagate pipeline exit code" (~line 1316). |
| `scripts/sw-gha-pipeline-test.sh` | Update `UPLOAD_COUNT` assertion from `1` to `2`. Add positive checks for the new step's name, files, retention, and `if:` conditions. |
| `website/src/content/docs/guides/cost.mdx` | Add a "Cross-machine cost history" section documenting the new artifact, name pattern, `gh` query example, retention, and schema-version known gap. |
| `CHANGELOG.md` | Add an entry under the next-release "Added" section. |

No new files. No script changes. No template changes.

---

## Implementation Steps

1. **Read the exact YAML context around the existing upload-artifact step** (`shipwright-pipeline.yml:1302-1314`) to match indentation (6-space step indent, 10-space `with:` keys) and `if:` conditional style.
2. **Insert the new step immediately after the existing upload step.** New step:
   ```yaml
         - name: Upload cost-breakdown artifact (always)
           if: always() && steps.claim_check.outputs.skip != 'true'
           uses: actions/upload-artifact@v4
           with:
             name: cost-breakdown-issue-${{ github.event.inputs.issue_number || github.event.issue.number }}-run-${{ github.run_id }}
             path: |
               .claude/pipeline-artifacts/cost-breakdown.json
               .claude/pipeline-artifacts/stage-costs.jsonl
               ~/.shipwright/baselines/
             retention-days: 90
             if-no-files-found: warn
           continue-on-error: true
   ```
3. **Update `scripts/sw-gha-pipeline-test.sh`:**
   - Change `UPLOAD_COUNT` assert from `"1"` to `"2"`.
   - Add a new block of assertions targeting only the new step (search for `Upload cost-breakdown` to scope, then assert: name contains `cost-breakdown-issue-`, path includes `cost-breakdown.json`, path includes `baselines/`, `retention-days: 90`, `if: always()`, `continue-on-error: true`).
   - Keep the existing `UPLOAD_LINE < EXITCODE_LINE` ordering check — it uses `head -1` so it remains valid (asserts the first upload step appears before exit-code propagation, which is still true).
4. **Add a positive-ordering assertion** that the *cost-breakdown* upload also appears before the exit-code propagation step (mirror the existing ordering check using `grep -n 'Upload cost-breakdown' | head -1`).
5. **Update `website/src/content/docs/guides/cost.mdx`** with a new section near the end:
   - One paragraph: what the artifact is, why it exists.
   - Code block: `gh run download <run_id> -n cost-breakdown-issue-<N>-run-<run_id>`.
   - Code block: `gh api repos/$OWNER/$REPO/actions/artifacts -q '.artifacts[]|select(.name|startswith("cost-breakdown-issue-"))|{name,id,size_in_bytes,expires_at}'`.
   - Known gap note: schema-version field not yet present (tracked in #87 follow-up).
6. **Add CHANGELOG entry** under the "Unreleased" / next-version "Added" section: `- Pipeline workflow now uploads a dedicated cost-breakdown artifact (90-day retention) for cross-machine cost-history sharing (closes #460).`
7. **Run targeted tests:**
   - `./scripts/sw-gha-pipeline-test.sh` (validates the workflow + new assertions).
   - `actionlint .github/workflows/shipwright-pipeline.yml` (YAML / GHA syntax).
   - `npm test` (full suite — sanity, no scripts changed but cheap insurance).
8. **Manual verification (best-effort):** Construct a synthetic `${ARTIFACTS_DIR}` directory with a minimal `cost-breakdown.json`, run `cost_generate_breakdown` against it, confirm the JSON shape that the artifact will contain. (No GHA roundtrip possible from this runner; left as PR-time verification by maintainer.)
9. **Commit & PR:** Title: `feat(ci): upload cost-breakdown artifact for cross-machine optimization (#460)`. Body cites #460 + #87.

---

## Task Decomposition (with dependencies)

- **Task 1: Confirm exact insertion point in `shipwright-pipeline.yml`.** Read lines 1290–1320 once. *(No dependencies.)*
- **Task 2: Add the new `Upload cost-breakdown artifact (always)` step.** *(Depends on Task 1.)*
- **Task 3: Update `UPLOAD_COUNT` assertion in `sw-gha-pipeline-test.sh` from 1 to 2.** *(Depends on Task 2 — must match reality.)*
- **Task 4: Add positive assertions for the new step's name, paths, retention, conditions.** *(Depends on Task 2.)*
- **Task 5: Add positive-ordering assertion (new step before exit-code propagation).** *(Depends on Task 2.)*
- **Task 6: Run `./scripts/sw-gha-pipeline-test.sh`; iterate until green.** *(Depends on Tasks 2-5.)*
- **Task 7: Document the artifact in `website/src/content/docs/guides/cost.mdx`.** *(Independent of test work, can run in parallel with Tasks 3-6.)*
- **Task 8: Add CHANGELOG entry.** *(Independent.)*
- **Task 9: Run `actionlint` against the workflow.** *(Depends on Task 2.)*
- **Task 10: Run full `npm test`.** *(Depends on Tasks 2-8.)*
- **Task 11: Commit, push, open PR with `closes #460`.** *(Depends on all above.)*

Critical-path dependency: **Task 2 → Tasks 3, 4, 5, 9 → Task 6 → Task 10 → Task 11.**

---

## Task Checklist

- [ ] Task 1: Read `shipwright-pipeline.yml:1290-1320` to confirm indentation and `if:` pattern.
- [ ] Task 2: Insert new `Upload cost-breakdown artifact (always)` step after the existing logs upload and before "Propagate pipeline exit code".
- [ ] Task 3: Update `UPLOAD_COUNT` assertion in `scripts/sw-gha-pipeline-test.sh` from `"1"` to `"2"`.
- [ ] Task 4: Add positive checks in `sw-gha-pipeline-test.sh` for the new step (name prefix `cost-breakdown-issue-`, paths `cost-breakdown.json` / `stage-costs.jsonl` / `baselines/`, `retention-days: 90`, `if: always()`, `continue-on-error: true`).
- [ ] Task 5: Add ordering assertion that the new step appears before "Propagate pipeline exit code".
- [ ] Task 6: Run `./scripts/sw-gha-pipeline-test.sh` until green.
- [ ] Task 7: Add "Cross-machine cost history" section to `website/src/content/docs/guides/cost.mdx` with `gh run download` and `gh api` examples and the schema-version known-gap note.
- [ ] Task 8: Add CHANGELOG entry under the next-release "Added" section.
- [ ] Task 9: Run `actionlint` on `.github/workflows/shipwright-pipeline.yml`.
- [ ] Task 10: Run full `npm test`.
- [ ] Task 11: Commit with conventional message and open PR citing `closes #460`.

---

## Testing Approach

- **Static workflow validation:** `actionlint .github/workflows/shipwright-pipeline.yml` (catches YAML errors, deprecated action versions, invalid `if:` expressions).
- **Workflow contract tests:** `./scripts/sw-gha-pipeline-test.sh` — extended with new assertions for the cost-breakdown step. This is the primary regression gate.
- **Full suite:** `npm test` — catches any incidental breakage. No production scripts are modified, so this is a sanity check.
- **End-to-end (manual, PR-time):** Maintainer merges and observes the next CI run produces a `cost-breakdown-issue-<N>-run-<RUN_ID>` artifact visible in the run summary. `gh run download <run_id> -n cost-breakdown-issue-<N>-run-<RUN_ID>` returns a non-empty zip. Not automatable in this PR.
- **Negative path:** A run where the pipeline aborts before any stage records cost (e.g., preflight failure) — `cost-breakdown.json` may be missing → `if-no-files-found: warn` keeps the step non-fatal. Verified by the existing test that asserts `if-no-files-found: warn` is set on each upload.

---

## Definition of Done

- [ ] `.github/workflows/shipwright-pipeline.yml` contains exactly two `upload-artifact@v4` steps, the new one named "Upload cost-breakdown artifact (always)".
- [ ] New artifact name evaluates to `cost-breakdown-issue-<issue>-run-<run_id>` (verified by test asserting the literal string fragment).
- [ ] New step has `retention-days: 90`, `if-no-files-found: warn`, `continue-on-error: true`, `if: always() && steps.claim_check.outputs.skip != 'true'`.
- [ ] New step uploads `.claude/pipeline-artifacts/cost-breakdown.json`, `.claude/pipeline-artifacts/stage-costs.jsonl`, and `~/.shipwright/baselines/`.
- [ ] New step appears before "Propagate pipeline exit code".
- [ ] `./scripts/sw-gha-pipeline-test.sh` exits 0 with the new and updated assertions.
- [ ] `actionlint` passes on the workflow file.
- [ ] `npm test` passes.
- [ ] `website/src/content/docs/guides/cost.mdx` includes the new "Cross-machine cost history" section with `gh` examples and the schema-version known-gap note.
- [ ] `CHANGELOG.md` has an "Added" entry referencing #460.
- [ ] PR opened with title `feat(ci): upload cost-breakdown artifact for cross-machine optimization (#460)` and body `Closes #460. Extends #87 by making per-stage cost data accessible outside the local machine.`
- [ ] No changes to production shell scripts, templates, or runtime behavior outside CI (verified by `git diff --stat` showing only `.github/`, `scripts/sw-gha-pipeline-test.sh`, `website/`, `CHANGELOG.md`).

---

## Out of Scope (Phase 2 follow-ups, NOT this PR)

- Auto-downloading prior artifacts at the start of a `cost-aware` template run to seed `~/.shipwright/baselines/`.
- Posting a PR-comment cost summary (Approach #2 / #3 from the issue).
- Adding a schema-version field to `cost-breakdown.json` (separate concern; #87 follow-up).
- Merge logic for baselines downloaded from multiple machines (conflict resolution, rolling-average reconciliation).
- A shared/aggregation backend (S3, datastore) — explicitly rejected per the issue's "without a dedicated aggregation service" framing.
