# Implementation Plan — fix(dod): configurable structural test-pairing for DoD verifier

## Summary

Replace the fixed pattern loop in `pipeline_verify_dod` (`scripts/lib/pipeline-intelligence.sh:539-551`) with a config-driven structural search composed from 5 small lists: `test_dir_names`, `test_filename_patterns`, `search_strategies`, `source_roots`, and `prefix_flat_template`. Defaults live in `config/defaults.json` under `pipeline.dod` and flow through the existing `_config_get` precedence chain so target repos can override per-layout without code changes. Rename the orphan `scripts/sw-cost-share-test.sh` → `scripts/sw-lib-cost-share-test.sh` so it conforms to the `sw-lib-*-test.sh` convention the verifier now expects.

## Files to Modify

| File | Change |
|---|---|
| `config/defaults.json` | Add `pipeline.dod` block (5 lists + template). |
| `scripts/lib/pipeline-intelligence.sh` | Replace lines 514–562 pattern loop with structural search helpers `_dod_test_dir_names_lc`, `_dod_render_pattern`, `_dod_candidate_paths`, `_dod_find_test_for`. Keep existing return shape of `pipeline_verify_dod` unchanged. |
| `scripts/sw-cost-share-test.sh` → `scripts/sw-lib-cost-share-test.sh` | `git mv` rename so the new test pairs with `scripts/lib/cost/share.sh` under the `prefix_flat` strategy. |
| `scripts/sw-lib-pipeline-intelligence-test.sh` | Add a new `_dod_find_test_for` test section with 6 behavioral assertions (Shipwright prefix_flat, Shipwright top-level, mirror, co-located Jest, case-insensitive Swift, override). Keep existing DoD tests green. |
| `scripts/sw-pipeline-test.sh` | Register the renamed test file if listed there. |

## Implementation Steps

1. **Inspect current verifier control flow.** Read `scripts/lib/pipeline-intelligence.sh:509-562` to confirm the `case $src_file` filter, the skip list, and the bash 3.2 syntax constraints (no associative arrays, no `${var,,}`). Confirm `_config_get` is already sourced (it is — `lib/config.sh` is loaded at the top of the file).

2. **Add config schema to `config/defaults.json`.** Insert a `dod` object under `pipeline` (between `command_discovery` and the closing brace) containing:
   - `test_dir_names`: `["test","tests","__tests__","spec","specs"]`
   - `test_filename_patterns`: 8-entry list from the issue (`{stem}.test.{ext}`, `{stem}.spec.{ext}`, `{stem}_test.{ext}`, `{stem}-test.{ext}`, `{stem}_spec.{ext}`, `test_{stem}.{ext}`, `{stem_pascal}Test.{ext}`, `{stem_pascal}Tests.{ext}`)
   - `search_strategies`: `["colocated","mirror","flat","prefix_flat"]`
   - `source_roots`: `["src/","lib/","app/","scripts/","pkg/",""]`
   - `prefix_flat_template`: `"scripts/sw-{lib_subpath}-{stem}-test.sh"`

3. **Add a JSON-list reader to `scripts/lib/config.sh`.** Add `_config_get_list "dotpath" [fallback_csv]` that uses `jq -r '<path> // [] | join(",")'` and falls back to a CSV string. Keep it bash 3.2 compatible — return a CSV the caller splits with `IFS=, read -r -a`. **Justification:** `_config_get` only handles scalars; the verifier needs arrays.

4. **Implement helper functions** in `pipeline-intelligence.sh` (above `pipeline_verify_dod`):
   - `_dod_to_lower s` — bash 3.2 lower via `tr '[:upper:]' '[:lower:]'`.
   - `_dod_to_pascal s` — split on `-` and `_`, capitalize each token via `${first^}`-free `tr`/`cut` chain (bash 3.2 safe).
   - `_dod_strip_source_root rel_dir roots_csv` — longest-prefix strip of `source_roots` from `dirname` (returns relative path or empty).
   - `_dod_lib_subpath rel_dir` — for files under `scripts/lib/`, join the path under `lib/` with `-` (e.g. `scripts/lib/cost/share.sh` → `cost`; `scripts/lib/pipeline-intelligence.sh` → empty/top-level handled by caller).
   - `_dod_render_pattern pattern stem ext stem_pascal` — `sed`-based placeholder substitution. Pattern is one of `test_filename_patterns`.
   - `_dod_candidate_paths src_file` — emits candidate paths to stdout, one per line, by walking the 4 strategies × `test_dir_names` (case-insensitively glob-matched via shell `nullglob` + lower-cased compare) × `test_filename_patterns`.
   - `_dod_find_test_for src_file` — returns the first existing candidate path; non-zero exit if none found. **Wraps the directory existence check so case-insensitive match works against the actual filesystem.**

5. **Rewrite the pattern loop in `pipeline_verify_dod`** (lines 538–551). Replace with:
   ```bash
   if _dod_find_test_for "$src_file" >/dev/null 2>&1; then
       test_found=true
   fi
   ```
   Keep the surrounding `checks_total`/`checks_passed`/`missing_tests` accounting unchanged so `dod-verification.json` shape is stable.

6. **Cache config reads** at the top of `pipeline_verify_dod` once per invocation (avoid 1 jq call per candidate × per file). Read all 5 lists into local CSV vars before the loop.

7. **Rename `scripts/sw-cost-share-test.sh` → `scripts/sw-lib-cost-share-test.sh`** with `git mv`. Update any reference in `scripts/sw-pipeline-test.sh` and `package.json` if either lists it explicitly (grep first).

8. **Extend `scripts/sw-lib-pipeline-intelligence-test.sh`** with a new section `_dod_find_test_for` (above the existing `pipeline_verify_dod` section, lines 167+). Add 6 assertions per the deliverables list. For each, `mkdir -p` the candidate source + test path under `$TEST_TEMP_DIR/project`, `cd` into it, and assert the helper resolves to the correct test path. The "override" test writes a `.claude/daemon-config.json` with a custom `prefix_flat_template` and asserts it takes precedence.

9. **Run targeted tests first**, then full suite:
   - `bash scripts/sw-lib-pipeline-intelligence-test.sh` (new + existing assertions)
   - `bash scripts/sw-postmortem-460-test.sh` (regression — unrelated to DoD but verifies no shared-lib breakage)
   - `bash scripts/sw-lib-cost-share-test.sh` (renamed file still runs)
   - `npm test` (final regression sweep)

10. **Verify pass-rate goal locally.** Run `pipeline_verify_dod` against the current branch diff after applying the changes; confirm `cat .claude/pipeline-artifacts/dod-verification.json | jq .pass_rate` is `100` (vs. the previous `97`).

## Task Checklist

- [ ] Task 1: Read and confirm bash 3.2 constraints, then add `pipeline.dod` block to `config/defaults.json`
- [ ] Task 2: Add `_config_get_list` to `scripts/lib/config.sh` with CSV fallback
- [ ] Task 3: Add `_dod_to_lower`, `_dod_to_pascal`, `_dod_strip_source_root`, `_dod_lib_subpath` helpers to `pipeline-intelligence.sh`
- [ ] Task 4: Add `_dod_render_pattern` placeholder renderer
- [ ] Task 5: Add `_dod_candidate_paths` strategy composer (colocated/mirror/flat/prefix_flat)
- [ ] Task 6: Add `_dod_find_test_for` orchestrator with case-insensitive directory match
- [ ] Task 7: Replace the fixed pattern loop in `pipeline_verify_dod` with the helper call and hoist config reads
- [ ] Task 8: `git mv scripts/sw-cost-share-test.sh scripts/sw-lib-cost-share-test.sh` and update any references
- [ ] Task 9: Add 6 new behavioral assertions in `scripts/sw-lib-pipeline-intelligence-test.sh` covering all 5 strategies and one override case
- [ ] Task 10: Run targeted lib test + renamed test, then `npm test` for regression sweep
- [ ] Task 11: Run `pipeline_verify_dod` against the current branch diff and confirm `pass_rate == 100`

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (8 new)** — One per helper function: `_dod_to_lower`, `_dod_to_pascal`, `_dod_strip_source_root`, `_dod_lib_subpath`, `_dod_render_pattern`, plus 3 negative cases (`_dod_find_test_for` returns non-zero when no candidate exists, when source isn't a recognized extension, and when only test files match a "skip" pattern like `*.config.*`).
- **Integration tests (6 new)** — The 6 behavioral scenarios from the issue, all asserting on `_dod_find_test_for` against a synthetic directory tree built in `$TEST_TEMP_DIR/project`.
- **Regression tests (3)** — Existing `pipeline_verify_dod` assertions in `sw-lib-pipeline-intelligence-test.sh:181-200`, plus `sw-postmortem-460-test.sh`, plus the renamed `sw-lib-cost-share-test.sh`.

### Coverage Targets

- Helper functions: 100% branch coverage (each function is small and pure).
- `_dod_find_test_for`: every `search_strategy` exercised by at least one positive test; every placeholder by at least one rendered pattern.
- Critical path: bash 3.2 compatibility — no `declare -A`, no `${var,,}`, no `readarray` (lint via `shellcheck`).

### Critical Paths to Test

- **Happy path:** `scripts/lib/cost/share.sh` resolves to `scripts/sw-lib-cost-share-test.sh` via `prefix_flat`.
- **Error case 1:** source file with no test → `_dod_find_test_for` exits non-zero; `pipeline_verify_dod` records it in `missing_tests`.
- **Error case 2:** malformed `daemon-config.json` (invalid JSON) → helper falls back to defaults from `config/defaults.json` (covered by existing `_config_get` jq `// ""` fallback; assert no crash).
- **Edge 1:** Case-insensitive: `Sources/Foo.swift` → `Tests/FooTests.swift` (Swift PascalCase + cap-T `Tests` dir).
- **Edge 2:** Empty source-root prefix: `foo.ts` at repo root → `__tests__/foo.test.ts` (mirror with empty `rel_path`).

## Definition of Done

- [ ] `bash scripts/sw-lib-pipeline-intelligence-test.sh` exits 0 with all assertions (existing + new) passing {auto:other:bash scripts/sw-lib-pipeline-intelligence-test.sh}
- [ ] `bash scripts/sw-lib-cost-share-test.sh` exits 0 after the rename {auto:other:bash scripts/sw-lib-cost-share-test.sh}
- [ ] `bash scripts/sw-postmortem-460-test.sh` exits 0 (regression) {auto:other:bash scripts/sw-postmortem-460-test.sh}
- [ ] `npm test` exits 0 with no new failures {auto:tests}
- [ ] `shellcheck scripts/lib/pipeline-intelligence.sh scripts/lib/config.sh` exits 0 {auto:other:shellcheck scripts/lib/pipeline-intelligence.sh scripts/lib/config.sh}
- [ ] `jq -e '.pipeline.dod.test_dir_names | length == 5' config/defaults.json` exits 0 {auto:other:jq -e '.pipeline.dod.test_dir_names | length == 5' config/defaults.json}
- [ ] `git diff --name-only main...HEAD` confirms `scripts/sw-cost-share-test.sh` was renamed (R status), not duplicated {auto:diff}
- [ ] `bash -c 'source scripts/lib/pipeline-intelligence.sh && _dod_find_test_for scripts/lib/cost/share.sh' | grep -q sw-lib-cost-share-test.sh` {auto:other:bash -c 'source scripts/lib/pipeline-intelligence.sh && _dod_find_test_for scripts/lib/cost/share.sh' | grep -q sw-lib-cost-share-test.sh}
- [ ] DoD verifier reports `pass_rate: 100` on this branch {auto:other:bash -c 'source scripts/lib/pipeline-intelligence.sh && pipeline_verify_dod .claude/pipeline-artifacts >/dev/null; jq -e ".pass_rate == 100" .claude/pipeline-artifacts/dod-verification.json'}
