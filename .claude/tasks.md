# Tasks — Reduce build-loop iteration ceiling — current 45/cycle × 3 cycles = 135 invocations is excessive

## Status: In Progress
Pipeline: autonomous | Branch: shipwright/issue-605

## Checklist
- [ ] Task 1: Lower `pipeline.build_test_retries` 3→1 in `config/defaults.json`
- [ ] Task 2: Lower `EXTENSION_SIZE` 5→3 and `MAX_EXTENSIONS` 3→1 in `scripts/sw-loop.sh`
- [ ] Task 3: Update per-complexity `max_iterations` ladder in `scripts/sw-triage.sh` (heuristic + recruit-derived branches)
- [ ] Task 4: Update `team_max_iterations` derivation in `scripts/sw-recruit.sh`
- [ ] Task 5: Update heuristic ladder and recruit branch in `scripts/sw-pm.sh`
- [ ] Task 6: Clamp PM risk additions to ≤20 (bash 3.2-compatible if/else)
- [ ] Task 7: Tighten empty-sample ceilings in `scripts/sw-self-optimize.sh` (10/15/20 instead of 10/20/30)
- [ ] Task 8: Lower `sweep.retry_max_iterations` 25→20 and `sweep.stuck_retry_max_iterations` 30→23 in `config/policy.json`
- [ ] Task 9: Add `EXTENSION_SIZE=3` / `MAX_EXTENSIONS=1` assertions in `scripts/sw-loop-test.sh`
- [ ] Task 10: Add smoke check in `scripts/sw-e2e-smoke-test.sh` verifying new ceilings end-to-end
- [ ] Task 11: Run loop/pipeline/convergence/smoke tests and verify they pass
- [ ] Task 12: Hand-verify worst-case math: `20 + 1×3 = 23` per cycle, `1+1 = 2` cycles, `23×2 = 46` invocations
- [ ] `bash scripts/sw-loop-test.sh` exits 0 with new `EXTENSION_SIZE=3` and `MAX_EXTENSIONS=1` assertions present {auto:other:bash scripts/sw-loop-test.sh}
- [ ] `bash scripts/sw-pipeline-test.sh` exits 0 {auto:other:bash scripts/sw-pipeline-test.sh}
- [ ] `bash scripts/sw-lib-loop-convergence-test.sh` exits 0 {auto:other:bash scripts/sw-lib-loop-convergence-test.sh}
- [ ] `bash scripts/sw-e2e-smoke-test.sh` exits 0 with ceiling-respect assertion {auto:other:bash scripts/sw-e2e-smoke-test.sh}
- [ ] `npm test` exits 0 {auto:tests}
- [ ] `jq -e '.pipeline.build_test_retries == 1' config/defaults.json` exits 0 {auto:other:jq -e '.pipeline.build_test_retries == 1' config/defaults.json}
- [ ] `EXTENSION_SIZE=3` and `MAX_EXTENSIONS=1` present in `scripts/sw-loop.sh` {auto:other:bash -c "grep -qE '^EXTENSION_SIZE=3' scripts/sw-loop.sh && grep -qE '^MAX_EXTENSIONS=1' scripts/sw-loop.sh"}
- [ ] `shellcheck scripts/sw-loop.sh scripts/sw-triage.sh scripts/sw-pm.sh scripts/sw-recruit.sh scripts/sw-self-optimize.sh` exits 0 {auto:lint}

## Notes
- Generated from pipeline plan at 2026-05-21T10:31:41Z
- Pipeline will update status as tasks complete
