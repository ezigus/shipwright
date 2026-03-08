# Pipeline Tasks — Fleet operational visibility dashboard

## Implementation Checklist
- [ ] Task 1: Create `lib/fleet-stats.sh` with `fleet_collect_repo_stats()` for per-repo event aggregation
- [ ] Task 2: Add `fleet_collect_worker_util()` for worker busy/idle/available calculation
- [ ] Task 3: Add `fleet_collect_aggregates()` for fleet-wide totals and cost rollup
- [ ] Task 4: Add `fleet_detect_cross_patterns()` for cross-repo failure pattern matching
- [ ] Task 5: Add `fleet_check_alerts()` for resource imbalance and pattern alerting
- [ ] Task 6: Enhance `fleet_status()` in `sw-fleet.sh` with new dashboard sections
- [ ] Task 7: Add `--json` output mode for enhanced fleet status
- [ ] Task 8: Register `fleet.status` and `fleet.alert` event types in `event-schema.json`
- [ ] Task 9: Write comprehensive shell tests in `sw-fleet-status-test.sh`
- [ ] Task 10: Run full test suite (`npm test`) and fix any regressions
- [ ] `shipwright fleet status` displays: active repos, worker pool utilization (progress bar), queue depth per repo
- [ ] Per-repo stats table shows: success rate, avg duration, last run timestamp, failure count
- [ ] Cross-repo pattern detection identifies failures appearing in ≥2 repos with same error_class
- [ ] Worker utilization shows: busy/idle/available workers with visual progress bar
- [ ] Fleet-wide aggregates show: total runs, overall success rate, total cost
- [ ] Alerts fire for: idle workers with queued work, single repo dominating resources (>60%), cross-repo failure patterns
- [ ] `shipwright fleet status --json` outputs valid JSON with all fields
- [ ] All new shell tests pass
- [ ] `npm test` passes with no regressions
- [ ] Bash 3.2 compatible (no associative arrays)

## Context
- Pipeline: standard
- Branch: feat/fleet-operational-visibility-dashboard-77
- Issue: #77
- Generated: 2026-03-08T18:16:46Z
