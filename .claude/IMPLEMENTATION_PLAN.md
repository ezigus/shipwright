# Implementation Plan: Sync Fork with Upstream (v3.1.0 → v3.2.4)

## Summary

Merge 42 upstream commits from `sethdford/shipwright` into `ezigus/shipwright`, resolving 11 file conflicts while preserving 38 local commits (bug fixes, smart test targeting, macOS compatibility, hardcoded test_cmd removal).

**Upstream version is actually v3.2.4** (not v3.2.0 as originally stated — upstream has continued past the v3.2.0 tag).

## Merge Statistics

| Metric                      | Value        |
| --------------------------- | ------------ |
| Merge base                  | `846b47f`    |
| Local commits since base    | 38           |
| Upstream commits since base | 42           |
| Files changed upstream-only | 211          |
| Files changed fork-only     | 159          |
| Files changed on both sides | 33           |
| **Actual git conflicts**    | **11 files** |
| Auto-merged successfully    | 22 files     |

## Files to Modify

### Conflict Resolution (11 files — manual merge required)

| File                                  | Resolution Strategy                                                                                                     |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `.claude/CLAUDE.md`                   | **Keep local** — thin wrapper philosophy; upstream only changed AUTO table line counts                                  |
| `.claude/intelligence-cache.json`     | **Delete** — ephemeral cache, deleted locally, regenerates on demand                                                    |
| `.claude/platform-hygiene.json`       | **Delete** — ephemeral scan results, deleted locally, regenerates on demand                                             |
| `scripts/lib/pipeline-detection.sh`   | **Merge both** — keep local multi-lang detection + add upstream `set -u` safety defaults                                |
| `scripts/sw-hygiene.sh`               | **Merge both** — keep local perf optimization + add upstream shellcheck directives                                      |
| `scripts/sw-otel.sh`                  | **Merge both** — keep local Bash 3.2 compat fixes + add upstream shellcheck directives                                  |
| `scripts/sw-pipeline.sh`              | **Merge both** — keep local 500-char goal compaction + add upstream env vars (`SHIPWRIGHT_ACTIVE`, `TEST_CMD_EXPLICIT`) |
| `scripts/sw-tmux-status.sh`           | **Keep local** — changes converged (both remove `local p a`); add upstream SC2155 directive                             |
| `templates/pipelines/autonomous.json` | **Merge both** — remove hardcoded `test_cmd` (local fix) + accept full model names + add `audit` stage from upstream    |
| `templates/pipelines/cost-aware.json` | **Merge both** — remove hardcoded `test_cmd` + accept full model names + add `audit` stage                              |
| `templates/pipelines/full.json`       | **Merge both** — remove hardcoded `test_cmd` + accept full model names + add `audit` stage                              |

### Auto-Merged Files (22 files — verify correctness)

These merged cleanly but need post-merge validation:

- `.gitignore`, `README.md`, `config/defaults.json`, `package.json`
- `scripts/lib/daemon-dispatch.sh`, `scripts/lib/pipeline-stages.sh`
- `scripts/sw-daemon.sh`, `scripts/sw-daemon-test.sh`
- `scripts/sw-code-review-test.sh`, `scripts/sw-docs-agent-test.sh`
- `scripts/sw-e2e-system-test.sh`, `scripts/sw-hygiene-test.sh`
- `scripts/sw-init-test.sh`, `scripts/sw-lib-daemon-dispatch-test.sh`
- `scripts/sw-loop.sh`, `scripts/sw-pipeline-test.sh`
- `scripts/sw-prep.sh`, `scripts/sw-regression.sh`
- `scripts/sw-self-optimize.sh`, `scripts/sw-self-optimize-test.sh`
- `scripts/sw-strategic-test.sh`, `scripts/sw-team-stages.sh`

### New Files from Upstream (~24 net-new files)

Key additions arriving from upstream:

- `.claudeignore` — context window optimization
- `.gitmodules` + `skipper` — Skipper submodule
- `scripts/sw-chaos-test.sh` — chaos testing
- `scripts/sw-lib-daemon-patrol-test.sh` — patrol test
- `dashboard/src/canvas/*` — Shipyard dashboard tab (pixel art)
- `dashboard/src/views/shipyard.ts` — Shipyard view
- `dashboard/src/design/submarine-theme.ts` — submarine theme
- `docs/plans/*` — Skipper integration design docs
- `AUDIT-*.md`, `.claude/*-AUDIT*.md` — audit reports
- `TEST_RESULTS.md` — test results artifact

### Post-Merge Version

- `package.json` version will be `3.2.4` (from upstream auto-merge)
- All script `VERSION=` headers arrive via upstream's changes

## Implementation Steps

### Phase 1: Preparation (Steps 1–3)

**Step 1.** Ensure we're on the merge branch `ci/chore-sync-fork-with-upstream-sethdford-37` (already checked out).

**Step 2.** Fetch latest upstream:

```bash
git fetch upstream
```

**Step 3.** Begin the merge:

```bash
git merge upstream/main --no-ff -m "chore: merge upstream v3.2.4 into fork (42 commits)"
```

This will stop with 11 conflicts to resolve.

### Phase 2: Conflict Resolution (Steps 4–14)

**Step 4.** Resolve `.claude/CLAUDE.md`:

- Keep the local thin wrapper (18-line version referencing centralized standards)
- `git checkout --ours .claude/CLAUDE.md && git add .claude/CLAUDE.md`

**Step 5.** Resolve `.claude/intelligence-cache.json`:

- Accept local deletion (ephemeral cache)
- `git rm .claude/intelligence-cache.json`

**Step 6.** Resolve `.claude/platform-hygiene.json`:

- Accept local deletion (ephemeral scan artifact)
- `git rm .claude/platform-hygiene.json`

**Step 7.** Resolve `scripts/lib/pipeline-detection.sh`:

- Start from local version (has multi-lang environment detection)
- Cherry-pick upstream's safety defaults: `PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"` and similar `SCRIPT_DIR` default
- Add upstream's comment change ("default branch prefix mapping")
- Verify all upstream shellcheck directives are present

**Step 8.** Resolve `scripts/sw-hygiene.sh`:

- Start from local version (has timeout optimization + index scan)
- Bump VERSION to `3.2.4`
- Add upstream's shellcheck disable directives (SC2155, SC2046, SC2034, SC2038, SC2318)
- Verify no upstream functional changes were lost

**Step 9.** Resolve `scripts/sw-otel.sh`:

- Start from local version (has Bash 3.2 array init + arithmetic fixes)
- Bump VERSION to `3.2.4`
- Add upstream's shellcheck disable directives (SC2034 etc.)
- Keep local's `active_pipelines=$((active_pipelines - 1))` with bounds check

**Step 10.** Resolve `scripts/sw-pipeline.sh`:

- Start from local version (has 500-char goal compaction + artifact references)
- Bump VERSION to `3.2.4`
- Add upstream's `export SHIPWRIGHT_ACTIVE=1` and `export SHIPWRIGHT_SOURCE=pipeline` in `setup_dirs()`
- Add upstream's `TEST_CMD_EXPLICIT` flag handling
- Add upstream's shellcheck directives
- Add upstream's composed pipeline cache TTL config lookup

**Step 11.** Resolve `scripts/sw-tmux-status.sh`:

- Keep local version (variable initialization fix)
- Bump VERSION to `3.2.4`
- Add upstream's `# shellcheck disable=SC2155` directive if not already present

**Step 12.** Resolve `templates/pipelines/autonomous.json`:

- Start from upstream version (has `audit` stage + full model names)
- Remove `"test_cmd": "npm test"` from `defaults` (local fix #25)
- Result: full model names + audit stage + no hardcoded test_cmd

**Step 13.** Resolve `templates/pipelines/cost-aware.json`:

- Same approach as autonomous.json
- Remove `"test_cmd": "npm test"` from `defaults`
- Keep upstream's full model IDs (`claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`)
- Keep upstream's `audit` stage

**Step 14.** Resolve `templates/pipelines/full.json`:

- Same approach as autonomous.json
- Remove `"test_cmd": "npm test"` from `defaults`
- Keep upstream's full model names + audit stage with `blocking: true`

### Phase 3: Finalize Merge (Steps 15–16)

**Step 15.** Stage all resolved files:

```bash
git add -A
```

**Step 16.** Complete the merge commit:

```bash
git commit --no-edit
```

### Phase 4: Post-Merge Verification (Steps 17–18)

**Step 17.** Check version consistency:

- `package.json` should show `3.2.4` from auto-merge
- Run `grep -r 'VERSION=' scripts/sw-*.sh | grep '3.1.0'` to find any scripts still at old version
- If any remain, update them to `3.2.4`

**Step 18.** Verify local fixes preserved:

- Smart test targeting in `sw-loop.sh` (PRs #19–#22) — changes intact
- Hardcoded test_cmd removal (PR #25) — no `"test_cmd": "npm test"` in templates
- Status --json flag (PR #36) — `sw-status.sh` changes intact

### Phase 5: Validation (Steps 19–22)

**Step 19.** Run the full test suite:

```bash
npm test
```

All test suites must pass. If new upstream tests fail, investigate and fix.

**Step 20.** Run version consistency check:

```bash
./scripts/check-version-consistency.sh
```

**Step 21.** Spot-check new upstream features:

- Verify `audit` stage exists in pipeline template configs
- Verify `.claudeignore` is present
- Verify new dashboard Shipyard files exist
- Verify Skipper submodule reference exists (`.gitmodules`)

**Step 22.** Fix any test failures introduced by the merge.

### Phase 6: PR (Step 23)

**Step 23.** Open PR: `ci/chore-sync-fork-with-upstream-sethdford-37` → `main`

## Task Checklist

- [ ] Task 1: Fetch upstream and start merge (`git merge upstream/main --no-ff`)
- [ ] Task 2: Resolve `.claude/CLAUDE.md` — keep local thin wrapper
- [ ] Task 3: Resolve `.claude/intelligence-cache.json` and `.claude/platform-hygiene.json` — delete both
- [ ] Task 4: Resolve `scripts/lib/pipeline-detection.sh` — merge local detection + upstream safety
- [ ] Task 5: Resolve `scripts/sw-hygiene.sh` — merge local perf + upstream linting
- [ ] Task 6: Resolve `scripts/sw-otel.sh` — merge local Bash 3.2 compat + upstream linting
- [ ] Task 7: Resolve `scripts/sw-pipeline.sh` — merge local goal compaction + upstream env vars
- [ ] Task 8: Resolve `scripts/sw-tmux-status.sh` — keep local + upstream SC2155
- [ ] Task 9: Resolve 3 pipeline templates — remove test_cmd + keep audit stage + full model names
- [ ] Task 10: Complete merge commit
- [ ] Task 11: Verify version consistency (all files at 3.2.4)
- [ ] Task 12: Verify local fixes preserved (smart targeting, test_cmd removal, status --json)
- [ ] Task 13: Run `npm test` — full suite, 0 failures
- [ ] Task 14: Fix any test failures from the merge
- [ ] Task 15: Open PR: `ci/chore-sync-fork-with-upstream-sethdford-37` → `main`

## Testing Approach

1. **Full test suite** (`npm test`): All 102+ test suites must pass
2. **Version consistency**: `./scripts/check-version-consistency.sh` — all VERSION= headers, package.json, and README badge must read `3.2.4`
3. **Spot-check new features**: Verify audit stage in templates, `.claudeignore` present, Shipyard dashboard files exist
4. **Regression check**: Verify local fixes preserved:
   - Smart test targeting (PRs #19–#22) — `sw-loop.sh` changes intact
   - Hardcoded test_cmd removal (PR #25) — no `"test_cmd": "npm test"` in templates
   - Status --json flag (PR #36) — `sw-status.sh` changes intact
   - macOS broken pipe assertions (PR #17) — test hardening intact

## Definition of Done

- [ ] All 11 merge conflicts resolved correctly
- [ ] Local bug fixes preserved (goal compaction, test_cmd removal, macOS compat, smart targeting)
- [ ] Upstream features present (audit stage, context engineering, shellcheck fixes, intelligence defaults, Shipyard dashboard)
- [ ] `package.json` version is `3.2.4`
- [ ] `npm test` passes with 0 failures
- [ ] Version consistency verified across all files
- [ ] PR opened against `main` with clear description of merge resolution decisions
- [ ] No regressions in pipeline stages, loop behavior, or status --json output

## Risks and Mitigations

| Risk                                                                                           | Mitigation                                                                                 |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Shellcheck fixes in 163 upstream scripts may re-introduce warnings in locally modified scripts | Run shellcheck on locally-modified scripts post-merge                                      |
| New upstream test suites may fail if they depend on features not present in fork's environment | Investigate failures individually; skip env-specific tests if needed                       |
| Skipper submodule reference may not resolve (different repo access)                            | Verify `.gitmodules` URL is accessible; if not, skip submodule init                        |
| Auto-merged files may have subtle semantic conflicts despite no textual conflicts              | Review auto-merged files for correctness, especially `sw-loop.sh` and `pipeline-stages.sh` |
| Version 3.2.4 may not match expectations (issue says v3.2.0)                                   | Upstream has continued past v3.2.0; accept 3.2.4 as current upstream HEAD                  |
