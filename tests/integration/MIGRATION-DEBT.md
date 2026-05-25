# Integration Test Migration Debt

Tests tagged `# tier: integration` during ADR-208 migration must be promoted to `unit`
or `e2e` within 8 weeks of Phase 5'' landing (deadline: 2026-07-20).

## Pending Migration

| Test File | Current Tier | Target Tier | Owner | Notes |
|-----------|-------------|-------------|-------|-------|
| scripts/sw-e2e-smoke-test.sh | integration | unit | TBD | Mocked, no external calls |
| scripts/sw-e2e-integration-test.sh | integration | e2e | TBD | Needs secret gating |
| scripts/sw-e2e-orchestrator-test.sh | integration | e2e | TBD | Needs secret gating |
| scripts/sw-e2e-system-test.sh | integration | e2e | TBD | Needs secret gating |
| scripts/sw-ruflo-benchmark-test.sh | integration | unit | TBD | Benchmark, no external calls |
| scripts/sw-ruflo-timeout-test.sh | integration | unit | TBD | Timeout simulation |
| scripts/sw-budget-chaos-test.sh | integration | unit | TBD | Mocked budget |
| scripts/sw-chaos-test.sh | integration | unit | TBD | Mocked chaos |
| scripts/sw-cross-repo-isolation-test.sh | integration | unit | TBD | Filesystem only |
| scripts/sw-postmortem-460-test.sh | integration | unit | TBD | Regression test |
| scripts/sw-review-rerun-test.sh | integration | unit | TBD | Mocked review |
| scripts/sw-tracker-providers-test.sh | integration | unit | TBD | Mocked providers |
| scripts/sw-evidence-test.sh | integration | unit | TBD | Mocked evidence |
| scripts/sw-adapters-test.sh | integration | unit | TBD | Mocked adapters |
| scripts/sw-server-api-test.sh | integration | e2e | TBD | Needs real API |
| scripts/sw-integration-claude-test.sh | integration | e2e | TBD | Needs Claude API |

## Migration Checklist

For each test being promoted:
- [ ] Confirm no external processes or network calls
- [ ] Confirm filesystem writes only to `$TEST_TEMP_DIR`
- [ ] Confirm test completes in <1s (unit) or <10s (integration)
- [ ] Update `# tier:` header
- [ ] Create symlink in `tests/<target-tier>/`
- [ ] Remove from this debt list
