Plan verified against actual codebase: workflow has one upload step at lines 1302-1313, test asserts `UPLOAD_COUNT == 1` at line 51-54, `cost-breakdown.json` is produced unconditionally from `cleanup_on_exit` (sw-pipeline.sh:1185-1206), `cost.mdx` exists. Producing ADR.

---

# Design: Upload cost-breakdown.json as GitHub Actions artifact for cross-machine optimization

## Context

`cost-breakdown.json` and `stage-costs.jsonl` are produced on every pipeline exit path by `cleanup_on_exit` in `scripts/sw-pipeline.sh:1185-1206` (via `cost_generate_breakdown` from `scripts/sw-cost.sh:599`, landed in #87). Rolling baselines accrue at `~/.shipwright/baselines/`. Today this data is **trapped on whichever machine ran the pipeline** — GHA runners are ephemeral, self-hosted workers don't share state, and developer laptops have separate baselines. As a result:

- **UCB1 model selection** (`scripts/sw-self-optimize.sh:905`) bootstraps from zero on every fresh runner.
- **Adaptive routing** and the **`cost-aware` template** have no historical signal.
- **Trend analysis** across a sprint/quarter is impossible without manual log scraping.

Constraints from the codebase:
- The existing `.github/workflows/shipwright-pipeline.yml:1302-1313` already uploads `pipeline-logs-issue-<N>-run-<RUN_ID>` with **7-day retention** under `if: always()`. The pattern is proven.
- `scripts/sw-gha-pipeline-test.sh:51-54` asserts `UPLOAD_COUNT == 1` and several assertions use `grep -A15 'upload-artifact@v4'` (the regex-against-concatenated-context approach still works with multiple steps).
- A past review (per memory `failures.json` relevance 92) flagged risk of **conflicting expectations between pipeline design and test validation** when adding upload steps — i.e., the test-assertion update **must** ship in the same PR as the workflow change.
- Issue explicitly rejects "a dedicated aggregation service" — must be filesystem/artifact only.
- Cost-breakdown payload is small (<50KB compressed); GHA artifact retention is the binding constraint, not size.

## Decision

**Add one dedicated `actions/upload-artifact@v4` step** to `shipwright-pipeline.yml`, named `Upload cost-breakdown artifact (always)`, positioned immediately after the existing `Upload pipeline logs and artifacts (always)` step (line 1313) and before `Propagate pipeline exit code` (line 1316). Update `sw-gha-pipeline-test.sh` to assert two upload steps and add positive checks scoped to the new step. Document the artifact contract in `website/src/content/docs/guides/cost.mdx`. **No production-script changes.**

The new step:

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

### Component Diagram

```
┌──────────────────────────────────────────┐
│ scripts/sw-pipeline.sh                   │
│   cleanup_on_exit() (line 1185-1206)     │
│     ↓ calls cost_generate_breakdown      │
│   produces:                              │
│     .claude/pipeline-artifacts/          │
│       cost-breakdown.json                │
│       stage-costs.jsonl                  │
│     ~/.shipwright/baselines/*.json       │
└────────────────────┬─────────────────────┘
                     │ (filesystem handoff)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ .github/workflows/shipwright-pipeline.yml                       │
│                                                                 │
│   [existing] Upload pipeline logs and artifacts (always)        │
│     name: pipeline-logs-issue-N-run-X      retention: 7d        │
│                                                                 │
│   [NEW]      Upload cost-breakdown artifact (always)            │
│     name: cost-breakdown-issue-N-run-X     retention: 90d       │
│                                                                 │
│   [existing] Propagate pipeline exit code                       │
└────────────────────┬────────────────────────────────────────────┘
                     │ (artifact API)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ Phase-2 consumers (out of scope this PR — names only):          │
│   sw-self-optimize.sh (UCB1)                                    │
│   cost-aware template bootstrap                                 │
│   dashboard trend view                                          │
└─────────────────────────────────────────────────────────────────┘
```

Five components, each with one reason to change:
1. **Producer** (`cleanup_on_exit`) — owns file generation. Untouched.
2. **CI upload step** (new) — owns artifact contract. New.
3. **CI gatekeeper** (`Propagate pipeline exit code`) — owns failure propagation. Untouched.
4. **Test gate** (`sw-gha-pipeline-test.sh`) — owns workflow-shape regression. Updated.
5. **Docs** (`cost.mdx`) — owns the consumer-facing contract. Extended.

Dependency direction is strict and inward: docs ← test ← workflow ← producer. No reverse coupling.

### Interface Contracts

The "interface" is the GHA artifact. Future consumers depend on this shape:

```typescript
// GHA artifact:
//   name:           "cost-breakdown-issue-<N>-run-<runId>"
//   retention:      90 days
//   compression:    GHA default (zip)
//   visibility:     inherits repo visibility
interface CostArtifact {
  // Always present when the pipeline reached at least one priced stage
  ".claude/pipeline-artifacts/cost-breakdown.json": CostBreakdownJson;
  // Always present alongside cost-breakdown.json (raw input that produced it)
  ".claude/pipeline-artifacts/stage-costs.jsonl":   StageCostLine[];
  // Best-effort — absent on a fresh runner with no prior history
  ".shipwright/baselines/stage-costs.json"?:        StageBaselineJson;
  ".shipwright/baselines/issue-<N>-costs.json"?:    IssueBaselineJson;
}

// Schema reproduced verbatim from scripts/sw-cost.sh:cost_generate_breakdown
interface CostBreakdownJson {
  pipeline_id:   string;
  issue:         string;              // empty string when unknown
  generated_at:  string;              // ISO8601 UTC
  summary: {
    total_input_tokens:  number;
    total_output_tokens: number;
    total_cost_usd:      number;
    iteration_count:     number;
    stage_count:         number;
  };
  by_stage: Array<{
    stage:         string;
    input_tokens:  number;
    output_tokens: number;
    cost_usd:      number;
    count:         number;
    models:        string[];
  }>;
  by_iteration: Array<{
    iteration:     number;
    input_tokens:  number;
    output_tokens: number;
    cost_usd:      number;
  }>;
}

// Listing / retrieval contracts (used by future consumers):
//   GET /repos/{owner}/{repo}/actions/artifacts?name=cost-breakdown-issue-{N}-run-{runId}
//   gh run download <runId> -n cost-breakdown-issue-<N>-run-<runId>
//
// Error contract for the upload step:
//   missing files     → `if-no-files-found: warn`   → step succeeds, artifact partial
//   upload network err → `continue-on-error: true`  → step records failure, job continues
//   In both cases, the gatekeeper "Propagate pipeline exit code" is NOT affected.
```

Preconditions on the upload step: none (runs on every exit path, including very-early aborts).
Postconditions: zero or one artifact named `cost-breakdown-issue-<N>-run-<runId>` exists in the run's artifact list; absent only if upload-artifact itself failed.

### Data Flow

```
pipeline run (any exit code, any stage failure)
  │
  └─→ cleanup_on_exit  (scripts/sw-pipeline.sh:1185)
        │
        ├─→ cost_generate_breakdown          → writes cost-breakdown.json + maintains stage-costs.jsonl
        └─→ baseline_update_from_breakdown   → writes ~/.shipwright/baselines/*.json   [best-effort]
  │
  ▼ (workflow's final 4 steps fire in order, all with `if: always()`)
  │
  Notify dashboard ─→ Persist ruflo memory ─→ Upload pipeline logs ─→ **[NEW] Upload cost-breakdown** ─→ Propagate exit code
  │
  ▼ (consumer side, Phase 2 — NOT this PR)
  gh api repos/.../artifacts?name=cost-breakdown-issue-N* → download → seed baselines → UCB1
```

### Error Boundaries

| Component | Failure mode | Handling | Propagation |
|-----------|--------------|----------|-------------|
| Producer (`cost_generate_breakdown`) | Missing sidecar, malformed JSONL | Returns empty arrays — already shipped behavior from #87 | Pipeline exit unaffected |
| New upload step — missing files | `cost-breakdown.json` not written (e.g., very-early abort) | `if-no-files-found: warn` | Step succeeds, artifact partial or empty |
| New upload step — network/API error | GHA artifact API 5xx, rate limit | `continue-on-error: true` | Step records failure, **job exit code unchanged** |
| Gatekeeper (`Propagate pipeline exit code`) | n/a (this step is the boundary) | Reads `${{ steps.pipeline.outputs.exit_code }}` and `pipeline-state.md` | Owns CI red/green |
| Test harness — assertion mismatch | Step added but assertion not updated | Test exits non-zero in same PR | PR-time gate, never reaches main |
| Consumer (Phase 2) — artifact pruned (>90d) | UCB1 must tolerate sparse history | Out of scope, but called out in docs | Documented gap |

Critical invariant: **the upload step must not be able to fail the pipeline**, because cost data is observability, not correctness. `continue-on-error: true` enforces this at the boundary.

## Alternatives Considered

1. **Dedicated second upload step (CHOSEN).** — Pros: clean queryable name `cost-breakdown-issue-*`, independent 90-day retention, ~15 lines of YAML, zero script changes, lowest blast radius. Cons: ~50KB of duplication with the existing pipeline-logs artifact. Net: duplication cost is trivial; queryability and retention independence are load-bearing for Phase 2.

2. **Extend the existing `pipeline-logs-*` upload to include `~/.shipwright/baselines/`.** — Pros: one-line diff. Cons: forces cost retention to match logs (7 days, kills monthly trend analysis), no queryable artifact name, consumers must download bloated 7-day log bundle to read 20KB of cost data. **Rejected** — couples two unrelated retention policies. Past review (memory `failures.json`, relevance 92) explicitly cautioned against this kind of consolidation when it conflicts with downstream test/consumer expectations.

3. **PR comment cost summary only.** — Pros: human-readable, zero new artifact. Cons: not machine-readable, can't feed UCB1, only fires on PR-context runs (not daemon issue runs). **Rejected for MVP** — issue explicitly prioritizes machine-consumable data. Filed for Phase 2 as a separate follow-up.

4. **Artifact + PR comment hybrid.** — Pros: covers both audiences. Cons: PR comment generation requires PR context only available in `stage_pr`, non-trivial shell logic, doubles the review surface. **Rejected** — comment generation belongs in its own issue.

5. **Aggregation backend (S3, datastore, etc.).** — Pros: true cross-machine source of truth. Cons: new infrastructure, credentials, monitoring; issue explicitly rejects "a dedicated aggregation service". **Rejected by issue framing.**

## Implementation Plan

**Files to create:** none.

**Files to modify:**
- `/home/runner/work/shipwright/shipwright/.github/workflows/shipwright-pipeline.yml` — insert new step after line 1313, before line 1315.
- `/home/runner/work/shipwright/shipwright/scripts/sw-gha-pipeline-test.sh` — change `UPLOAD_COUNT` assertion at line 53-54 from `"1"` to `"2"`; add a new block of assertions scoped via `grep -A15 'cost-breakdown-issue-'` (or `awk` range on the step's `name:` line) to validate name pattern, the three path entries, `retention-days: 90`, `if-no-files-found: warn`, `continue-on-error: true`, `if: always() && ... claim_check.outputs.skip`; add a second ordering assertion that the new step's line number precedes the `Propagate pipeline exit code` line.
- `/home/runner/work/shipwright/shipwright/website/src/content/docs/guides/cost.mdx` — append a "Cross-machine cost history" section: artifact name pattern, `gh run download` example, `gh api .../artifacts?name=cost-breakdown-issue-*` example, retention (90d), and the schema-version known-gap note (no `schema_version` field yet — track as #87 follow-up).
- `/home/runner/work/shipwright/shipwright/CHANGELOG.md` — entry under next-release Added: `Pipeline workflow now uploads a dedicated cost-breakdown artifact (90-day retention) for cross-machine cost-history sharing (closes #460).`

**Dependencies:** none added. `actions/upload-artifact@v4` already in use.

**Risk areas:**
- *Test-assertion fragility (HIGHEST RISK).* The existing block uses `grep -A15 'upload-artifact@v4'` which after the change returns concatenated context from **both** steps separated by `--`. The regex `assert_contains_regex` checks remain truthy (the patterns still appear somewhere in the concatenated output), but this **silently weakens** the scoping of every existing assertion — any future step removal from the *first* upload could still pass tests because the regex matches the *second* upload's context. **Mitigation:** the new positive-assertion block must be scoped tightly (extract just the cost-breakdown step's body via line-range, not `grep -A`), and a TODO comment in `sw-gha-pipeline-test.sh` should call out that the legacy `-A15` scoping is now ambiguous and should be tightened in a follow-up.
- *Ordering check uses `head -1`.* Line 103 (`grep -n 'upload-artifact@v4' | head -1`) continues to validate only the *first* upload step's position. The new ordering assertion (Task 5) must independently locate the cost-breakdown step's line number.
- *`~/.shipwright/baselines/` tilde expansion in `path:`.* `actions/upload-artifact@v4` expands `~` to `$HOME`. Verified behavior; documented in upload-artifact README. No mitigation needed.
- *Artifact name length.* `cost-breakdown-issue-<int>-run-<int>` is ~35 chars; GHA limit is 255. Safe.
- *Concurrent uploads to same name.* GHA assigns a new artifact ID per upload even with identical names, but `upload-artifact@v4` rejects same-name conflicts within a single run. Two **different** names here — no conflict.
- *Past review caution (memory: relevance 92).* That review flagged "duplicate `upload-artifact` steps" as something to consolidate or, alternatively, to validate carefully in tests. The deliberate decision here is **two steps, fully validated** — both options were considered acceptable; we picked two because retention windows diverge by design. This rationale is recorded here so a future reviewer doesn't unwind it on autopilot.

## Schema Changes

**Forward migration:** none — no database, no on-disk schema change. `cost-breakdown.json` schema is unchanged from #87. The "migration" is purely the addition of a transport channel (GHA artifact).

**Rollback script:** `git revert <commit-sha>` on the PR. No data migration to reverse. Artifacts already uploaded will auto-prune after 90 days; they cannot be retroactively un-uploaded but they are harmless.

**Backfill:** not applicable — historic GHA runs cannot have artifacts retroactively attached. New artifacts accrue from PR merge forward. This is documented in `cost.mdx` as a known limitation.

**Schema versioning gap:** `cost-breakdown.json` has no `schema_version` field today. Adding one is **a #87 follow-up, not this PR.** Consumers in Phase 2 must (a) treat missing keys as `null`/`0`, (b) check `generated_at` for staleness, and (c) be defensive on `by_stage` / `by_iteration` array shapes. Documented in the doc update with explicit language: "Schema is best-effort and may change; consumers should validate keys before use."

## Idempotency Strategy

- **Producer side:** `cost_generate_breakdown` is idempotent — re-running it on the same `stage-costs.jsonl` sidecar produces byte-identical `cost-breakdown.json` (modulo `generated_at`).
- **CI side:** each pipeline run has a unique `github.run_id`, so the artifact name `cost-breakdown-issue-<N>-run-<run_id>` is unique per run. Retried jobs within the same run produce a single artifact (upload-artifact@v4 dedupes same-name uploads within a run).
- **Cross-run retries (`shipwright/auto-retry`):** each retry is a new `run_id` → new artifact, intentionally. Consumers can identify retries by issue number and ordering (`created_at` from the GHA artifact API).
- **Consumer side (Phase 2):** consumers receive every retry's artifact and must dedupe by their own logic (e.g., keep only the latest successful run per issue). Out of scope here.

## Validation Criteria

- [ ] `.github/workflows/shipwright-pipeline.yml` contains exactly two `actions/upload-artifact@v4` step uses (verify with `grep -c 'upload-artifact@v4'` returning `2`).
- [ ] The new step's literal `name:` is `Upload cost-breakdown artifact (always)`.
- [ ] The new step's `name:` field evaluates to `cost-breakdown-issue-<N>-run-<run_id>` at runtime (validated via literal-substring assertion `cost-breakdown-issue-` in the test).
- [ ] The new step's `path:` includes all three of `.claude/pipeline-artifacts/cost-breakdown.json`, `.claude/pipeline-artifacts/stage-costs.jsonl`, `~/.shipwright/baselines/`.
- [ ] The new step has `retention-days: 90`, `if-no-files-found: warn`, `continue-on-error: true`.
- [ ] The new step's `if:` is `always() && steps.claim_check.outputs.skip != 'true'` (same gate as siblings).
- [ ] The new step's line number is strictly between the existing pipeline-logs upload (line 1302 today) and `Propagate pipeline exit code` (line 1316 today).
- [ ] `./scripts/sw-gha-pipeline-test.sh` exits 0 with the updated `UPLOAD_COUNT == 2` assertion **and** the new positive-assertion block scoped to the cost-breakdown step.
- [ ] `actionlint .github/workflows/shipwright-pipeline.yml` exits 0 (no YAML/action errors).
- [ ] `npm test` exits 0.
- [ ] `website/src/content/docs/guides/cost.mdx` has a new "Cross-machine cost history" section with: artifact name pattern, `gh run download` example, `gh api ... /artifacts?name=cost-breakdown-issue-*` example with `jq` extraction, retention statement (90 days), and the explicit schema-version known-gap note.
- [ ] `CHANGELOG.md` Added section references issue #460.
- [ ] `git diff --stat` on the PR shows changes **only** in `.github/workflows/shipwright-pipeline.yml`, `scripts/sw-gha-pipeline-test.sh`, `website/src/content/docs/guides/cost.mdx`, and `CHANGELOG.md`. **No production-shell changes.**
- [ ] Rollback verified: `git revert <commit>` restores the workflow to its pre-change shape and `sw-gha-pipeline-test.sh` passes against the reverted file (this is a property of clean revert; spot-check by reading the diff).

## Monitoring Checklist (post-merge)

Skill-mandated observability section. This change has no runtime/user-facing surface, so most P0/P1 alerts are N/A — replaced with PR-merge / first-week observation criteria.

**P0 — first CI run after merge (within ~30 minutes):**
- The workflow run's "Artifacts" panel shows **two** artifacts (pipeline-logs-*, cost-breakdown-*) — threshold: must be exactly 2.
- The new step's GHA log shows "Artifact uploaded" with non-zero size — threshold: ≥ 1KB.
- The job's final status is unchanged from baseline (same green/red as it would have been without the change) — proves `continue-on-error: true` is doing its job.

**P1 — first week (~7 days):**
- Across all merged pipeline runs in the period, the `cost-breakdown-*` artifact is present in **≥ 95%** of runs. Misses are expected on very-early aborts (preflight failure) and are not regressions; investigate only if rate drops below 95%.
- No new `actionlint`/CI lints from the workflow file in `main` branch CI summary.
- No support issues or PR comments referencing "missing artifact" or "upload failed".

**P2 — first month (~30 days):**
- GHA storage usage for this repo: monitor in repo Settings → Actions → Cache and artifact storage. Threshold: cost-breakdown artifacts should contribute <5MB total in a month at the current run cadence. Investigate if >50MB.
- First Phase-2 consumer (UCB1, separate issue) is able to fetch and parse at least 10 historical artifacts via `gh api`. Validates the contract end-to-end.

**Anomaly triggers (run-level):**
- Spike: zero artifacts uploaded across all runs in a 1-hour window → upload-artifact API degraded or workflow broken; investigate via GHA status page first.
- Trend: gradually growing artifact size (>500KB per artifact) → `baselines/` directory unexpectedly large; investigate `baseline_update_from_breakdown` for accidental growth.
- Absence: a successful pipeline run (exit 0) produces no `cost-breakdown-*` artifact → upload step silently failed; check the step's log for `continue-on-error: true` swallowing.
- Latency shift: the new step regularly takes >30s → unusual since artifact is small; investigate runner I/O.

**Log analysis:** search the workflow run logs for `Upload cost-breakdown artifact` step entries. Look for: `No files were found with the provided path` (expected occasionally; OK if pipeline aborted early), `Error: ` (always investigate), `0 files uploaded` (artifact will be empty zip; investigate producer).

**Auto-rollback criteria:** none required for this change. The upload step is `continue-on-error: true` and cannot affect job exit code. If post-merge observation finds the upload step is causing unexpected workflow failures (e.g., interacts badly with concurrent steps), manual revert via the rollback section above is the response. There is no automated rollback trigger to wire because there is no failure mode that warrants one.

---

**Status:** ADR approved by review — proceed to implementation. Task ordering and checklist in the implementation plan are correct; the critical-path is Task 2 → (Task 3, 4, 5) → Task 6 → Task 10 → Task 11, with Tasks 7 and 8 parallelizable.
