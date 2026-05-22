# Implementation Plan — Issue #624

**Goal**: Pipeline: add `resync` stage scaffold between `audit` and `pr` (basic git merge, no conflict handling).

This is Issue A of 4 (decomposition of #608) — scaffold only. Issues B/C/D follow.

---

## Architecture Decision Record

### Context
The pipeline currently goes `… → audit → pr`. When `main` advances during a long pipeline run, the WIP branch falls behind and `gh pr create` opens a PR against stale code. `stage_pr()` already calls `auto_rebase` internally (`pipeline-stages-delivery.sh:134`), but that conflates two concerns and gives no separate failure surface. Introducing a dedicated `resync` stage isolates "make WIP current with base" from "open the PR" so future issues can layer conflict-resolution retries, post-merge verification, and telemetry without further mutating `stage_pr()`.

### Decision
Add `stage_resync()` as a sibling of `stage_pr()` in `scripts/lib/pipeline-stages-delivery.sh`. Wire it into every pipeline template + the legacy `stage_order` fallback. Use `git merge` (not rebase) for Issue A — branch-rewriting behavior stays in `stage_pr`'s `auto_rebase` path. The scaffold's contract: success ⇒ working tree matches `origin/$BASE_BRANCH` merged into WIP; failure ⇒ working tree clean, stage marked failed, pipeline stops before `pr`.

### Alternatives Considered

| Option | Pros | Cons | Decision |
|---|---|---|---|
| Inline merge inside `stage_pr` (no new stage) | Smallest surface | Issue B's retry loop has nowhere to live; failure surface still entangled with PR creation | Rejected |
| Rebase instead of merge | Cleaner linear history | Force-push semantics complicate Issue B conflict handling; merge keeps SHA history stable for retry detection | Rejected for A; revisit in C |
| Skip `resync` in `fast`/`hotfix` templates | Faster hotfix path; matches existing skip pattern for `plan`/`review` | Inconsistent fail-surface across templates | Adopted (`enabled: false`) per issue hint |
| `resync_abort` inline in `stage_resync` | Fewer LOC | Issue B reuses the abort contract; isolating it now prevents B from inheriting broken-state bugs | Rejected (per issue rationale) |

### Component Decomposition

| Component | Responsibility | Reason to change |
|---|---|---|
| `stage_resync()` | Fetch base, merge into WIP, set `CURRENT_STAGE_ID`, log result | merge semantics change |
| `resync_abort()` | `git merge --abort` + verify clean tree | abort contract changes |
| Template files (11) | Declare `resync` in pipeline composition | stage added/removed/renamed |
| `defaults.json` `stage_order` | Legacy fallback ordering | stage added/removed/renamed |
| `pipeline-stages.sh` `show_stage_preview` | One-line preview text | new stage added |
| `pipeline-state.sh` `get_stage_description` | Status-line description | new stage added |

### Interface Contracts

```
stage_resync() → int
  preconditions:  git working tree clean (or in a state where auto_rebase would have run);
                  BASE_BRANCH (default "main") defined; CWD is project root
  postconditions: success(0)  → HEAD has merged origin/$BASE_BRANCH (possibly no-op);
                                CURRENT_STAGE_ID="resync"
                  failure(1)  → resync_abort() was called; working tree clean;
                                mark_stage_failed("resync", <msg>) invoked

resync_abort() → int (always 0)
  side-effects:   `git merge --abort` (ignored when no merge in progress);
                  warn() if working tree still dirty after abort
```

---

## Files to Modify

### Templates (11 — JSON insertion of one stage object)
- `templates/pipelines/autonomous.json` — between `audit` and `pr`, `enabled: true`
- `templates/pipelines/full.json` — between `audit` and `pr`, `enabled: true`
- `templates/pipelines/cost-aware.json` — between `audit` and `pr`, `enabled: true`
- `templates/pipelines/standard.json` — before `pr` (no `audit` in this template), `enabled: true`
- `templates/pipelines/enterprise.json` — before `pr`, `enabled: true`, `gate: "approve"` (matches template's all-approve policy)
- `templates/pipelines/tdd.json` — before `pr`, `enabled: true`
- `templates/pipelines/ios.json` — before `pr`, `enabled: true`
- `templates/pipelines/deployed.json` — before `pr`, `enabled: true`
- `templates/pipelines/fast.json` — before `pr`, **`enabled: false`** (per issue hint)
- `templates/pipelines/hotfix.json` — before `pr`, **`enabled: false`** (per issue hint)
- `templates/pipelines/ios-fast.json` — before `pr`, **`enabled: false`** (matches `fast` policy)

### Config
- `config/defaults.json` — insert `"resync"` into `pipeline.stage_order` between `"compound_quality"` and `"pr"` (the list has no `audit`).

### Scripts
- `scripts/lib/pipeline-stages-delivery.sh` — add `stage_resync()` + `resync_abort()` before `stage_pr()` at line 6 (inside the `_PIPELINE_STAGES_DELIVERY_LOADED` guard).
- `scripts/lib/pipeline-stages.sh` — add `resync) echo "..." ;;` case to `show_stage_preview` (~line 290) before `pr)`.
- `scripts/lib/pipeline-state.sh` — add `resync) echo "Syncing branch with base before PR" ;;` to `get_stage_description` static fallback (~line 188).

### Tests
- `scripts/sw-lib-pipeline-stages-test.sh` — add `stage_resync` test section (happy-path no-op, conflict path → `resync_abort` invoked, missing remote tolerated).

**No dispatch table to modify** — `run_stage_with_retry` in `sw-pipeline.sh:1572` dynamically calls `"stage_${stage_id}"`, so defining the function in a sourced lib is sufficient.

---

## Implementation Steps

1. **Define `resync_abort()`** in `pipeline-stages-delivery.sh` (above `stage_pr`):

   ```bash
   resync_abort() {
       git merge --abort 2>/dev/null || true
       if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
           warn "resync_abort: working tree still dirty after git merge --abort"
       fi
       return 0
   }
   ```

2. **Define `stage_resync()`** directly below `resync_abort()`:

   ```bash
   stage_resync() {
       CURRENT_STAGE_ID="resync"
       BASE_BRANCH="${BASE_BRANCH:-main}"

       info "Syncing branch with origin/${BASE_BRANCH}..."

       # Fetch base — failure is non-fatal (offline / no remote in tests)
       if ! git fetch origin "$BASE_BRANCH" 2>/dev/null; then
           warn "Could not fetch origin/${BASE_BRANCH} — assuming local-only base"
           if ! git rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1 \
               && ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
               log_stage "resync" "no-op (no base ref available)"
               return 0
           fi
       fi

       local merge_ref="origin/${BASE_BRANCH}"
       git rev-parse --verify "$merge_ref" >/dev/null 2>&1 || merge_ref="$BASE_BRANCH"

       if git merge "$merge_ref" --no-edit 2>&1; then
           success "Branch is current with ${merge_ref}"
           emit_event "resync.complete" \
               "issue=${ISSUE_NUMBER:-0}" \
               "base=${BASE_BRANCH}" || true
           log_stage "resync" "merged ${merge_ref}"
           return 0
       fi

       # Merge failed → assume conflict (only failure mode for non-no-op merge)
       error "Merge conflict against ${merge_ref} — conflict resolution coming in follow-up issue"
       resync_abort
       emit_event "resync.conflict" \
           "issue=${ISSUE_NUMBER:-0}" \
           "base=${BASE_BRANCH}" || true
       mark_stage_failed "resync" "conflicts detected — conflict resolution coming in follow-up issue"
       return 1
   }
   ```

   **Note**: Do NOT call `gh pr create` / `gh pr close` here. The next `git push` from `stage_pr` will auto-update any existing PR. The stage is a pure git operation.

3. **Patch all 11 template JSON files** — insert the resync stage at the right position. Standard shape:
   ```json
   { "id": "resync", "enabled": true, "gate": "auto", "config": {} }
   ```
   For `fast.json`, `hotfix.json`, `ios-fast.json`: `"enabled": false`. For `enterprise.json`: `"gate": "approve"`.

4. **Update `config/defaults.json`** — insert `"resync"` between `"compound_quality"` and `"pr"` in `pipeline.stage_order`.

5. **Add `resync` to `show_stage_preview`** in `pipeline-stages.sh` (~line 290, before `pr)`):
   ```bash
   resync)   echo -e "  Sync branch with base via git merge (no conflict resolution)" ;;
   ```

6. **Add `resync` to `get_stage_description`** in `pipeline-state.sh` static fallback (~line 188, before `pr)`):
   ```bash
   resync) echo "Syncing branch with base before PR" ;;
   ```

7. **Add tests** to `scripts/sw-lib-pipeline-stages-test.sh`:
   - **Happy path no-op**: temp git repo where WIP == base; `stage_resync` returns 0, working tree unchanged.
   - **Conflict path**: temp repo where WIP modifies a line that base also modified differently; `stage_resync` returns 1, working tree clean (no `<<<<<<<` markers), `mark_stage_failed` invoked.
   - **Missing remote**: temp repo with no `origin`; `stage_resync` returns 0 (no-op fallback).

8. **Run the targeted test** — `bash scripts/sw-lib-pipeline-stages-test.sh` must exit 0.

9. **Validate template JSON shape** — `jq . templates/pipelines/*.json >/dev/null` must exit 0.

10. **Verify pipeline-smoke gate** (commit a1f3464) still passes — `bash scripts/sw-pipeline-test.sh` must exit 0.

11. **Run the full test suite** — `npm test` must exit 0.

---

## Task Checklist

- [ ] Task 1: Add `resync_abort()` helper to `scripts/lib/pipeline-stages-delivery.sh` (above `stage_pr`)
- [ ] Task 2: Add `stage_resync()` to `scripts/lib/pipeline-stages-delivery.sh` (below `resync_abort`, above `stage_pr`)
- [ ] Task 3: Add `resync` case to `show_stage_preview` in `scripts/lib/pipeline-stages.sh`
- [ ] Task 4: Add `resync` case to `get_stage_description` in `scripts/lib/pipeline-state.sh`
- [ ] Task 5: Insert `resync` into `pipeline.stage_order` in `config/defaults.json`
- [ ] Task 6: Patch 3 templates with audit (`autonomous.json`, `full.json`, `cost-aware.json`) — insert resync between audit and pr (enabled: true)
- [ ] Task 7: Patch 5 standard templates without audit (`standard.json`, `tdd.json`, `ios.json`, `deployed.json`, `enterprise.json`) — insert resync before pr (enabled: true; enterprise uses gate: approve)
- [ ] Task 8: Patch 3 fast/hotfix templates (`fast.json`, `hotfix.json`, `ios-fast.json`) — insert resync before pr with `enabled: false`
- [ ] Task 9: Validate template JSON shape — `jq . templates/pipelines/*.json` must succeed
- [ ] Task 10: Add unit tests for `stage_resync` (no-op, conflict→abort, missing-remote) in `scripts/sw-lib-pipeline-stages-test.sh`
- [ ] Task 11: Run `bash scripts/sw-lib-pipeline-stages-test.sh` and confirm all assertions pass
- [ ] Task 12: Run `bash scripts/sw-pipeline-test.sh` (pipeline-smoke gate) and confirm exit 0
- [ ] Task 13: Run `npm test` and confirm all suites pass

**Dependencies**: Task 2 depends on Task 1 (`stage_resync` calls `resync_abort`). Task 10 depends on Tasks 1–2. Tasks 6–8 are independent of each other but all depend on Task 2 conceptually (template references the function name). Tasks 11–13 depend on all preceding.

---

## Risk Analysis

| Risk | Impact | Mitigation |
|---|---|---|
| Merge produces unexpected merge commit on a branch that shouldn't have one | History pollution; may break linear-history branch protection | Scaffold uses `git merge --no-edit`; Issue B/C will revisit. For A, acceptable because `stage_pr` already calls `auto_rebase` upstream which would rewrite this commit anyway. |
| `git fetch origin` fails (no network, no remote) | Stage fails spuriously | Wrap `git fetch` in `\|\| warn`; fall back to local `BASE_BRANCH` ref; final fallback to no-op success. Matches `_safe_base_diff` pattern at `pipeline-stages.sh:266`. |
| `mark_stage_failed` not defined when lib sourced standalone (e.g. unit tests) | Test setup fails | Tests must source `pipeline-state.sh` before `pipeline-stages-delivery.sh`, or stub `mark_stage_failed`. Existing `stage_pr` tests at `sw-lib-pipeline-stages-test.sh:1156` already handle this. |
| Template with `enabled: false` still discovered by `build_stage_progress` | Resync appears as `pending` forever | `build_stage_progress` at `pipeline-state.sh:207` explicitly skips disabled stages — verified safe. |
| Existing in-flight PRs use a composed-pipeline cache that omits `resync` | Stale cached pipelines skip the new stage | Acceptable for A — only affects in-flight pipelines for ~1 hour (`composed_cache_ttl=3600` in defaults.json). New pipelines pick up `resync` immediately. |
| `stage_resync` fails in `--no-github` / `LOCAL_MODE` runs (no `origin/main`) | Local-mode pipelines break | Test case 3 covers this — no-op fallback handles missing remote gracefully. |
| Conflict-marker residue if `git merge --abort` doesn't clean fully | Downstream `stage_pr` sees dirty tree, refuses to push | `resync_abort` verifies + warns; explicit `mark_stage_failed` halts the pipeline before `stage_pr` runs. |

---

## Testing Approach

### Test Pyramid Breakdown
- **3 unit tests** (in `sw-lib-pipeline-stages-test.sh`): happy-path no-op, conflict→abort, missing-remote
- **1 integration test**: existing pipeline-smoke gate (`sw-pipeline-test.sh`) exercises template composition end-to-end and will naturally include `resync` after this change
- **0 E2E tests**: full pipeline run requires real GitHub + Claude API — out of scope for scaffold; Issue D adds telemetry verification

### Coverage Targets
Critical paths that MUST be covered:
1. **Happy path (no-op merge)**: `stage_resync` returns 0 when WIP is already current with base.
2. **Conflict path**: `stage_resync` returns 1, `resync_abort` is invoked, working tree is clean (no `<<<<<<<` markers), `mark_stage_failed` is called.
3. **Missing-remote path**: `stage_resync` returns 0 (no-op) when neither `origin/main` nor `main` exists locally — required for local-mode pipelines and CI test isolation.

Edge cases:
- Merge with non-conflicting divergent commits (clean merge, not no-op) — verifies `--no-edit` semantics.
- `BASE_BRANCH` unset — verifies default to `main`.

### Test Setup Pattern (mirrors existing `stage_pr` tests at line 1156)
```bash
tmp_repo=$(mktemp -d); cd "$tmp_repo"
git init -q && git checkout -b main -q
echo "v1" > a.txt && git add a.txt
git -c user.email=t@t -c user.name=t commit -qm init
git checkout -b shipwright/issue-624 -q
# ... vary base/HEAD state per test ...
stage_resync; rc=$?
assert_equal "$rc" "0"  # or 1 for conflict case
```

---

## Endpoint / API Specification

N/A — this issue adds an internal bash function, not an HTTP endpoint. Section skipped per skill guidance.

---

## Definition of Done

- [ ] `bash scripts/sw-lib-pipeline-stages-test.sh` exits 0 with new `stage_resync` tests included {auto:other:bash scripts/sw-lib-pipeline-stages-test.sh}
- [ ] `bash scripts/sw-pipeline-test.sh` exits 0 (pipeline-smoke gate still green) {auto:other:bash scripts/sw-pipeline-test.sh}
- [ ] All 11 template files contain a `resync` stage object {auto:other:bash -c 'for f in templates/pipelines/*.json; do jq -e "[.stages[].id] | index(\"resync\") != null" "$f" >/dev/null || { echo FAIL:$f; exit 1; }; done'}
- [ ] `config/defaults.json` `pipeline.stage_order` contains `resync` immediately after `compound_quality` and immediately before `pr` {auto:other:jq -e '.pipeline.stage_order | (index("resync") == (index("compound_quality") + 1)) and ((index("resync") + 1) == index("pr"))' config/defaults.json}
- [ ] `stage_resync` and `resync_abort` functions are defined and callable {auto:other:bash -c 'source scripts/lib/pipeline-state.sh 2>/dev/null; source scripts/lib/pipeline-stages-delivery.sh; type stage_resync resync_abort >/dev/null'}
- [ ] All template JSON files parse cleanly {auto:other:bash -c 'jq . templates/pipelines/*.json >/dev/null'}
- [ ] `npm test` exits 0 {auto:tests}
- [ ] Diff includes `stage_resync` and `resync_abort` definitions in `pipeline-stages-delivery.sh` {auto:diff}
- [ ] Diff modifies 11 template files plus the 4 script/config files (`pipeline-stages-delivery.sh`, `pipeline-stages.sh`, `pipeline-state.sh`, `defaults.json`) plus the test file {auto:diff}
