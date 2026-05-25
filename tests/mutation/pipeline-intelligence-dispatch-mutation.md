# Mutation Document: pipeline-intelligence.sh dispatch

**Critical file:** `scripts/lib/pipeline-intelligence.sh` (dispatch functions)

## Mutation 1: Stage skip logic inversion

**Condition mutated:** Invert `pipeline_should_skip_stage` return value.
**Expected test:** `sw-lib-pipeline-intelligence-test.sh` — skip logic correctly gates stage execution.
**Verification bash line:**
```bash
# Mutate: invert return value
# sed_inplace 's/return 0$/return 1/; s/return 1$/return 0/' scripts/lib/pipeline-intelligence.sh
# Then run: bash scripts/sw-lib-pipeline-intelligence-test.sh; echo "exit: $?"
```

## Mutation 2: Compound quality guard removal

**Condition mutated:** Remove `if ! type stage_compound_quality` guard, allowing duplicate definition.
**Expected test:** `sw-lib-pipeline-intelligence-test.sh` — correct version of stage_compound_quality is called.
**Verification bash line:**
```bash
# Mutate: remove guard
# sed_inplace '/if ! type stage_compound_quality/d; /fi.*end fallback/d' scripts/lib/pipeline-intelligence.sh
# Then run: bash scripts/sw-lib-pipeline-stages-review-test.sh; echo "exit: $?"
```

## Mutation 3: Audit cycle counter

**Condition mutated:** Never increment cycle counter in compound quality loop.
**Expected test:** `sw-lib-pipeline-intelligence-test.sh` — loop terminates within max cycles.
**Verification bash line:**
```bash
# Mutate: prevent cycle increment
# sed_inplace 's/_cycles_executed=$(( _cycles_executed + 1 ))/_cycles_executed=$_cycles_executed/' scripts/lib/pipeline-intelligence.sh
# Then run: bash scripts/sw-lib-pipeline-intelligence-test.sh; echo "exit: $?"
# Expected: test detects infinite loop (timeout or cycle cap failure)
```
