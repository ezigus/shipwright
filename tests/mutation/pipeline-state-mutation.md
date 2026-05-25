# Mutation Document: pipeline-state.sh

**Critical file:** `scripts/lib/pipeline-state.sh`

## Mutation 1: Atomic write removed

**Condition mutated:** Replace tmp+mv pattern in `write_state` with direct write.
**Expected test:** `sw-lib-pipeline-state-test.sh` — state file integrity under concurrent writes.
**Verification bash line:**
```bash
# Mutate: remove atomic write
# sed_inplace 's/mv "\$tmp_state" "\$STATE_FILE"/cat "$tmp_state" > "$STATE_FILE"; rm "$tmp_state"/' scripts/lib/pipeline-state.sh
# Then run: bash scripts/sw-lib-pipeline-state-test.sh; echo "exit: $?"
```

## Mutation 2: Stage status tracking

**Condition mutated:** Skip `set_stage_status` call in `mark_stage_complete`.
**Expected test:** `sw-lib-pipeline-state-test.sh` — completed stages appear in stage list.
**Verification bash line:**
```bash
# Mutate: comment out stage status update
# sed_inplace '/set_stage_status/s/^/# MUTATED /' scripts/lib/pipeline-state.sh
# Then run: bash scripts/sw-lib-pipeline-state-test.sh; echo "exit: $?"
```

## Mutation 3: ORIGINAL_GOAL bootstrap

**Condition mutated:** Skip ORIGINAL_GOAL bootstrap in `write_state`.
**Expected test:** `sw-lib-pipeline-state-test.sh` — original goal preserved across resume.
**Verification bash line:**
```bash
# Mutate: remove ORIGINAL_GOAL bootstrap
# sed_inplace '/ORIGINAL_GOAL.*GOAL/s/^/# MUTATED /' scripts/lib/pipeline-state.sh
# Then run: bash scripts/sw-lib-pipeline-state-test.sh; echo "exit: $?"
```
