# Implementation Plan: Upload `cost-breakdown.json` as GitHub Actions Artifact

**Goal:** Make per-stage cost data from `cost-breakdown.json` accessible across CI runs and machines so UCB1 model selection, adaptive routing, and predictive baselines can learn cross-machine instead of starting from zero on each runner.

**Issue:** Closes/extends #87 (stage-level cost attribution).

---

## 1. Brainstorming — Socratic Design Refinement (decisions documented)

### Requirements clarity

- **Minimum viable change:** Add a dedicated `actions/upload-artifact@v4` step at the end of `shipwright-pipeline.yml` that uploads only `cost-breakdown.json` under a deterministic, query-friendly name with longer retention (90 days). The existing catch-all `pipeline-logs-*` upload at line 1244 already captures the whole `.claude/pipeline-artifacts/` dir, but it expires in 7 days and its name is run-scoped (hard to query by issue/stage). A dedicated artifact gives us a stable shape to crawl with `gh api`.
- **Implicit requirements:**
  1. The artifact must be machine-readable (raw JSON, not a markdown summary).
  2. Naming must let `gh run download` / `gh api .../artifacts` filter by repo/issue/date without log-parsing.
  3. Upload must run on **every** pipeline exit path (success and failure) — failing runs still emit costs.
  4. A downloader helper must exist for the cost-aware template / future bootstrap. The issue lists it as an open question.
- **Acceptance criteria (defined since issue lists none):**
  - AC1: Every `shipwright-pipeline.yml` run that produces a `cost-breakdown.json` uploads it as a discrete artifact named `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>` with 90-day retention.
  - AC2: A new helper `scripts/lib/cost/artifact-fetch.sh` exposes `cost_fetch_remote_breakdowns <filter> [limit]` that downloads the N most recent matching artifacts via `gh` and merges them into `~/.shipwright/baselines/`.
  - AC3: Upload is automatic (not opt-in) in CI when `cost-breakdown.json` exists, but is **inert** locally (no `GITHUB_ACTIONS=true`) — controlled via the workflow YAML, not the shell script, so local pipelines are untouched.
  - AC4: A new opt-in env `SHIPWRIGHT_BOOTSTRAP_BASELINES=true` (or `--bootstrap-baselines` flag) causes intake to call `cost_fetch_remote_breakdowns` before the first stage that uses baselines runs (review/compound_quality). Default = off (zero behaviour change).
  - AC5: `shipwright doctor` validates the new artifact upload step exists in the workflow.
  - AC6: Tests in `scripts/sw-cost-artifact-test.sh` cover fetch/merge logic with `gh` mocked.

### Design alternatives considered

| # | Approach | Complexity | Performance | Maintainability | Blast radius | Verdict |
|---|----------|-----------|-------------|-----------------|--------------|---------|
| **A** | Dedicated `upload-artifact` step + `gh`-based fetch helper (this plan) | Low | None (local), small CI step | High — leverages existing `gh` CLI present everywhere | Tiny — adds one YAML step + one shell file + one opt-in flag | **Chosen** |
| B | Rely solely on existing `pipeline-logs-*` artifact at line 1244 | Lowest | Same | Low — name is run-scoped; 7-day retention loses history; consumers must grep through a fat tarball | None | Rejected — issue explicitly asks for cross-run queryability and history. 7 days is too short for trend analysis. |
| C | Push `cost-breakdown.json` to an orphan branch (mirror `ruflo_ci_memory_push` at line 1239 and `sw_discovery_ci_push` at line 1093) | Medium | Slower (git push) | Medium — adds another orphan branch | Medium — branch sprawl, GC concerns | Rejected — orphan branches are right for *append-only memory*; cost data is per-run and already has perfect storage (GitHub Actions artifacts). |
| D | PR comment summary + artifact (issue's option 3) | Medium | Same | Medium — PR comments rot, not machine-parseable, add API noise | Small | Partially adopted — added as **stretch goal** (Task 13). Out of scope for MVP. |

**Why A wins:** GitHub Actions artifacts already give us free storage, retention controls, atomic uploads, deduplication, and a queryable API (`/repos/{o}/{r}/actions/artifacts`). The naming scheme `cost-breakdown-issue-<N>-run-<run_id>` lets `gh api` filter without downloading. No new infrastructure, no new orphan branches.

### Risk assessment

| Risk | What breaks | Mitigation |
|------|-------------|------------|
| Concurrent pipelines on the same issue race on the same artifact name | `upload-artifact` errors with "an artifact with this name already exists" | Suffix with `${{ github.run_id }}` (unique per run) AND `${{ github.run_attempt }}` for re-runs. |
| `cost-breakdown.json` missing on early-failure runs | Upload step warns ("no files found") | Use `if-no-files-found: ignore` (not `warn`/`error`) — early failures are valid. |
| Bootstrap downloads stale data from old code that produced an incompatible schema | Schema drift breaks `baseline_update_from_breakdown` | Reject any breakdown whose `.schema_version` does not match. Add `schema_version: 1` to `cost_generate_breakdown` output as part of this change. |
| `gh api` rate-limited when downloading many artifacts | Bootstrap silently truncated | Cap `cost_fetch_remote_breakdowns` to `limit=20` by default; honour `GITHUB_TOKEN` rate-limit headers; treat 403 as soft-failure. |
| `pipeline-logs-*` artifact also contains `cost-breakdown.json` → dual upload | Disk/quota duplication only — harmless | Acceptable: the catch-all is failure forensics, the dedicated one is for optimization. Documented in `artifact-fetch.sh` header. |
| Tests start hitting real GitHub API | CI flakiness, credentials needed | Mock `gh` via shim on PATH as `sw-pipeline-artifact-push-test.sh` already does. |

### Dependency analysis

- **Depends on:** `cost_generate_breakdown` (sw-cost.sh:599), `actions/upload-artifact@v4` (already pinned), `baseline_update_from_breakdown` (lib/cost/baselines.sh:153), `gh` CLI (present on all runners and in dev setup).
- **Used by (after change):** cost-aware bootstrap (`--bootstrap-baselines`), `shipwright doctor`, future cross-run dashboards (out of scope).
- **No circular dependency risk** — new helper is leaf-level; baselines.sh does not need to know about artifact fetch.

### Simplicity check

- Single YAML step + single new shell file + one opt-in flag + one doctor check. No new dependencies, no new services, no schema migrations (just one additive `schema_version` field).
- Existing infrastructure reused: `actions/upload-artifact@v4`, `gh` CLI, `baseline_update_from_breakdown`, the doctor framework.

---

## 2. Files to Modify

### Create
- `scripts/lib/cost/artifact-fetch.sh` — `gh`-based downloader/merger. ~120 lines.
- `scripts/sw-cost-artifact-test.sh` — test suite for fetch/merge with mocked `gh`. ~150 lines.

### Modify
- `.github/workflows/shipwright-pipeline.yml` — add a dedicated `cost-breakdown.json` upload step (alongside the existing catch-all at line 1244–1255).
- `scripts/sw-cost.sh` — add `schema_version: 1` to `cost_generate_breakdown` JSON output (line 667–691 `jq -n` block); source `artifact-fetch.sh`; add `breakdown-fetch` subcommand.
- `scripts/sw-pipeline.sh` — when `SHIPWRIGHT_BOOTSTRAP_BASELINES=true` (or `--bootstrap-baselines` flag), invoke `cost_fetch_remote_breakdowns` during intake. Single conditional block, gated off by default.
- `scripts/sw-doctor.sh` — extend the existing `cost-breakdown.json` validation block (around line 1029) to also verify the dedicated upload step exists in `shipwright-pipeline.yml` (grep for `cost-breakdown-issue-`).
- `scripts/sw-cost-test.sh` — add an assertion that the generated breakdown has `.schema_version == 1`.
- `package.json` (if needed) or the test runner manifest — register the new test script.
- `CLAUDE.md` — one-line entry under "Runtime State" describing the new artifact name.

---

## 3. Architecture (ADR-style)

### Component diagram

```
                                  ┌───────────────────────────────────────┐
                                  │   GitHub Actions Artifact Storage     │
                                  │   (90-day retention, REST queryable)  │
                                  └───────────────┬───────────────────────┘
                                                  │
                            upload (per run)      │      download (on demand)
                                  ▲               │              ▼
┌──────────────────────────┐   ┌──┴────────────────────────┐   ┌──────────────────────────┐
│  cost_generate_breakdown │──▶│ shipwright-pipeline.yml    │   │ cost_fetch_remote_       │
│  (scripts/sw-cost.sh)    │   │  · upload step             │   │  breakdowns              │
│  + schema_version: 1     │   │  · run_id-suffixed name    │   │  (lib/cost/              │
└──────────────────────────┘   └────────────────────────────┘   │   artifact-fetch.sh)     │
            │                                                    └───────────┬──────────────┘
            │ produces                                                         │ merges into
            ▼                                                                  ▼
┌──────────────────────────┐                                       ┌──────────────────────────┐
│ .claude/pipeline-        │                                       │ ~/.shipwright/baselines/ │
│  artifacts/              │                                       │  stage-costs.json        │
│  cost-breakdown.json     │                                       │  issue-<N>-costs.json    │
└──────────────────────────┘                                       └──────────────────────────┘
                                                                                ▲
                                                                                │ feeds
                                                                                │
                                                                  ┌─────────────┴─────────────┐
                                                                  │ UCB1 model routing        │
                                                                  │ baseline_classify         │
                                                                  └───────────────────────────┘
```

### Interface contracts

```bash
# scripts/lib/cost/artifact-fetch.sh — public API

# Download the N most recent cost-breakdown artifacts matching <filter>
# and merge them into local baselines. Idempotent (skips already-merged runs
# tracked in ${HOME}/.shipwright/baselines/.fetched-runs.json).
#
# filter: "all" | "issue:<N>" | "branch:<name>"
# limit:  positive integer, default 20, max 100
# Returns: 0 on success (incl. zero matches), 1 on hard error (gh missing).
# Emits:   event "cost.artifact_fetched" {count, filter, oldest_run, newest_run}
cost_fetch_remote_breakdowns() {
    local filter="${1:-all}"
    local limit="${2:-20}"
    # ...
}

# List remote breakdowns without downloading (cheap discovery).
# Echoes one JSON object per line: {run_id, issue, branch, created_at, size_bytes}
cost_list_remote_breakdowns() {
    local filter="${1:-all}"
    local limit="${2:-20}"
    # ...
}
```

### Data flow

1. **Pipeline ends** → `cost_generate_breakdown` writes `.claude/pipeline-artifacts/cost-breakdown.json` (with new `schema_version: 1`).
2. **Workflow finalization** → dedicated `upload-artifact@v4` step uploads it as `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>` with `retention-days: 90` and `if-no-files-found: ignore`.
3. **Future run on a different machine** with `SHIPWRIGHT_BOOTSTRAP_BASELINES=true` calls `cost_fetch_remote_breakdowns` during intake.
4. **Helper** invokes `gh api /repos/{owner}/{repo}/actions/artifacts?per_page=100`, filters by name prefix client-side (GitHub doesn't support server-side name globbing), downloads each via `gh run download --name <name>`, validates `schema_version`, and feeds each one into `baseline_update_from_breakdown`.
5. **Tracking file** `~/.shipwright/baselines/.fetched-runs.json` records merged run IDs so re-runs are idempotent.

### Error boundaries

| Error source | Caught by | Behaviour |
|--------------|-----------|-----------|
| `gh` missing | `cost_fetch_remote_breakdowns` precondition | Return 1, log `warn`, do **not** fail the pipeline. |
| `gh api` returns 403 / rate-limited | per-artifact loop | Skip that artifact, log `warn`, continue. |
| Downloaded JSON fails `jq -e '.schema_version == 1'` | per-artifact validation | Skip, record in `.fetched-runs.json` as `skipped:schema_mismatch`. |
| `baseline_update_from_breakdown` returns non-zero | per-artifact merge | Skip that artifact, continue with next. |
| Upload step fails in CI | `continue-on-error: true` on the new step | Pipeline succeeds; doctor catches missing artifacts later. |

### Idempotency strategy

- **Upload:** Unique name per `(issue, run_id, run_attempt)` → re-runs cannot collide.
- **Fetch:** `.fetched-runs.json` records merged `run_id`s; helper skips IDs it has already merged. Safe to call repeatedly.
- **Baseline update:** `baseline_update_stage` uses an EWMA — merging the same data twice would skew the baseline, hence the tracking file.

### Rollback plan

- **Workflow:** Revert the new YAML step — no data loss; old `pipeline-logs-*` artifact still contains the file.
- **Schema field:** Field is additive; rolling back leaves older consumers ignoring it.
- **Helper / flag:** Both opt-in / leaf code; deleting them does not affect the default pipeline path.
- **Baselines if poisoned:** delete `~/.shipwright/baselines/*.json` and `.fetched-runs.json`; next pipeline rebuilds locally from a fresh start.

### Patterns applied

- **Dependency injection:** helper accepts `_GH_BIN="${GH_BIN:-gh}"` so tests shim `gh`.
- **Single responsibility:** `artifact-fetch.sh` only fetches/merges; baselines.sh still owns baseline math.
- **Open/closed:** `schema_version` is the extension point for future shape changes.

### Anti-patterns avoided

- No god `cost.sh` — split into a focused new file.
- No circular dep (baselines.sh ↛ artifact-fetch.sh).
- No orchestration in YAML — only the upload step is YAML; download is bash and testable.

---

## 4. Implementation Steps (in execution order)

1. **Add `schema_version: 1` to `cost_generate_breakdown` output** in `scripts/sw-cost.sh:667-691`. Add `--arg schema_version "1"` to the `jq -n` invocation and inject `schema_version: ($schema_version | tonumber)` into the output object. This is the foundation — must land first.

2. **Add the dedicated upload step** to `.github/workflows/shipwright-pipeline.yml`, placed immediately **after** the existing catch-all at line 1255 so it runs on every exit path with the same `if: always()` guard:

   ```yaml
   - name: Upload cost-breakdown.json (cross-run baselines)
     if: always() && steps.claim_check.outputs.skip != 'true'
     uses: actions/upload-artifact@v4
     with:
       name: cost-breakdown-issue-${{ github.event.inputs.issue_number || github.event.issue.number }}-run-${{ github.run_id }}-attempt-${{ github.run_attempt }}
       path: .claude/pipeline-artifacts/cost-breakdown.json
       retention-days: 90
       if-no-files-found: ignore
     continue-on-error: true
   ```

3. **Create `scripts/lib/cost/artifact-fetch.sh`** implementing `cost_fetch_remote_breakdowns` and `cost_list_remote_breakdowns` per the contracts above. Use `_GH_BIN` injection. Bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`). Atomic writes via tmp+mv. Guard `$NO_GITHUB`.

4. **Wire `artifact-fetch.sh` into `sw-cost.sh`**: `source` it near the top alongside other `lib/cost/*.sh` helpers and add a `breakdown-fetch <filter> [limit]` subcommand for manual ops (parallels `breakdown` at line 1212).

5. **Add `--bootstrap-baselines` flag** to `sw-pipeline.sh` arg parser and corresponding `SHIPWRIGHT_BOOTSTRAP_BASELINES` env var. When set, during intake stage call `cost_fetch_remote_breakdowns "issue:${ISSUE_NUMBER}" 10` (most relevant) followed by `cost_fetch_remote_breakdowns "all" 20` (broader fallback). Default off.

6. **Extend `sw-doctor.sh`** around line 1060 with a new check: grep `.github/workflows/shipwright-pipeline.yml` for `cost-breakdown-issue-`; emit `check_warn` if missing. Keeps doctor honest if someone reverts the workflow change. Also add a check that the local `cost-breakdown.json` (when present) has `schema_version`.

7. **Write `scripts/sw-cost-artifact-test.sh`**: install a `gh` shim early on `PATH` that emulates `gh api`, `gh run download`, and `gh auth status` from fixture files. Test cases:
   - `cost_list_remote_breakdowns "all" 5` returns expected entries (parses fixture).
   - `cost_fetch_remote_breakdowns "issue:42" 10` downloads, validates, merges, updates `.fetched-runs.json` and `~/.shipwright/baselines/issue-42-costs.json`.
   - Schema mismatch is skipped and recorded.
   - Re-running fetch is a no-op (idempotency).
   - `gh` missing → returns 1, no pipeline failure.

8. **Extend `scripts/sw-cost-test.sh`** with one new assertion: the generated breakdown has `.schema_version == 1`.

9. **Wire the new test suite into `npm test`** (inspect `package.json` for the runner — likely already invokes `scripts/sw-*-test.sh`; if not, add the new path explicitly).

10. **Update `CLAUDE.md`** "Runtime State" section:
    ```
    - GitHub artifact: cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt> (90d retention)
    ```

11. **Local validation:** run `npm test`, `scripts/sw-cost-test.sh`, `scripts/sw-cost-artifact-test.sh`, `scripts/sw-pipeline-test.sh`, `shipwright doctor` — all must pass.

12. **CI sanity:** open PR, confirm in Actions UI that the new step appears and produces a discoverable artifact with the expected name pattern.

13. *(Stretch — separate follow-up PR, out of scope for MVP)* PR comment with cost breakdown. Skeleton: in the PR-creation stage, render `cost-breakdown.json` via existing `render_cost_table_plain` and post via `gh pr comment`.

### Task dependencies

- Task 1 (schema_version) **blocks** Tasks 6 (doctor check), 7 (fetch validates it), 8 (cost-test asserts it).
- Task 3 (helper file) **blocks** Tasks 4, 5, 7.
- Task 2 (YAML upload) is **independent** of helper work — can ship alone.
- Tasks 7 + 8 (tests) **gate** Task 11 (validation).
- Tasks 11 + 12 **gate** merge.

---

## 5. Task Checklist

- [ ] **Task 1:** Add `schema_version: 1` to `cost_generate_breakdown` JSON output in `scripts/sw-cost.sh:667-691`.
- [ ] **Task 2:** Add dedicated `cost-breakdown.json` upload step to `.github/workflows/shipwright-pipeline.yml` after line 1255 (90-day retention, run-id+attempt-suffixed name).
- [ ] **Task 3:** Create `scripts/lib/cost/artifact-fetch.sh` with `cost_fetch_remote_breakdowns` and `cost_list_remote_breakdowns` (gh injection via `_GH_BIN`, idempotent merge tracking in `~/.shipwright/baselines/.fetched-runs.json`, Bash 3.2 compatible).
- [ ] **Task 4:** Source `artifact-fetch.sh` from `scripts/sw-cost.sh` and add the `breakdown-fetch` subcommand for manual use.
- [ ] **Task 5:** Add `--bootstrap-baselines` flag and `SHIPWRIGHT_BOOTSTRAP_BASELINES` env var to `scripts/sw-pipeline.sh`; gate the fetch call inside intake.
- [ ] **Task 6:** Extend `scripts/sw-doctor.sh` to (a) check the `schema_version` field, (b) verify the upload step exists in the workflow file.
- [ ] **Task 7:** Create `scripts/sw-cost-artifact-test.sh` with a `gh` shim and the five test cases listed in step 7.
- [ ] **Task 8:** Add `schema_version` assertion to `scripts/sw-cost-test.sh`.
- [ ] **Task 9:** Wire `sw-cost-artifact-test.sh` into the npm test runner.
- [ ] **Task 10:** Update `CLAUDE.md` "Runtime State" with the new artifact name.
- [ ] **Task 11:** Run full test suites (`npm test`, all `scripts/sw-*-test.sh`, `shipwright doctor`); fix any regressions.
- [ ] **Task 12:** Confirm pipeline runs end-to-end in CI by triggering a no-op pipeline; verify the dedicated artifact appears in the run's Artifacts list with the expected name and downloads cleanly.

---

## 6. Testing Approach

- **Unit:** `sw-cost-test.sh` verifies the new `schema_version` field is present and equals 1.
- **Unit/integration (mocked):** `sw-cost-artifact-test.sh` shims `gh` to feed fixture data, exercises all error branches (missing `gh`, rate-limit 403, schema mismatch, empty results, normal multi-artifact merge), and asserts:
  - `.fetched-runs.json` updated correctly and idempotently.
  - `~/.shipwright/baselines/stage-costs.json` updated.
  - Per-issue baseline `~/.shipwright/baselines/issue-<N>-costs.json` updated when filter is `issue:<N>`.
  - Schema-mismatched artifacts recorded with a `skipped:` reason.
- **Pipeline test:** extend `sw-pipeline-test.sh` (which already stages a `cost-breakdown.json`) with one assertion that `--bootstrap-baselines` invokes the fetch helper (mocked).
- **End-to-end (manual, single CI run):** draft PR with these changes; verify in the Actions UI that:
  1. The new `Upload cost-breakdown.json (cross-run baselines)` step appears and succeeds.
  2. The artifact name matches `cost-breakdown-issue-<N>-run-<run_id>-attempt-1`.
  3. `gh api /repos/{owner}/{repo}/actions/artifacts | jq '.artifacts[].name'` returns it.
  4. Downloading and `jq .schema_version` returns `1`.
- **Doctor:** `shipwright doctor` reports PASS on both new checks.

---

## 7. Definition of Done

- [ ] `cost-breakdown.json` carries `schema_version: 1` on every new generation (verified by `sw-cost-test.sh`).
- [ ] Every CI pipeline run (success **and** failure) produces a dedicated GitHub Actions artifact named `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>` with 90-day retention.
- [ ] `cost_fetch_remote_breakdowns` and `cost_list_remote_breakdowns` exist in `scripts/lib/cost/artifact-fetch.sh`, are callable from `sw-cost.sh breakdown-fetch`, and behave idempotently.
- [ ] `--bootstrap-baselines` works on a fresh machine: starting a pipeline with zero local baselines fetches at least N remote artifacts and populates `~/.shipwright/baselines/` such that `baseline_classify` returns non-`NEW` for recently-seen stages.
- [ ] `shipwright doctor` reports PASS on the two new checks.
- [ ] All test suites green: `npm test`, `sw-cost-test.sh`, `sw-cost-artifact-test.sh`, `sw-pipeline-test.sh`, `sw-doctor.sh`.
- [ ] Default behaviour (no flag/env set) is byte-identical to today on every existing field — confirmed by diffing a normal pipeline run's `cost-breakdown.json` (only addition: `schema_version`).
- [ ] `CLAUDE.md` "Runtime State" lists the new artifact name.
- [ ] PR description explains the change is additive and cross-machine bootstrap is opt-in.

---

## 8. Open questions from the issue — answered inline

| Question | Answer (defended) |
|----------|-------------------|
| Should upload be opt-in or automatic? | **Upload is automatic** (free, low-risk, forensically useful even for non-optimizing users). **Consumption (bootstrap)** is opt-in via `--bootstrap-baselines` so we don't surprise users with cross-run data influencing local decisions without consent. |
| Right artifact naming scheme? | `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>` — prefix is the queryable token, suffix guarantees uniqueness across re-runs. Branch is not encoded in the name (already in artifact metadata via `workflow_run.head_branch`). |
| Does `cost-aware` template need to pull artifacts? | **Yes eventually — but as an opt-in flag, not template-level.** Hard-wiring `cost-aware` to bootstrap on every run would create network dependency for what's currently a local-only template. Instead, users (or daemon configs) set `SHIPWRIGHT_BOOTSTRAP_BASELINES=true` when running `cost-aware` on a fresh machine. Default cost-aware behaviour stays offline. |

---

## 9. API Skill Notes (skipped — not applicable)

The API design skill was injected by the planner. This change introduces **no HTTP endpoints, no REST surface, and no client-server protocol**. It uses the existing GitHub Actions Artifacts REST API as a consumer only (no new API design). Endpoint specification, error codes, rate-limiting (beyond mitigation in §1's risk table), and versioning sections are **explicitly skipped**. The only "schema" is the additive `schema_version: 1` field on the JSON artifact, documented in §3.
