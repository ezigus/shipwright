# Pipeline Tasks — Event collection health check and auto-repair

## Implementation Checklist
- [ ] Task 1: Add `--test-events` flag parsing to sw-doctor.sh
- [ ] Task 2: Add `doctor.test_event` to config/event-schema.json
- [ ] Task 3: Implement `doctor_check_events()` function (dir, file, permissions, lock, integrity, recency, size checks with auto-repair)
- [ ] Task 4: Implement `doctor_test_events()` function (synthetic event write/read/cleanup)
- [ ] Task 5: Insert EVENT COLLECTION section into doctor flow (before PLATFORM HEALTH)
- [ ] Task 6: Add exit code logic (exit 1 on failures)
- [ ] Task 7: Add test cases to sw-doctor-test.sh (7 tests covering all check paths)
- [ ] Task 8: Run `npm test` and verify all tests pass
- [ ] `shipwright doctor` output includes "EVENT COLLECTION" section with pass/warn/fail checks
- [ ] Detects: missing events.jsonl, permission errors, malformed entries, stale lock files, no recent events, oversized file
- [ ] Auto-repairs: creates missing `~/.shipwright/` directory, creates missing events.jsonl, fixes world-readable permissions
- [ ] `shipwright doctor --test-events` writes a synthetic event and verifies read-back
- [ ] Synthetic test event is cleaned up after verification
- [ ] Clear error messages with remediation commands for non-repairable issues
- [ ] Exit code is 1 when any check fails, 0 otherwise (for CI/automation)
- [ ] `doctor.test_event` registered in event-schema.json
- [ ] All existing tests continue to pass
- [ ] 7 new test cases pass in sw-doctor-test.sh
- [ ] `npm test` passes clean

## Context
- Pipeline: standard
- Branch: ci/event-collection-health-check-and-auto-r-73
- Issue: #73
- Generated: 2026-03-08T18:16:24Z
