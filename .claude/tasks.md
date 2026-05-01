# Tasks — Stuckness detector floods ruflo with redundant subprocess spawns (throttle writes)

## Status: In Progress
Pipeline: autonomous | Branch: fix/stuckness-detector-floods-ruflo-with-red-447

## Checklist
- [ ] Read `scripts/lib/loop-convergence.sh:336-411` and confirm only lines 362–366 and 383–386 spawn ruflo subprocesses
- [ ] Add module-scope `_STUCKNESS_RECALL_CACHE` and `_STUCKNESS_RECALL_CACHE_FP` vars with `:=` defaults
- [ ] Add `_stuckness_fingerprint` helper (signals + reasons → md5[0..11], with md5/md5sum fallback)
- [ ] Compute fingerprint and read prior fingerprint inside the `signals >= 2` gate
- [ ] Wrap `ruflo_store` call (lines 362–366) — only invoke when fingerprint differs
- [ ] Wrap `ruflo_recall` call (lines 383–386) — reuse cache on hit, populate on miss
- [ ] Atomically write fingerprint via tmp+mv after a non-skipped call
- [ ] Preserve `emit_event` (line 360) and `warn` (line 368) — verify no behavior change
- [ ] Preserve `|| true` on both ruflo calls (fail-open on subprocess error)
- [ ] Verify Bash 3.2 compatibility (no `declare -A`, no `${var,,}`, no `readarray`)
- [ ] Create `scripts/sw-lib-loop-convergence-test.sh` modeled on `sw-lib-loop-restart-test.sh`
- [ ] Test 1: first detection — store + recall called once, fingerprint file written
- [ ] Test 2: second identical detection — store + recall NOT called, cached recall returned
- [ ] Test 3: detection with changed reasons — store + recall fire again, fingerprint updated
- [ ] Test 4: fingerprint file deleted — fail-open, both calls fire
- [ ] Test 5: `emit_event` and `warn` fire every iteration regardless of throttle
- [ ] Run `bash scripts/sw-lib-loop-restart-test.sh` and `bash scripts/sw-loop-test.sh` — no regression
- [ ] Run `./scripts/sw-pipeline-test.sh` — no adjacent regressions
- [ ] Run `npm test` — vitest suite still passes
- [ ] On a stuck pipeline, `ruflo memory store` is called at most once per distinct signal pattern (acceptance criterion #1).

## Notes
- Generated from pipeline plan at 2026-05-01T16:30:40Z
- Pipeline will update status as tasks complete
