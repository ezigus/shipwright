I'll produce the ADR now. The plan is grounded in real code I've verified: `pipeline-intelligence.sh:538-551` (the hardcoded pattern loop), `config/defaults.json:23-73` (insertion point for `pipeline.dod`), `config.sh:22-86` (scalar-only `_config_get`), and the rename targets both exist.

---

# Design: fix(dod): configurable structural test-pairing for DoD verifier

## Context

The DoD verifier in `scripts/lib/pipeline-intelligence.sh:538-551` uses a 6-entry hardcoded pattern list to pair source files with tests. The list is biased toward co-located Jest layouts (`{stem}.test.{ext}` next to the source) and misses three structural conventions this repo and others actually use:

1. **Shipwright `sw-lib-*` flat layout** — `scripts/lib/cost/share.sh` should pair with `scripts/sw-lib-cost-share-test.sh`, not `scripts/lib/cost/share.test.sh`.
2. **Mirror trees** — `src/foo/bar.ts` → `tests/foo/bar.test.ts` (with empty `dir_name` after stripping the source root).
3. **PascalCase + capitalized test dir** — Swift convention `Sources/Foo.swift` → `Tests/FooTests.swift`.

Constraints from the codebase:
- **Bash 3.2 compatible** (`.ai-standards/generated/claude-instructions.md` → "Shell Standards"): no `declare -A`, no `${var,,}` / `${var^^}`, no `readarray`.
- `_config_get` in `scripts/lib/config.sh:24-72` returns scalars only; arrays need a new helper.
- `pipeline_verify_dod` must keep its return shape and the `dod-verification.json` schema intact — downstream gates depend on `checks_total`, `checks_passed`, `missing_tests`, `pass_rate`.
- One file in the repo, `scripts/sw-cost-share-test.sh`, breaks the `sw-lib-*-test.sh` convention; renaming it is part of the fix.

Current `pass_rate` on this branch is 97; target is 100 with no new false negatives elsewhere.

## Decision

Replace the inline pattern loop with a **composable structural search** driven by five lists in `config/defaults.json` under `pipeline.dod`. The search is composed by four small pure helpers plus one orchestrator:

```
config (5 lists) ─┐
                  ├─→ _dod_candidate_paths(src) ─→ _dod_find_test_for(src) ─→ pipeline_verify_dod
helpers (pure) ───┘            (generator)              (filesystem probe)         (accounting)
```

Composition rule (per candidate strategy × dir × pattern):
- `colocated` — `{dirname(src)}/[{test_dir}/]{render(pattern, stem, ext, stem_pascal)}`
- `mirror` — `{src_root}{test_dir}/{rel_path}/{render(...)}` where `rel_path` = `dirname(src)` with `source_roots` longest-prefix stripped
- `flat` — `{test_dir}/{render(...)}` at repo root
- `prefix_flat` — `render(prefix_flat_template, lib_subpath=..., stem=..., ext=...)` (Shipwright `sw-lib-*-test.sh`)

Each candidate is rendered through `_dod_render_pattern` with placeholders `{stem}`, `{ext}`, `{stem_pascal}`, `{lib_subpath}`. Case-insensitive directory matching is done by listing the parent dir with `nullglob`, lowercasing both sides via `tr`, and comparing — no `${var,,}`. The orchestrator emits candidates one per line and returns the first that exists; non-zero exit if none.

**Data flow:**
```
git diff --name-only ──→ for each changed file ──→ extension filter
                                                       │
                                                       ▼
                                        cache config (5 CSV vars, once)
                                                       │
                                                       ▼
                              _dod_find_test_for(src) ──→ stdout: first hit | exit 1
                                                       │
                                                       ▼
                          checks_passed++ | missing_tests += src
```

**Error handling:**
- Missing/invalid `daemon-config.json` → `_config_get` already returns the `// ""` fallback; we re-pull from `config/defaults.json`. No crash.
- Empty config list → fall back to hardcoded CSV default inside `_config_get_list` (preserves current behavior even if `defaults.json` is corrupted).
- No candidate exists → `_dod_find_test_for` exits non-zero; caller records `missing_tests`. Identical to today's behavior for un-pairable files.

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  config/defaults.json                                           │
│  └─ pipeline.dod: { test_dir_names, test_filename_patterns,     │
│                     search_strategies, source_roots,            │
│                     prefix_flat_template }                      │
└────────────────────────────┬────────────────────────────────────┘
                             │ jq read (cached once per call)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/lib/config.sh                                          │
│  └─ _config_get_list(dotpath, [fallback_csv]) → CSV string      │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/lib/pipeline-intelligence.sh — Helper layer (pure)     │
│  ├─ _dod_to_lower(s)              → string                      │
│  ├─ _dod_to_pascal(s)             → string                      │
│  ├─ _dod_strip_source_root(d, csv)→ string                      │
│  ├─ _dod_lib_subpath(d)           → string  (Shipwright-only)   │
│  ├─ _dod_render_pattern(p,s,e,sp) → string                      │
│  └─ _dod_candidate_paths(src)     → stdout (lines)              │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  _dod_find_test_for(src)  — orchestrator + FS probe              │
│  (case-insensitive dir match via nullglob + tr)                 │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  pipeline_verify_dod()  — accounting (unchanged shape)          │
│  reads checks_total/checks_passed/missing_tests → JSON output   │
└─────────────────────────────────────────────────────────────────┘
```

Dependencies point inward: `pipeline_verify_dod` → orchestrator → helpers → config reader. Helpers don't touch the filesystem; only `_dod_find_test_for` does. This isolates the side-effecting layer for testing.

## Interface Contracts

```ts
// Pure helpers — no FS, no globals
_dod_to_lower(s: string): string
_dod_to_pascal(s: string): string
  // "cost-share" → "CostShare"; "foo_bar" → "FooBar"; "" → ""

_dod_strip_source_root(rel_dir: string, roots_csv: string): string
  // longest-prefix strip; ("src/foo/bar","src/,lib/") → "foo/bar"
  // returns "" if no root matched and rel_dir was a root itself

_dod_lib_subpath(rel_dir: string): string
  // ("scripts/lib/cost") → "cost"
  // ("scripts/lib")      → ""
  // (anything else)      → ""  (caller skips prefix_flat strategy)

_dod_render_pattern(
  pattern: string,        // e.g. "{stem}.test.{ext}"
  stem: string,
  ext: string,
  stem_pascal: string,
  lib_subpath: string = ""
): string
  // sed-substitutes {stem} {ext} {stem_pascal} {lib_subpath}

_dod_candidate_paths(src_file: string): void
  // stdout: one candidate path per line, deduplicated, in strategy order
  // never touches the filesystem; pure generation

// Impure orchestrator
_dod_find_test_for(src_file: string): string | exit 1
  // stdout: first existing candidate path
  // exit 1 if none exist or src_file extension is not in the recognized set
  // case-insensitive directory match via lowercased nullglob compare
```

**Preconditions:** `src_file` is a repo-relative path; `_config_get_list` has been called at least once before `_dod_find_test_for` so config CSV vars are populated. **Postconditions:** `_dod_find_test_for` never writes to disk; never mutates globals beyond its locals.

**Error contracts:** Helpers return empty string for invalid input (never exit non-zero). `_dod_find_test_for` is the only function that signals failure via exit code.

## Data Flow

```
pipeline_verify_dod()
  │
  ├─ once: hoist 5 CSV vars via _config_get_list (cache; ~5 jq calls per invocation, not per file)
  │
  └─ for each src in $(git diff --name-only):
       ├─ extension filter (case in *.ts|*.js|...|*.sh)
       ├─ skip filter      (case in *test*|*spec*|*__tests__*|*.config.*|*.d.ts)
       ├─ _dod_find_test_for "$src"
       │    └─ _dod_candidate_paths "$src"  // generator
       │         └─ for strategy in $STRATEGIES_CSV:
       │              for dir in $TEST_DIR_NAMES_CSV:
       │                for pat in $TEST_FILENAME_PATTERNS_CSV:
       │                  emit _dod_render_pattern + path composition
       │    └─ probe each line; first FS hit wins
       └─ accounting → checks_total++; checks_passed++ or missing_tests +=
```

Performance: previous loop did 6 FS stats per source file. New loop does up to `|strategies| × |dirs| × |patterns|` ≈ `4 × 5 × 8 = 160` candidates worst case, with short-circuit. To keep this cheap, candidate generation is pure-string (no `find`, no subshells per candidate), and the FS probe is a single `[[ -f ]]` per candidate. Dedup the generator output via `awk '!seen[$0]++'` before probing.

## Error Boundaries

| Component | Errors handled | Propagation |
|---|---|---|
| `_config_get_list` | Missing key, invalid JSON, empty list | Returns CSV fallback (passed by caller); never exits non-zero |
| Pure helpers | Empty input, missing placeholders | Return empty string; caller filters empties |
| `_dod_candidate_paths` | `_dod_lib_subpath` empty → skip `prefix_flat` for that file | Continues with other strategies |
| `_dod_find_test_for` | No candidate exists | exit 1; **only signal** to `pipeline_verify_dod` |
| `pipeline_verify_dod` | `_dod_find_test_for` exit 1 | Appends to `missing_tests`; never aborts the whole DoD check |

## Alternatives Considered

1. **Inline-only extension of the hardcoded loop** — add the 2-3 missing patterns directly to lines 540-546. **Pros:** smallest diff, no config schema changes. **Cons:** doesn't fix the actual problem (different repos still need different conventions); each new repo layout requires a code change; can't override per-repo via `daemon-config.json`. **Rejected.**

2. **External tool (`find` + filename regex)** — invoke `find scripts -name "*${stem}*"` per source file and pick the closest match by Levenshtein. **Pros:** auto-discovers any layout. **Cons:** slow at scale (one `find` per file), false positives (e.g. `share.sh` matches `share-helpers.sh`), non-deterministic ordering across filesystems, harder to debug in CI. **Rejected** — DoD verification runs on every PR, so latency and determinism matter.

3. **Convention plugins (one bash function per layout)** — `_dod_pair_jest()`, `_dod_pair_shipwright_flat()`, `_dod_pair_swift()`. **Pros:** very readable, each function is small. **Cons:** can't be overridden by `daemon-config.json` without sourcing user-provided bash (security risk and breaks the static-config model); adding a new convention requires editing the lib. **Rejected** in favor of pure-data config.

4. **Hardcoded extension of the loop + rename only** (skip the config schema entirely). **Pros:** ~10 lines of change. **Cons:** punts the structural problem to the next failing repo; doesn't satisfy the issue's "configurable" requirement. **Rejected.**

## Implementation Plan

**Files to create:** none — everything lands in existing files.

**Files to modify:**
- `config/defaults.json` — insert `pipeline.dod` block (5 lists + template) between lines 43 (`command_discovery`) and 73 (closing of `pipeline`).
- `scripts/lib/config.sh` — add `_config_get_list "dotpath" [fallback_csv]` after `_config_get` (line 72). Uses `jq -r '<path> // [] | join(",")'`; falls back to fallback CSV on null/empty.
- `scripts/lib/pipeline-intelligence.sh` —
  - Above `pipeline_verify_dod` (line 509): add 5 pure helpers + `_dod_candidate_paths` + `_dod_find_test_for`.
  - Inside `pipeline_verify_dod`: hoist 5 `_config_get_list` reads to local CSV vars before the diff loop; replace lines 538-551 with a single `_dod_find_test_for "$src_file" >/dev/null 2>&1` call.
- `scripts/sw-lib-pipeline-intelligence-test.sh` — add a `_dod_find_test_for` section above the existing `pipeline_verify_dod` section with 6 behavioral + 8 unit + 3 negative assertions.
- `scripts/sw-pipeline-test.sh` — grep for the old filename; update if listed.
- `package.json` — grep for the old filename; update if listed.

**Files to rename:**
- `git mv scripts/sw-cost-share-test.sh scripts/sw-lib-cost-share-test.sh`.

**Dependencies:** none new. `jq` is already required by `_config_get`.

**Risk areas:**
- **Bash 3.2 trap** — `_dod_to_pascal` and `_dod_to_lower` must avoid `${var,,}`/`${var^^}`. Use `tr` + word-split on `-`/`_`.
- **Performance regression** — candidate generator should be string-only; only `_dod_find_test_for` probes the FS. Dedup via `awk '!seen[$0]++'` to avoid redundant stats when strategies converge on the same path.
- **Case-insensitive dir match** — must not double-match (e.g. `Tests/` and `tests/` both existing). First-hit-wins with strategy ordering keeps behavior deterministic.
- **`prefix_flat` over-applies** — must early-exit when `_dod_lib_subpath` returns empty (i.e. not under `scripts/lib/`), or it generates malformed paths for non-Shipwright files.
- **Cached CSV staleness** — config reads are hoisted per `pipeline_verify_dod` invocation, not module-load, so a `daemon-config.json` edit between runs is picked up.

## Validation Criteria

### Test Pyramid Breakdown

- **Unit tests (11)** — 8 pure-helper tests (`_dod_to_lower`, `_dod_to_pascal` × 2 inputs, `_dod_strip_source_root` × 2 inputs, `_dod_lib_subpath` × 2 inputs, `_dod_render_pattern`) + 3 negative cases on `_dod_find_test_for` (no candidate exists; unsupported extension; only skip-pattern matches).
- **Integration tests (6)** — the 6 behavioral scenarios from the issue, all against synthetic dir trees in `$TEST_TEMP_DIR/project`:
  1. Shipwright `prefix_flat`: `scripts/lib/cost/share.sh` → `scripts/sw-lib-cost-share-test.sh`.
  2. Shipwright top-level: `scripts/lib/pipeline-intelligence.sh` → `scripts/sw-lib-pipeline-intelligence-test.sh`.
  3. Mirror: `src/foo/bar.ts` → `tests/foo/bar.test.ts`.
  4. Co-located Jest: `src/util.ts` → `src/__tests__/util.test.ts`.
  5. Case-insensitive Swift: `Sources/Foo.swift` → `Tests/FooTests.swift`.
  6. Override: `.claude/daemon-config.json` with custom `prefix_flat_template` takes precedence over default.
- **Regression tests (3)** — `sw-lib-pipeline-intelligence-test.sh` existing `pipeline_verify_dod` assertions (lines 181-200); `sw-postmortem-460-test.sh`; renamed `sw-lib-cost-share-test.sh`.

### Coverage Targets

- Pure helpers: 100% branch coverage (each is small enough to exhaust).
- `_dod_find_test_for`: every `search_strategy` exercised by ≥1 positive integration test; every placeholder (`{stem}`, `{ext}`, `{stem_pascal}`, `{lib_subpath}`) hit by ≥1 rendered pattern.
- Bash 3.2 compatibility: `shellcheck scripts/lib/pipeline-intelligence.sh scripts/lib/config.sh` exits 0; grep guard in CI for `declare -A`, `\${[^}]*,,\}`, `\${[^}]*\^\^\}`, `readarray`.

### Critical Paths to Test

- **Happy path:** Shipwright `prefix_flat` resolution → test 1 above.
- **Error case 1:** Source file with no test → `_dod_find_test_for` exits non-zero; `pipeline_verify_dod` records in `missing_tests` and `pass_rate < 100`.
- **Error case 2:** Malformed `daemon-config.json` → `_config_get_list` returns fallback CSV; `_dod_find_test_for` still works against `config/defaults.json` defaults; no shell crash.
- **Edge 1:** Case-insensitive Swift `Tests/` dir under PascalCase rename (test 5).
- **Edge 2:** Empty source-root prefix — `foo.ts` at repo root → `__tests__/foo.test.ts` (mirror with empty `rel_path`).

### Acceptance Gates

- [ ] `bash scripts/sw-lib-pipeline-intelligence-test.sh` exits 0 with all existing + 17 new assertions passing.
- [ ] `bash scripts/sw-lib-cost-share-test.sh` exits 0 after rename (file resolves under `prefix_flat` strategy).
- [ ] `bash scripts/sw-postmortem-460-test.sh` exits 0 (regression).
- [ ] `npm test` exits 0 with no new failures.
- [ ] `shellcheck scripts/lib/pipeline-intelligence.sh scripts/lib/config.sh` exits 0.
- [ ] `jq -e '.pipeline.dod.test_dir_names | length == 5' config/defaults.json` exits 0.
- [ ] `git diff --name-status main...HEAD` shows `R` (rename) for `sw-cost-share-test.sh`, not `A` + `D`.
- [ ] `bash -c 'source scripts/lib/pipeline-intelligence.sh && _dod_find_test_for scripts/lib/cost/share.sh' | grep -q sw-lib-cost-share-test.sh`.
- [ ] DoD verifier reports `pass_rate: 100` on this branch: `jq -e ".pass_rate == 100" .claude/pipeline-artifacts/dod-verification.json`.
