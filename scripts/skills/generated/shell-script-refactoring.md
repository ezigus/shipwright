# Shell Script Refactoring: Monolith to Modules

When extracting a large bash script into modular stage libraries:

## Module Interface Contract

Each stage module must follow this pattern for orchestrator compatibility:

```bash
VERSION="1.0.0"  # Sync with main package.json

stage_init() {
  local stage=$1 version=$2
  # Initialize stage resources, verify dependencies
}

stage_run() {
  local input_state=$1 config=$2 environment=$3
  # Core stage logic; set -euo pipefail in effect
  # Read from input_state, write to stdout + files
  # Exit codes: 0=success, 1=fatal, 2=retriable
}

stage_cleanup() {
  local stage=$1
  # Remove temp files, release locks, kill subprocesses
  # Must be safe to call multiple times
}

trap 'stage_cleanup "$stage_name"' EXIT
```

## State Threading Between Stages

**CRITICAL**: Monolith uses memory (global variables); modules don't. Transfer state via:
- JSON state files (output from stage N becomes input to stage N+1)
- Stdout captures (for short data)
- Environment variables (for configuration)
- Never global shell variables across module boundaries

```bash
# Orchestrator pattern
for stage in intake plan design build test review pr merge deploy validate monitor; do
  source "lib/stages/$stage.sh"
  stage_init "$stage" "$VERSION"
  stage_run "$previous_state_file" "$config" | tee "$current_state_file"
  [ $? -eq 0 ] || { error "Stage $stage failed"; exit 1; }
done
```

## Helper Functions: No Duplication

Extract ALL shared helpers to lib/common.sh:
- `info()`, `success()`, `warn()`, `error()` — output
- `emit_event()` — event logging
- `read_json()`, `write_json()` — JSON handling
- Stage modules source lib/common.sh, not redefine helpers

## Error Handling Consistency

- All modules: `set -euo pipefail` at top
- Consistent exit codes: 0=success, 1=fatal error, 2=retriable
- All errors logged via `error()` function to event log
- Each module cleans up via trap, orchestrator verifies cleanup
- No silent failures (must see errors in logs)

## Testing Module Extraction

**Unit Tests** (per stage module):
```bash
# test/stages/stage-<name>.test.sh
source lib/stages/<name>.sh
source lib/common.sh

# Test happy path
stage_init "test" "1.0"
stage_run "./fixtures/input.json" "./fixtures/config.json"
assert_equals $? 0

# Test error paths
stage_run "./fixtures/missing.json" "./fixtures/config.json"
assert_equals $? 1  # Should fail gracefully
```

**Integration Tests** (orchestrator + all stages):
```bash
# test/pipeline.integration.test.sh
# Run old monolith vs new orchestrator, diff outputs
./scripts/sw-pipeline.sh --goal "test" > old.json
./scripts/sw-pipeline-new.sh --goal "test" > new.json
diff old.json new.json  # Must be identical
```

**REQUIREMENT**: All existing pipeline tests must pass without modification. If tests fail, implementation is incomplete—don't change tests.

## Extraction Checklist

- [ ] Map all helper functions each stage uses → extract to lib/common.sh
- [ ] Define clear input/output/exit-code contracts for each of 12 stages
- [ ] Extract each stage to lib/stages/<name>.sh with trap for cleanup
- [ ] Update main orchestrator to source modules and call stage_run in sequence
- [ ] Verify VERSION variable at top of each module, sync in version bump
- [ ] Add unit tests for each stage module (test/stages/<name>.test.sh)
- [ ] Run existing pipeline tests—must all pass unchanged
- [ ] Diff monolith output vs modular output—must be byte-identical
- [ ] Measure: main orchestrator should be <500 lines
- [ ] Documentation: update with stage architecture diagram

## Common Pitfalls to Avoid

1. **State Loss**: Don't assume variables survive across `source` calls in different processes; use files
2. **Incomplete Helper Extraction**: Every function must go to lib/common.sh or be inlined; no partial duplication
3. **Missing Cleanup in Modules**: If monolith cleans temp files implicitly, modules must do it in trap
4. **Test Modification**: Don't change tests to make them pass; fix the implementation
5. **Variable Scope Leakage**: Module functions inherit orchestrator environment; be explicit about what they read/modify
6. **Error Recovery Lost**: Monolith may retry stages or skip stages on error; document this in orchestrator
