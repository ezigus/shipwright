# What's Next — Gaps, Not Fully Implemented, Not Integrated, E2E Audit

**Status:** 2026-02-16  
**Companion to:** [docs/AGI-PLATFORM-PLAN.md](AGI-PLATFORM-PLAN.md)

---

## 1. Still broken or risky

| Item                                         | What                                                                                                                                                                                    | Fix                                                                                           |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Platform-health workflow threshold check** | ~~Report step used string comparison for threshold.~~ **Fixed:** Now normalizes to numeric with default 0.                                                                              | Done.                                                                                         |
| **policy.sh when REPO_DIR not set**          | If a script is run from a different cwd (e.g. CI from repo root), `git rev-parse --show-toplevel` may point to a different repo.                                                        | Already uses SCRIPT_DIR/.. when SCRIPT_DIR is set; document that callers must set SCRIPT_DIR. |
| **Daemon get_adaptive_heartbeat_timeout**    | When policy has no entry for a stage, we fall back to case statement only when `policy_get` is not available; when policy exists but stage is missing we keep HEALTH_HEARTBEAT_TIMEOUT. | Verified: logic is correct (policy stage → else case → HEALTH_HEARTBEAT_TIMEOUT).             |

---

## 2. Not fully implemented

| Item                                       | What                                                                                                                                                                                          | Next step                                                                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| ~~**Phase 3 libs not sourced**~~           | **Done.** `pipeline-quality.sh` sourced by `sw-pipeline.sh` and `sw-quality.sh`; `daemon-health.sh` sourced by `sw-daemon.sh`.                                                                | Wired and verified.                                                                             |
| **Policy JSON Schema validation**          | We run `jq empty` in CI. Optional `ajv` step exists in platform-health workflow but is untested.                                                                                              | Trigger platform-health workflow once to validate; or document "schema is reference only".      |
| ~~**Sweep workflow still hardcoded**~~     | **Done.** Sweep workflow now checks out repo, reads `config/policy.json`, and exports `STUCK_THRESHOLD_HOURS`, `RETRY_TEMPLATE`, `RETRY_MAX_ITERATIONS`, `STUCK_RETRY_MAX_ITERATIONS` to env. | Wired.                                                                                          |
| ~~**Helpers adoption (Phase 1.4)**~~       | **Done.** 4 scripts migrated: `sw-hygiene.sh`, `sw-doctor.sh`, `sw-pipeline.sh`, `sw-quality.sh`. More in progress.                                                                           | Continue migrating remaining scripts in batches.                                                |
| **Monolith decomposition (Phase 3.1–3.4)** | Pipeline stages, pipeline quality gate, daemon poll loop, daemon health are **not** extracted into separate sourced files. Line counts unchanged (8600+ / 6000+).                             | Defer or do incrementally: extract one module (e.g. pipeline quality gate block) and source it. |

---

## 3. Not integrated

| Item                             | What                                                                                                                                              | Next step                                                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| ~~**pipeline-quality.sh**~~      | **Done.** Sourced by `sw-pipeline.sh` and `sw-quality.sh`; duplicate policy_get for thresholds removed.                                           | Wired.                                                                                                       |
| ~~**daemon-health.sh**~~         | **Done.** Sourced by `sw-daemon.sh`; `get_adaptive_heartbeat_timeout` calls `daemon_health_timeout_for_stage` when loaded.                        | Wired.                                                                                                       |
| **Strategic + platform-hygiene** | Strategic reads `.claude/platform-hygiene.json` when present but there is no automated run of `hygiene platform-refactor` before strategic in CI. | Optional: add a job that runs platform-refactor then strategic (e.g. in shipwright-strategic.yml or patrol). |
| ~~**Test suite and policy**~~    | **Done.** Policy read test added to `sw-hygiene-test.sh` (Test 12): verifies `policy_get` reads from config and returns default when key missing. | Covered.                                                                                                     |

---

## 4. Not audited E2E

| Item                                | What                                                                                                                           | Next step                                                                                                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Pipeline E2E with policy**        | E2E integration test runs pipeline but does not assert that coverage/quality thresholds come from policy.                      | Add a case: set policy.json with a custom threshold, run pipeline through compound_quality (or quality gate), assert threshold used (e.g. from logs or exit behavior). |
| **Daemon E2E with policy**          | No test runs daemon with policy and checks POLL_INTERVAL or health timeouts.                                                   | Add daemon test that loads config + policy and asserts POLL_INTERVAL (or equivalent) matches policy.                                                                   |
| **Platform-health workflow E2E**    | Workflow has not been run in CI yet (new file). Possible issues: path to scripts, `npm ci` vs script-only, permissions.        | Trigger workflow (workflow_dispatch) and fix any path/permission errors.                                                                                               |
| **Doctor with no platform-hygiene** | When `.claude/platform-hygiene.json` is missing, doctor shows "Platform hygiene not run". Not wrong, but we never auto-run it. | Optional: doctor could run `hygiene platform-refactor` once and then show section (add flag `--skip-platform-scan` to preserve current fast behavior).                 |
| **Full npm test with policy**       | `npm test` runs 98 suites; none specifically load policy or assert policy-driven behavior.                                     | Run `npm test` after policy changes to ensure no regressions; add one policy-aware test in hygiene or a new policy-test.sh.                                            |

---

## 5. Summary checklist

- [x] **Wire or remove** pipeline-quality.sh and daemon-health.sh — sourced in pipeline, quality, daemon.
- [ ] **Policy schema** — Optional ajv step exists in CI; trigger once to validate or document as reference-only.
- [x] **Sweep** — Workflow reads policy.json and exports env vars.
- [x] **Helpers** — 4 scripts migrated (hygiene, doctor, pipeline, quality); continuing batch migration.
- [x] **Test** — Policy read test in hygiene-test.sh (Test 12).
- [ ] **E2E** — Run platform-health workflow once; optionally add pipeline/daemon E2E with policy.
- [ ] **TODO/FIXME/HACK** — Phase 4: triage backlog (issues or "accepted tech debt" comments); run dead-code and reduce fallbacks over time.

---

## References

- [AGI-PLATFORM-PLAN.md](AGI-PLATFORM-PLAN.md) — Phases and success criteria.
- [PLATFORM-TODO-BACKLOG.md](PLATFORM-TODO-BACKLOG.md) — TODO/FIXME/HACK triage.
- [config-policy.md](config-policy.md) — Policy usage and schema.
