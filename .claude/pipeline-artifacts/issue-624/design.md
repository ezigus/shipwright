Verified the plan's claims against the codebase — line numbers, file paths, and structural assumptions all match. The plan is sound. Producing the ADR now.

# Design: Pipeline: add resync stage scaffold between audit and pr (basic git merge, no conflict handling)

## Context

The pipeline today wires `… → compound_quality → audit → pr` (in `autonomous`/`full`/`cost-aware`) or `… → compound_quality → pr` (in the 8 other templates). When `main` advances during a long pipeline run, `stage_pr()` already absorbs the "make WIP current with base" concern via its internal `auto_rebase` call at `scripts/lib/pipeline-stages-delivery.sh:134`. That conflation hides three problems:

1. A merge/rebase failure currently surfaces as a PR-creation failure, blocking telemetry attribution.
2. No place exists for a future retry/conflict-resolution loop (Issue B) without further bloating `stage_pr()` (already 200+ lines).
3. The `--no-github`/`LOCAL_MODE` skip at line 55 short-circuits PR creation **and** also skips the rebase — meaning local-mode runs never test the sync path.

Constraints from the codebase:
- Bash 3.2 compatibility, `set -euo pipefail`, no `declare -A`, no `${var^^}`.
- Stages are dispatched dynamically via `stage_${stage_id}` (`scripts/sw-pipeline.sh:1572`) — adding a stage requires only a sourced function, no dispatch table edit.
- `build_stage_progress` (`pipeline-state.sh:207`) honors `enabled: false`, so disabled stages don't pollute the status line.
- `config/defaults.json` `pipeline.stage_order` is the legacy fallback when no template applies — it contains no `audit` stage; resync slots between `compound_quality` and `pr`.
- 8 of 11 templates have no `audit` stage — title-level positioning is "before `pr`," not strictly "between `audit` and `pr`."

This is Issue A of 4 (decomposition of #608) — scaffold only. The scaffold must be inert under happy-path conditions so Issues B (conflict retries), C (rebase semantics), and D (telemetry) can layer in without disturbing it.

## Decision

Add **two functions** to `scripts/lib/pipeline-stages-delivery.sh` immediately above `stage_pr()`:

1. **`resync_abort()`** — pure cleanup primitive. Runs `git merge --abort` (silenced when no merge in progress), then verifies the working tree is clean and warns if not. Always returns 0. Isolated so Issue B can call it from a retry loop without inheriting a stage's failure-bookkeeping side effects.

2. **`stage_resync()`** — the new pipeline stage. Sets `CURRENT_STAGE_ID="resync"`, fetches `origin/$BASE_BRANCH` (default `main`), runs `git merge origin/$BASE_BRANCH --no-edit`, then either: (a) emits `resync.complete` and returns 0 on success, or (b) calls `resync_abort`, emits `resync.conflict`, calls `mark_stage_failed`, returns 1 on conflict. Fail-open on missing remotes: if `git fetch` fails AND neither `origin/main` nor local `main` exists, log a no-op and return 0 (covers `--no-github` runs and CI test isolation).

Wire the stage in via:
- 11 template files (one stage object per file; `enabled: false` for `fast`/`hotfix`/`ios-fast`; `gate: "approve"` for `enterprise` to match its all-approve policy; `enabled: true, gate: "auto"` for the other 7).
- `config/defaults.json` `pipeline.stage_order` (insert `"resync"` between `"compound_quality"` and `"pr"`).
- `show_stage_preview` case in `pipeline-stages.sh:278` (one-line preview).
- `get_stage_description` case in `pipeline-state.sh:142` (status-line text).

**Data flow**:
```
build → test → review → compound_quality → [audit?] → resync → pr
                                                       │
                                       fetch origin/$BASE_BRANCH
                                                       │
                                    git merge $merge_ref --no-edit
                                                       │
                       ┌──────────success──────────────┴─────────conflict──────────┐
                       │                                                            │
                emit resync.complete                                  resync_abort()
                log_stage "resync"                                    emit resync.conflict
                return 0                                              mark_stage_failed
                                                                      return 1 → pipeline halts before stage_pr
```

**Error handling**: only two failure modes exist — (a) conflict during merge → graceful abort + stage failure; (b) catastrophic git error after a partial merge that `--abort` can't clean up → `resync_abort` warns and the dirty tree is caught by `stage_pr`'s quality gate downstream. No retry inside the stage (Issue B).

**Why merge, not rebase**: rebase rewrites SHAs, complicating Issue B's "detect the same conflict twice" logic. Merge keeps history stable for retry detection and matches the conservative scaffold intent. `stage_pr`'s `auto_rebase` becomes redundant once `stage_resync` runs successfully — its removal is explicitly deferred to Issue C.

## Alternatives Considered

1. **Inline merge inside `stage_pr` (no new stage)** — Pros: smallest diff, zero template churn. Cons: failure surface stays entangled with PR creation; Issue B's retry loop has nowhere to live; telemetry for "sync failed" vs "push failed" remains conflated. **Rejected.**

2. **Rebase instead of merge** — Pros: linear history, matches existing `auto_rebase`. Cons: SHA-rewriting breaks retry-detection heuristics planned for Issue B; force-push semantics conflict with `stage_pr`'s `--force-with-lease` path. **Rejected for A; revisit in C** when conflict handling is in place.

3. **Skip `resync` in `fast`/`hotfix`/`ios-fast` (`enabled: false`)** — Pros: faster hotfix path, mirrors existing skip pattern for `plan`/`review` in `fast.json`. Cons: inconsistent fail-surface across templates; a hotfix to a stale branch silently opens against stale code. **Adopted** per issue hint — the scaffold value is being non-disruptive; conflict handling in B can revisit whether hotfix should enable.

4. **`resync_abort` inline in `stage_resync`** — Pros: fewer LOC, single function. Cons: Issue B's retry loop needs to call abort between attempts without invoking the full stage's bookkeeping (`mark_stage_failed`, event emission). Isolating now prevents B from inheriting bugs we'd otherwise need to refactor out. **Rejected.**

5. **Use `git pull --rebase=false`** — Pros: combines fetch+merge in one command. Cons: hides the failure point; we want explicit fetch error handling (offline → no-op) separate from merge error handling (conflict → abort). **Rejected.**

## Implementation Plan

**Files to create**: none.

**Files to modify** (16 total):

- `scripts/lib/pipeline-stages-delivery.sh` — insert `resync_abort()` and `stage_resync()` directly above `stage_pr()` (line 6), inside the `_PIPELINE_STAGES_DELIVERY_LOADED` guard.
- `scripts/lib/pipeline-stages.sh` — add `resync) echo -e "  Sync branch with base via git merge (no conflict resolution)" ;;` case before `pr)` at line 291.
- `scripts/lib/pipeline-state.sh` — add `resync) echo "Syncing branch with base before PR" ;;` case before `pr)` at line 189 in `get_stage_description`.
- `config/defaults.json` — insert `"resync"` into `pipeline.stage_order` between `"compound_quality"` (index 6) and `"pr"` (index 7).
- `templates/pipelines/autonomous.json` — insert `{ "id": "resync", "enabled": true, "gate": "auto", "config": {} }` between `audit` and `pr`.
- `templates/pipelines/full.json` — same insertion between `audit` and `pr`.
- `templates/pipelines/cost-aware.json` — same insertion between `audit` and `pr`.
- `templates/pipelines/standard.json` — insert before `pr` (no `audit` in this template).
- `templates/pipelines/tdd.json` — insert before `pr`.
- `templates/pipelines/ios.json` — insert before `pr`.
- `templates/pipelines/deployed.json` — insert before `pr`.
- `templates/pipelines/enterprise.json` — insert before `pr` with `"gate": "approve"`.
- `templates/pipelines/fast.json` — insert before `pr` with `"enabled": false`.
- `templates/pipelines/hotfix.json` — insert before `pr` with `"enabled": false`.
- `templates/pipelines/ios-fast.json` — insert before `pr` with `"enabled": false`.
- `scripts/sw-lib-pipeline-stages-test.sh` — add `stage_resync` test section (no-op, conflict, missing-remote) following the pattern at line 1156.

**Dependencies**: none added — uses only `git`, `jq`, and existing pipeline helpers (`info`, `success`, `warn`, `error`, `log_stage`, `emit_event`, `mark_stage_failed`).

**Risk areas**:

| Risk | Mitigation |
|---|---|
| `stage_pr`'s `auto_rebase` (line 134) runs after `stage_resync` succeeds — second rebase on already-merged code | No-op in practice; Issue C removes `auto_rebase` from `stage_pr`. Acceptable redundancy for A. |
| Linear-history branch protection rejects merge commits | `git merge --no-edit` fast-forwards when possible; only produces a merge commit on true divergence. Issue C's rebase mode resolves this. |
| `mark_stage_failed` undefined when lib sourced standalone in tests | Test setup must source `pipeline-state.sh` before `pipeline-stages-delivery.sh`, or stub. Existing `stage_pr` tests already follow this pattern. |
| Stale composed-pipeline cache (TTL=3600s) omits `resync` for in-flight pipelines | Acceptable — affects only pipelines started in the last hour; new pipelines pick up resync immediately. |
| `--no-github` / `LOCAL_MODE` runs lack `origin/main` | Fall-through to local `main` ref; final fallback to no-op return 0 (covered by test 3). |
| Conflict-marker residue if `git merge --abort` fails | `resync_abort` checks `git status --porcelain` and warns; `mark_stage_failed` halts before `stage_pr` runs. |
| `_PIPELINE_STAGES_DELIVERY_LOADED` guard causes re-sourcing to skip the new functions in long-running test runs | Standard guard pattern — functions are defined on first source; safe. |

## Validation Criteria

- [ ] `bash scripts/sw-lib-pipeline-stages-test.sh` exits 0 with three new `stage_resync` assertions (no-op, conflict→abort, missing-remote).
- [ ] `bash scripts/sw-pipeline-test.sh` exits 0 — pipeline-smoke gate (commit a1f3464) still green with `resync` in composed pipelines.
- [ ] `jq -e '[.stages[].id] | index("resync") != null'` succeeds against all 11 template files.
- [ ] `jq -e '.pipeline.stage_order | (index("resync") == (index("compound_quality") + 1)) and ((index("resync") + 1) == index("pr"))' config/defaults.json` returns true.
- [ ] After sourcing `pipeline-state.sh` then `pipeline-stages-delivery.sh`, both `stage_resync` and `resync_abort` are defined (`type` returns "function").
- [ ] `jq . templates/pipelines/*.json >/dev/null` parses cleanly for all templates.
- [ ] `npm test` exits 0.
- [ ] In a temp repo where WIP == base, `stage_resync` returns 0 and `git status --porcelain` is empty.
- [ ] In a temp repo with conflicting WIP/base edits to the same line, `stage_resync` returns 1, working tree contains no `<<<<<<<` markers, and `mark_stage_failed` was invoked with arg `"resync"`.
- [ ] In a temp repo with no `origin` remote and no local `main`, `stage_resync` returns 0 (no-op).
- [ ] `show_stage_preview resync` and `get_stage_description resync` both return non-empty strings.
- [ ] `enterprise.json` resync stage has `"gate": "approve"`; `fast.json`/`hotfix.json`/`ios-fast.json` resync stages have `"enabled": false`.

## Scope

```scope
scripts/lib/pipeline-stages-delivery.sh
scripts/lib/pipeline-stages.sh
scripts/lib/pipeline-state.sh
scripts/sw-lib-pipeline-stages-test.sh
config/defaults.json
templates/pipelines/autonomous.json
templates/pipelines/full.json
templates/pipelines/cost-aware.json
templates/pipelines/standard.json
templates/pipelines/tdd.json
templates/pipelines/ios.json
templates/pipelines/deployed.json
templates/pipelines/enterprise.json
templates/pipelines/fast.json
templates/pipelines/hotfix.json
templates/pipelines/ios-fast.json
```

---

### Skill sections explicitly skipped

- **Endpoint / API Specification, Error Codes, Rate Limiting, Versioning** — N/A. This change adds an internal Bash function dispatched dynamically by `run_stage_with_retry`, not an HTTP API or external interface. The "API" surface is the two-function contract (`stage_resync`, `resync_abort`) already specified above under "Interface Contracts."

### Reviewer notes / plan-quality findings

The implementation plan is accurate and tightly scoped. Verified against the live codebase:

- `stage_pr()` at `pipeline-stages-delivery.sh:6` and `auto_rebase` invocation at `:134` — confirmed.
- `show_stage_preview` at `pipeline-stages.sh:278`, `pr)` case at `:291` — confirmed (plan said ~290).
- `get_stage_description` at `pipeline-state.sh:142`, `pr)` case at `:189` — confirmed (plan said ~188).
- All 11 templates exist; `autonomous.json` has the `audit → pr` sequence; `fast.json`/`standard.json` have no `audit` (resync goes after `compound_quality`).
- `defaults.json` `pipeline.stage_order` has no `audit` entry — confirms insertion point.

Two minor caveats worth surfacing to the build agent:

1. The plan's wording "between `audit` and `pr`" is true only for 3 of 11 templates; for the other 8 it's "between `compound_quality` and `pr`" (or just "before `pr`"). The file-by-file list correctly reflects this; the heading is shorthand.
2. After `stage_resync` lands, `stage_pr`'s `auto_rebase` call becomes a redundant second pass. Leaving it in is intentional for A (defense in depth) but should be removed in Issue C alongside the rebase-mode switch.
