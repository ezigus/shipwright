# ADR-208: Tiered Test Execution and Merge-Gating Policy

**Status:** Accepted  
**Date:** 2026-05-25

## Context
CI runs 130+ test scripts in one undifferentiated loop with no per-tier breakdown. Real e2e tests run only on a weekly cron — never on PRs. Fork PRs silently skip integration tests when secrets are absent. There is no bash coverage measurement. The stated 70/20/10 test pyramid is aspirational; reality is ~82% mocked-unit, ~13% mocked-feature, ~3% true e2e.

## Decision

### Tier definitions
- **unit/** — no external processes, no filesystem writes outside `$TEST_TEMP_DIR`, <1s per test
- **integration/** — multi-module, all external processes mocked at process boundary, <10s per test
- **e2e/** — real external calls, secret-gated, budget-capped

### Gating policy
- Unit + integration must pass on every PR (merge-blocking)
- E2E-smoke (mocked) must pass on every PR (merge-blocking)
- Real e2e runs on every PR when `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` present; on fork PRs runs in a deferred job triggered by `safe-to-test-e2e` maintainer label — no silent skips
- Nightly cron runs the full e2e suite for drift detection

### Budget policy
- Per-test cap: $1.00
- Per-day org cap: $25.00
- Per-week org cap: $100.00
- PRs over cap defer to next available window with a PR comment, not silent skip

### Coverage policy
- Bash coverage via `kcov`; measured per-tier; floor = `measured_baseline - 5%` set on first measurement PR; ratcheted upward
- Empty tier: passes green with a warning annotation (no blocking)

### CI reporting
CI job summary must include: `unit X/Y passed, integration X/Y passed, e2e X/Y passed`

### File structure
- `tests/unit/` — unit tests
- `tests/integration/` — integration tests
- `tests/e2e/` — end-to-end tests
- `scripts/run-tests.sh --tier {unit,integration,e2e,all}` — tier-scoped runner

### Mutation testing
PRs touching any of the 6 critical core files (daemon-state.sh, cost/stage.sh, pipeline-state.sh, pipeline-intelligence.sh dispatch, helpers.sh, ruflo bridge) must update or re-run the relevant mutation doc in `tests/mutation/`.

### Mocked-feature test cleanup
Tests tagged `# tier: integration` during migration must be promoted or demoted within 8 weeks of Phase 5'' landing. Tracked in `tests/integration/MIGRATION-DEBT.md`.

## Consequences
- Parallel CI jobs replace the single sequential for-loop
- Fork PRs get visible label-based workflow instead of silent skip
- Coverage floors prevent regression; empty tiers don't block bootstrapping
- Budget caps prevent runaway spend on real Claude calls
