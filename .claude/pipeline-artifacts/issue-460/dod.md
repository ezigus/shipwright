\1- `cost-breakdown.json` carries `schema_version: 1` on every new generation (verified by `sw-cost-test.sh`).
\1- Every CI pipeline run (success **and** failure) produces a dedicated GitHub Actions artifact named `cost-breakdown-issue-<N>-run-<run_id>-attempt-<attempt>` with 90-day retention.
\1- `cost_fetch_remote_breakdowns` and `cost_list_remote_breakdowns` exist in `scripts/lib/cost/artifact-fetch.sh`, are callable from `sw-cost.sh breakdown-fetch`, and behave idempotently.
\1- `--bootstrap-baselines` works on a fresh machine: starting a pipeline with zero local baselines fetches at least N remote artifacts and populates `~/.shipwright/baselines/` such that `baseline_classify` returns non-`NEW` for recently-seen stages.
\1- `shipwright doctor` reports PASS on the two new checks.
\1- All test suites green: `npm test`, `sw-cost-test.sh`, `sw-cost-artifact-test.sh`, `sw-pipeline-test.sh`, `sw-doctor.sh`.
\1- Default behaviour (no flag/env set) is byte-identical to today on every existing field — confirmed by diffing a normal pipeline run's `cost-breakdown.json` (only addition: `schema_version`).
\1- `CLAUDE.md` "Runtime State" lists the new artifact name.
\1- PR description explains the change is additive and cross-machine bootstrap is opt-in.

---
