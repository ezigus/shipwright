## Pipeline Modularization Strategy: Shell Orchestration Decomposition

Approach for extracting tightly-coupled shell scripts into maintainable modules while preserving orchestration correctness.

### Extraction Boundaries

1. **State Manager Module** (`sw-pipeline-state.sh`)
   - Single responsibility: persist/read/validate pipeline state (JSON)
   - Operations: `state_read()`, `state_write()`, `state_validate()`, `state_update_field()`
   - Atomicity: write to temp file, then `mv` (not direct echo) to prevent corruption on interrupt
   - Validation: schema check before every write; error on malformed state

2. **Stage Executor Module** (`sw-pipeline-stage-executor.sh`)
   - Single responsibility: execute one stage with hooks and error handling
   - Input: stage name, pipeline state (as JSON)
   - Output: success/failure, updated state
   - Hooks: pre-stage, post-stage, on-error (call but don't fail if missing)
   - No side effects on caller's variables; use subshells for isolation

3. **Orchestrator** (`sw-pipeline.sh`)
   - Remaining responsibility: stage sequencing, state transitions, CLI interface
   - Calls state manager to read current stage
   - Calls executor for each stage
   - Updates state after each executor completes
   - Should not contain stage-specific logic

### Testability Patterns

- **State module**: Mock filesystem, test JSON parsing/validation with edge cases (truncated JSON, missing fields, invalid types)
- **Executor module**: Mock hooks and external commands; verify it calls hooks in order and propagates errors
- **Orchestrator**: Mock state and executor modules; verify stage sequencing and state transitions
- Use `bats-core` or similar for bash testing; run with `bash -x` to debug test failures

### Verification Checklist

- [ ] All existing tests pass (no behavioral regression)
- [ ] New modules have >80% line coverage (checked with `bash-coverage` or similar)
- [ ] Modules can be sourced independently without side effects
- [ ] State format is documented (JSON schema)
- [ ] All public functions are documented (comment with input/output)
- [ ] sw-pipeline.sh reduced below 1500 lines
- [ ] No module imports other modules except orchestrator imports state + executor
