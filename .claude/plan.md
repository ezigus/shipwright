# Implementation Plan: [03.1] Self-Heal Hypothesis Hive — Root-Cause Triage on Test Failure

**Status**: Implementation complete (7 commits on `ci/issue-422`); plan stage delta-only.
**Goal**: `feat(ruflo): [03.1] self-heal hypothesis hive — root-cause triage on test failure`
**Source ADR**: `.claude/PLAN-03-1-self-heal-hive.md` (874 lines, full architecture)

This plan summarises the current state, captures the *delta* still owed by the build/test/PR stages, and meets the pipeline's required output contract. Detailed architecture, data flow, and rationale live in the ADR; this artifact stays narrow.

---

## Current Implementation State

| Component | Location | Status |
|-----------|----------|--------|
| `ruflo_execute_self_heal_hive()` orchestrator | `scripts/lib/ruflo-adapter.sh:1782–1996` | Done |
| Four fail-open gates (env / ruflo / hive / hive_id) | `scripts/lib/ruflo-adapter.sh:1805–1828` | Done |
| Six-phase pipeline (seed → spawn → triage → read → synth → read) | same file, lines 1830–1996 | Done |
| Loop integration + sentinel stripping | `scripts/sw-loop.sh:2700–2705` | Done |
| Synthesis fallback (union, byte-bounded to 8000) | `scripts/lib/ruflo-adapter.sh:1977–1992` | Done (commit `491c63e`) |
| Test suite (≥25 tests, 92 self-heal references) | `scripts/sw-ruflo-adapter-test.sh:4244+` | Done (commit `9988be2`) |
| Loop test header sanitization | `scripts/sw-loop.sh` | Done (commits `7582f74`, `352cd27`) |

**Gap analysis** — what's still missing for a clean PR:

1. README (`README.md:512`) and CHANGELOG (`CHANGELOG.md:23`) already mention `RUFLO_SELF_HEAL_HIVE` (landed in commit `a10657a`). CLAUDE.md still does NOT mention the flag — only remaining doc gap.
2. Working copy has unstaged changes in `.claude/helpers/github-safe.js` and `.claude/helpers/statusline.cjs` unrelated to this goal — must be excluded from the feature commit.
3. This `.claude/plan.md` is the canonical plan artifact for the build stage.

---

## Files to Modify

| File | Change | Status |
|------|--------|--------|
| `README.md` | `RUFLO_SELF_HEAL_HIVE=true` env-flag entry | Done (`README.md:512`) |
| `CHANGELOG.md` | `### Added` entry under `[Unreleased]` | Done (`CHANGELOG.md:23`) |
| `CLAUDE.md` | One-line entry in env-vars / feature-flags section | Pending |
| `.claude/plan.md` | This artifact | In flight |

**Files NOT to modify** (already correct):

- `scripts/lib/ruflo-adapter.sh` — full implementation present
- `scripts/sw-loop.sh` — integration present, sentinel stripping in place
- `scripts/sw-ruflo-adapter-test.sh` — 25+ tests already present
- `.claude/PLAN-03-1-self-heal-hive.md` — keep as canonical ADR

---

## Implementation Steps

1. **Verify clean state** — `git diff --stat` shows only `.claude/helpers/intelligence.cjs` modified (out of scope). Decision: do NOT stage that file in the feature commit; leave for a follow-up or separate cleanup PR.
2. **Locate doc anchors** — grep `README.md` and `CHANGELOG.md` for env-var / unreleased sections so edits land in the right place.
3. **Add docs entries** (README, CHANGELOG, CLAUDE.md) — three minimal edits, ≤5 lines each, no new files.
4. **Replace `.claude/plan.md`** with this plan (already in flight via this stage).
5. **Re-run targeted test** to confirm doc edits didn't accidentally touch a sourced file: `./scripts/sw-ruflo-adapter-test.sh` (full sweep happens in the test stage).
6. **Stage and commit** only the four files listed above; commit message follows the goal verbatim.
7. **Pipeline proceeds** to design → build → test → review → PR stages; build stage is effectively a no-op for this goal because code is already present.

Per repo guidance for `SHIPWRIGHT_SOURCE=loop`, do NOT run the full test matrix manually — the harness owns test execution and will inject results into the next iteration.

---

## Task Checklist

- [x] Task 1: Verify `ruflo_execute_self_heal_hive()` exists and integrates with `sw-loop.sh`
- [x] Task 2: Confirm 25+ tests cover gates, bounding, format, ranking, events
- [x] Task 3: Confirm synthesis-fallback bytes are bounded (commit `491c63e`)
- [x] Task 4: Add `RUFLO_SELF_HEAL_HIVE` to README env-flag section (`README.md:512`)
- [x] Task 5: Add CHANGELOG entry under `[Unreleased] / Added` (`CHANGELOG.md:23`)
- [ ] Task 6: Add one-line pointer in CLAUDE.md env-vars section
- [ ] Task 7: Confirm `.claude/plan.md` reflects current state (this update)
- [ ] Task 8: Verify `./scripts/sw-ruflo-adapter-test.sh` still passes after doc edits
- [ ] Task 9: Confirm `.claude/helpers/github-safe.js` and `.claude/helpers/statusline.cjs` are **not** included in the feature commit
- [ ] Task 10: Stage docs + plan; produce single commit matching the goal title
- [ ] Task 11: Confirm pipeline review stage sees no new findings against current ADR
- [ ] Task 12: PR description references `.claude/PLAN-03-1-self-heal-hive.md` ADR

**Dependency graph**: Tasks 4–7 are independent and can be batched. Task 8 depends on 4–7. Task 10 depends on 8 + 9. Tasks 11–12 are pipeline-driven and gated by 10.

---

## Testing Approach

1. **Existing unit suite** (no changes required): `./scripts/sw-ruflo-adapter-test.sh` covers gate logic, input bounding, namespace seeding, hypothesis format, cost/confidence ranking, event emission, and synthesis-fallback fallback.
2. **Loop integration tests** (no changes required): `./scripts/sw-loop-test.sh` covers loop-control sentinel stripping and goal injection.
3. **Smoke check after docs edits**: rerun `./scripts/sw-ruflo-adapter-test.sh` to ensure no accidental regressions from documentation files being sourced/parsed by tests.
4. **Default-path zero-cost verification**: with `RUFLO_SELF_HEAL_HIVE` unset, loop iteration time must be unchanged — guarded by gate test at line ~4248 of `sw-ruflo-adapter-test.sh`.

No new test files needed; the existing 92 self-heal references already exceed the 25-test target in the ADR's DoD.

---

## Definition of Done

- [x] `ruflo_execute_self_heal_hive()` implemented in `scripts/lib/ruflo-adapter.sh`
- [x] Loop integration in `scripts/sw-loop.sh` (gated, sentinel-stripped)
- [x] Four fail-open gates: env flag, ruflo binary, hive available, hive id non-empty
- [x] Input bounding: 8 KB error_text, 2 KB changed_files (multibyte-safe `head -c`)
- [x] Phase timeouts: 12 s spawn / 20 s triage / 5 s read / 8 s synth / 5 s read (≤55 s budget)
- [x] Cost / confidence ranking: argmin(cost) → argmax(confidence) tiebreak
- [x] Synthesis fallback emits byte-bounded union, never raw namespace
- [x] Sentinel stripping (`<<<` and `>>>`) before goal injection
- [x] 25+ tests covering gates, bounding, ranking, events, fallback (currently 92 references)
- [x] README documents `RUFLO_SELF_HEAL_HIVE=true` (`README.md:512`)
- [x] CHANGELOG includes feature in `[Unreleased] / Added` (`CHANGELOG.md:23`)
- [ ] CLAUDE.md mentions env flag in feature-toggle area
- [ ] `.claude/plan.md` reflects current state (this artifact, updated this iteration)
- [ ] Single feature commit excludes unrelated working-tree changes (`.claude/helpers/github-safe.js`, `.claude/helpers/statusline.cjs`)
- [ ] PR description links the ADR (`.claude/ADR-03-1-self-heal-hive.md`)

---

## Risk Analysis

| # | Risk | What Could Break | Mitigation |
|---|------|------------------|------------|
| 1 | Unrelated `github-safe.js` / `statusline.cjs` changes leak into commit | Reviewer flags scope creep; PR bounces | Stage explicitly by file path; never use `git add -A` |
| 2 | Doc edits accidentally touch a file the test harness sources | Test suite breaks unexpectedly | Edit only `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `.claude/plan.md`; rerun tests after edits |
| 3 | CHANGELOG entry duplicates an existing one | Merge conflict on release | Grep for `RUFLO_SELF_HEAL_HIVE` first; place in correct `[Unreleased]` section |
| 4 | README env-flag section may not exist | Edit fails silently or lands in wrong place | Use `Grep` to locate the env-flag table or feature-toggle list before editing; if absent, append to the end of the relevant section, not as a new top-level header |
| 5 | Loop runtime regression if tests rely on default-disabled behavior | CI breaks for downstream consumers | Gate test at `sw-ruflo-adapter-test.sh:4248` already enforces zero-cost default path; no code edits in this stage |
| 6 | ADR drift vs current implementation | Future contributors misled by stale design | This plan stays minimal and points at the ADR; only gap items are listed here, no architecture restated |

---

## Alternatives Considered

### Alternative A — Re-derive the full plan from scratch (rejected)

Re-running the full ADR generation would produce a parallel document that drifts from the canonical `.claude/PLAN-03-1-self-heal-hive.md`. **Trade-off**: high token cost, higher maintenance burden, two sources of truth. **Blast radius**: the build stage might pick the wrong source.

### Alternative B — Skip the plan stage entirely because implementation is done (rejected)

The pipeline state machine requires a `plan` stage artifact for the build stage's prompt composer. Skipping leaves a stale plan in `.claude/plan.md` (compound-quality fix from a prior run) which would mislead the build agent. **Trade-off**: zero work but produces wrong context downstream.

### Alternative C — Delta plan that points at the ADR (chosen)

Replace `.claude/plan.md` with a focused delta plan. Documents what's done, what's left (docs gap), and contractual sections (Required Output, Risks, DoD, Alternatives). **Trade-off**: requires the build agent to read both this file and the ADR, but the ADR is already linked from the goal context. **Blast radius**: single file replacement; reversible via git revert.

### Alternative D — Inline-merge the ADR into `plan.md` (rejected)

Concatenating the 874-line ADR into `plan.md` duplicates content. **Trade-off**: build agent gets full context in one read but blows past the 200-line context-efficiency target and creates two near-identical documents to keep in sync.

---

## Out of Scope

- Adaptive specialist count (`RUFLO_SELF_HEAL_MAX_AGENTS` tuning) — listed under "Future Enhancements" in the ADR
- Weighted ranking formula replacement
- MCP blob storage for unbounded inputs
- Cross-repo specialist hypothesis sharing
- Refactor of the unrelated `.claude/helpers/github-safe.js` / `.claude/helpers/statusline.cjs` working-tree changes
