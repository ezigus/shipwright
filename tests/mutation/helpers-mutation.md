# Mutation Document: helpers.sh

**Critical file:** `scripts/lib/helpers.sh`

## Mutation 1: NO_COLOR guard removal

**Condition mutated:** Remove NO_COLOR guard, always emit color codes.
**Expected test:** `sw-lib-helpers-test.sh` — NO_COLOR=1 produces plain output.
**Verification bash line:**
```bash
# Mutate: remove NO_COLOR check
# sed_inplace '/NO_COLOR/,/fi/d' scripts/lib/helpers.sh
# Then run: NO_COLOR=1 bash scripts/sw-lib-helpers-test.sh; echo "exit: $?"
```

## Mutation 2: emit_event JSON corruption

**Condition mutated:** Remove JSON field quoting in emit_event.
**Expected test:** `sw-lib-helpers-test.sh` — emitted events are valid JSON.
**Verification bash line:**
```bash
# Mutate: remove quotes around JSON field values
# sed_inplace 's/\\\\\"${key}\\\\\":\\\\\"\${val}\\\\\"/\${key}:\${val}/' scripts/lib/helpers.sh
# Then run: bash scripts/sw-lib-helpers-test.sh; echo "exit: $?"
```

## Mutation 3: error() stderr redirect removal

**Condition mutated:** Send error() output to stdout instead of stderr.
**Expected test:** `sw-lib-helpers-test.sh` — error messages appear on stderr.
**Verification bash line:**
```bash
# Mutate: remove >&2
# sed_inplace 's/ >&2//' scripts/lib/helpers.sh
# Then run: bash scripts/sw-lib-helpers-test.sh 2>/dev/null; echo "exit: $?"
# Expected: error message missing from stderr; test fails
```
