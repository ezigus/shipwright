# Tasks — Fleet-wide pattern sharing for cross-repository learning

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-80

## Checklist
- [ ] Task 1: Add `fleet_patterns_record_reuse` function to `sw-fleet-patterns.sh`
- [ ] Task 2: Wire `fleet_patterns_capture` call into `sw-pipeline.sh` pipeline completion
- [ ] Task 3: Track injected fleet pattern IDs in `sw-memory.sh` `memory_ranked_search`
- [ ] Task 4: Add reuse outcome recording at pipeline completion in `sw-pipeline.sh`
- [ ] Task 5: Add pattern promotion logic to `_memory_aggregate_global` in `sw-memory.sh`
- [ ] Task 6: Add `test_record_reuse_success` test
- [ ] Task 7: Add `test_record_reuse_failure` test
- [ ] Task 8: Add `test_record_reuse_missing_pattern` test
- [ ] Task 9: Add `test_pipeline_integration_capture` test
- [ ] Task 10: Run existing test suites to verify no regressions
- [ ] `fleet_patterns_capture` is called automatically at pipeline completion when `pattern_share_enabled=true`
- [ ] `fleet_patterns_record_reuse` correctly updates `success_count`, `failure_count`, and `effectiveness_rate`
- [ ] Fleet pattern IDs used during build are tracked in `fleet-patterns-used.json`
- [ ] Reuse outcomes are recorded at pipeline completion
- [ ] High-frequency repo patterns are promoted to fleet-wide patterns
- [ ] All new functions have corresponding tests
- [ ] Existing test suites pass without regression
- [ ] All changes are Bash 3.2 compatible (no associative arrays, readarray, etc.)
- [ ] All file writes use atomic tmp+mv pattern under flock

## Notes
- Generated from pipeline plan at 2026-03-08T17:46:52Z
- Pipeline will update status as tasks complete
