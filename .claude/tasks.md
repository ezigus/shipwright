# Tasks — fix(harness): no memory budget guard — concurrent pipelines OOM the host

## Status: In Progress
Pipeline: autonomous | Branch: fix/fix-harness-no-memory-budget-guard-concu-445

## Checklist
- [x] Helper functions added to `sw-pipeline.sh`
- [x] Default thresholds + env-override + integer validation
- [x] `pipeline_start` calls gate + write + post-write race recheck
- [x] `pipeline_resume` re-claims a slot through the same gate
- [x] EXIT trap calls `release_active_pipeline_lock` idempotently (safe even when start was refused before write)
- [x] `sw-doctor.sh` lists active pipelines and free memory
- [x] Unit tests in `sw-pipeline-memory-guard-test.sh` (18 cases)
- [x] E2E tests #20–23 in `sw-e2e-smoke-test.sh`
- [ ] Re-run unit + e2e suites in CI to confirm green on this branch
- [ ] Manually verify `shipwright doctor` output in three states: zero locks, one live lock, one stale lock
- [ ] Confirm `CHANGELOG.md` entry exists; add if missing
- [ ] Spot-check `docs/` for stale "no concurrency awareness" claims
- [x] Lock at `~/.shipwright/active-pipelines/<pid>.json` written on `start`/`resume`, deleted on EXIT (idempotent)
- [x] Concurrency cap: at most one active pipeline per host (overridable via `SHIPWRIGHT_MAX_ACTIVE_PIPELINES`); enforced after stale reaping
- [x] Memory floor: refuse start when `<4 GB` free (overridable via `SHIPWRIGHT_MIN_FREE_GB`); cross-platform probe; fail-closed on probe failure
- [x] Refusal diagnostic names blocking pipeline's PID, `started_at`, `issue_or_goal`, `repo`, `pipeline_template`, and policy limits
- [x] `shipwright doctor` lists active pipelines + free memory; warns at capacity or below floor
- [x] Unit + e2e tests pass
- [ ] CI re-run on this branch confirms green
- [ ] CHANGELOG entry added if missing

## Notes
- Generated from pipeline plan at 2026-04-26T03:18:01Z
- Pipeline will update status as tasks complete
