# Mutation Document: ruflo bridge

**Critical file:** `scripts/lib/ruflo-adapter.sh` (ruflo bridge integration)

## Mutation 1: Circuit breaker bypass

**Condition mutated:** Remove circuit breaker check; always attempt ruflo calls even when disabled.
**Expected test:** `sw-ruflo-adapter-test.sh` — circuit breaker prevents calls after timeout.
**Verification bash line:**
```bash
# Mutate: remove RUFLO_AVAILABLE check
# sed_inplace 's/\[\[ "\${RUFLO_AVAILABLE:-false}" == "true" \]\]/true/' scripts/lib/ruflo-adapter.sh
# Then run: bash scripts/sw-ruflo-adapter-test.sh; echo "exit: $?"
```

## Mutation 2: EXIT trap chaining removal

**Condition mutated:** Remove EXIT trap chaining; overwrite existing trap.
**Expected test:** `sw-ruflo-adapter-test.sh` — caller's EXIT trap still runs after ruflo cleanup.
**Verification bash line:**
```bash
# Mutate: revert to non-chaining trap
# sed_inplace 's/trap.*_existing_trap.*ruflo_cleanup.*/trap '"'"'ruflo_cleanup 2>\/dev\/null || true'"'"' EXIT/' scripts/lib/ruflo-adapter.sh
# Then run: bash scripts/sw-ruflo-adapter-test.sh; echo "exit: $?"
```

## Mutation 3: Fail-open bypass

**Condition mutated:** Make ruflo failures propagate (remove fail-open).
**Expected test:** `sw-ruflo-bridge-test.sh` — pipeline continues when ruflo is unavailable.
**Verification bash line:**
```bash
# Mutate: remove fail-open pattern
# sed_inplace 's/2>\/dev\/null || echo/2>\/dev\/null/' scripts/lib/ruflo-adapter.sh
# Then run: RUFLO_AVAILABLE=false bash scripts/sw-ruflo-bridge-test.sh; echo "exit: $?"
```
