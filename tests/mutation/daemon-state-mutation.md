# Mutation Document: daemon-state.sh

**Critical file:** `scripts/lib/daemon-state.sh`

## Mutation 1: State file write atomicity

**Condition mutated:** Remove atomic write (tmp+mv) from `daemon_save_state`.
**Expected test:** `sw-lib-daemon-state-test.sh` — assert that state file is not corrupted if write is interrupted.
**Verification bash line:**
```bash
# Mutate: replace atomic write with direct write
# sed_inplace 's/mv "\$_tmp" "\$STATE_FILE"/echo "MUTATED" > "$STATE_FILE"/' scripts/lib/daemon-state.sh
# Then run: bash scripts/sw-lib-daemon-state-test.sh; echo "exit: $?"
# Expected: non-zero exit (test catches corruption)
```

## Mutation 2: Lock file guard bypass

**Condition mutated:** Remove flock from state write critical section.
**Expected test:** `sw-lib-daemon-state-test.sh` — concurrent write test detects race.
**Verification bash line:**
```bash
# Mutate: comment out flock call
# sed_inplace 's/flock -w 5 200/: # flock -w 5 200/' scripts/lib/daemon-state.sh
# Then run: bash scripts/sw-lib-daemon-state-test.sh; echo "exit: $?"
```

## Mutation 3: Status field validation

**Condition mutated:** Accept any string as STATUS value (remove validation).
**Expected test:** `sw-lib-daemon-state-test.sh` — invalid status check.
**Verification bash line:**
```bash
# Mutate: remove status validation
# sed_inplace '/valid_statuses/,/esac/d' scripts/lib/daemon-state.sh
# Then run: bash scripts/sw-lib-daemon-state-test.sh; echo "exit: $?"
```
