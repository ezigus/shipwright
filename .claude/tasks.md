# Tasks — Stuckness detector floods ruflo with redundant subprocess spawns (throttle writes)

## Status: Complete
Pipeline: autonomous | Branch: fix/stuckness-detector-floods-ruflo-with-red-447

## Checklist
- [x] **Unit test** — `scripts/sw-lib-loop-convergence-test.sh` (14/14 assertions): first detection, identical detection, changed reasons re-arms, missing fingerprint fail-open, observability preserved, JSON escaping
- [x] **Regression test** — `bash scripts/sw-lib-loop-restart-test.sh` (28/28 pass)
- [x] **Regression test** — `bash scripts/sw-loop-test.sh` (237/237 pass)
- [x] **Pipeline test** — `./scripts/sw-pipeline-test.sh` (72/72 pass)
- [x] **Wire convergence test into npm test** — added to `package.json` `scripts.test`
- [x] Read `scripts/lib/loop-convergence.sh:336-411` and confirm only the two call sites spawn ruflo subprocesses
- [x] Add module-scope `_STUCKNESS_RECALL_CACHE` and `_STUCKNESS_RECALL_CACHE_FP` vars with `:=` defaults
- [x] Add `_stuckness_fingerprint` helper (signals + reasons → md5[0..11], with cksum fallback)
- [x] Compute fingerprint and read prior fingerprint inside the `signals >= 2` gate
- [x] Wrap `ruflo_store` call — only invoke when fingerprint differs
- [x] Wrap `ruflo_recall` call — reuse cache on hit, populate on miss
- [x] Atomically write fingerprint via tmp+mv after a non-skipped call
- [x] Preserve `emit_event` and `warn` — verified outside the throttle gate
- [x] Preserve `|| true` on both ruflo calls (fail-open on subprocess error)
- [x] Verify Bash 3.2 compatibility (no `declare -A`, no `${var,,}`, no `readarray`)
- [x] Create `scripts/sw-lib-loop-convergence-test.sh` with 6 test cases
- [x] Test 1: first detection — store + recall called once, fingerprint file written
- [x] Test 2: identical detection — store + recall NOT called (cache hit)
- [x] Test 3: changed reasons — store + recall fire again, fingerprint updated
- [x] Test 4: fingerprint file deleted — fail-open path exercised

## Notes
- Generated from pipeline plan at 2026-05-01T20:43:10Z
- Pipeline will update status as tasks complete
