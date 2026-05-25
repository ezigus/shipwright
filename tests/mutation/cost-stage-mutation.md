# Mutation Document: cost/stage.sh

**Critical file:** `scripts/lib/cost/stage.sh`

## Mutation 1: flock fail-open reversion

**Condition mutated:** Revert `flock -w 5 200` to fail-open (`|| true`) pattern.
**Expected test:** `sw-lib-cost-share-test.sh` — concurrent cost append test detects data loss.
**Verification bash line:**
```bash
# Mutate: revert to fail-open
# sed_inplace 's/if ! flock -w 5 200/flock -w 5 200 2>/dev/null || true; if false/' scripts/lib/cost/stage.sh
# Then run: bash scripts/sw-lib-cost-share-test.sh; echo "exit: $?"
```

## Mutation 2: Cost JSONL append atomicity

**Condition mutated:** Replace `>>` append with `>` overwrite in cost sidecar write.
**Expected test:** `sw-lib-cost-share-test.sh` — previous cost entries preserved.
**Verification bash line:**
```bash
# Mutate: use overwrite instead of append
# sed_inplace 's/echo "\$_line" >> "\$_sidecar"/echo "$_line" > "$_sidecar"/' scripts/lib/cost/stage.sh
# Then run: bash scripts/sw-lib-cost-share-test.sh; echo "exit: $?"
```

## Mutation 3: Cost calculation accuracy

**Condition mutated:** Use wrong token pricing formula.
**Expected test:** `sw-lib-cost-share-test.sh` — cost total validation.
**Verification bash line:**
```bash
# Mutate: multiply cost by 2
# sed_inplace 's/tonumber/tonumber * 2/' scripts/lib/cost/stage.sh
# Then run: bash scripts/sw-lib-cost-share-test.sh; echo "exit: $?"
```
