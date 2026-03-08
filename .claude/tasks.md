# Tasks — Fleet operational visibility dashboard

## Status: In Progress
Pipeline: standard | Branch: feat/fleet-operational-visibility-dashboard-77

## Checklist
- [ ] Task 1: Add `fleet_collect_repo_stats()` function — queries events.jsonl/DB for per-repo success rate, avg duration, last run, failure count
- [ ] Task 2: Add `fleet_collect_worker_util()` function — calculates busy/idle/available workers from heartbeats and fleet-config
- [ ] Task 3: Add `fleet_collect_failure_patterns()` function — cross-repo failure pattern detection from events
- [ ] Task 4: Add `fleet_generate_alerts()` function — checks for idle workers with queue, resource hogs, cross-repo failures, stale fleet, budget pressure
- [ ] Task 5: Enhance `fleet_status()` display — integrate all collectors, render ASCII utilization bars, per-repo table with stats, aggregates section, alerts section, cross-repo patterns section
- [ ] Task 6: Add JSON output mode (`--json` flag) — structured JSON output for all fleet status data
- [ ] Task 7: Add `fleet.alert` event type to `config/event-schema.json`
- [ ] Task 8: Add `--period` flag support — bound event queries to N days (default 7)
- [ ] Task 9: Write tests for per-repo stats collection and display
- [ ] Task 10: Write tests for worker utilization display
- [ ] Task 11: Write tests for cross-repo pattern detection
- [ ] Task 12: Write tests for alert generation (idle workers, resource hog, cross-repo failures)
- [ ] Task 13: Write tests for JSON output mode
- [ ] Task 14: Write tests for edge cases (no events, empty fleet, no fleet running)
- [ ] Task 15: Run full test suite and verify no regressions
- [ ] `shipwright fleet status` displays worker pool utilization (busy/idle/available) with ASCII bar
- [ ] `shipwright fleet status` displays per-repo table with: status, active, queued, completed, success rate, avg duration, last run, failure count
- [ ] `shipwright fleet status` displays fleet-wide aggregates: total runs, overall success rate, total cost
- [ ] `shipwright fleet status` displays cross-repo failure patterns (failures in ≥2 repos)
- [ ] `shipwright fleet status` displays alerts for: idle workers with queue, resource hog, cross-repo failures

## Notes
- Generated from pipeline plan at 2026-03-08T12:35:35Z
- Pipeline will update status as tasks complete
