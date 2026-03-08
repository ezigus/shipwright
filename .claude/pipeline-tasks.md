# Pipeline Tasks — Event collection health check and auto-repair

## Implementation Checklist
- [ ] Task 1: Add `--test-events` flag parsing to sw-doctor.sh (line ~42-50)
- [ ] Task 2: Create `doctor_check_event_collection_health()` function
- [ ] Task 3: Implement directory existence and permission check
- [ ] Task 4: Implement events.jsonl existence and permission check
- [ ] Task 5: Implement disk space check (threshold: 100MB, using df)
- [ ] Task 6: Implement JSON format validation for last 10 entries
- [ ] Task 7: Create `auto_repair_event_logging()` function
- [ ] Task 8: Implement auto-repair: create directory if missing
- [ ] Task 9: Implement auto-repair: create file if missing
- [ ] Task 10: Implement auto-repair: fix permissions on directory/file
- [ ] Task 11: Implement clear error messages for non-repairable issues
- [ ] Task 12: Create `test_event_collection()` function
- [ ] Task 13: Implement test event emission and verification
- [ ] Task 14: Add event polling with retries (up to 5 attempts, 100ms delay)
- [ ] Task 15: Integrate health check call into main doctor flow
- [ ] Task 16: Write comprehensive tests for health check in sw-doctor-test.sh
- [ ] Task 17: Write tests for auto-repair success cases
- [ ] Task 18: Write tests for auto-repair edge cases (permission denied, disk full)
- [ ] Task 19: Write tests for test mode (--test-events flag)
- [ ] Task 20: Verify exit codes work correctly (0=pass, 1=fatal, 2=check failed)

## Context
- Pipeline: standard
- Branch: ci/event-collection-health-check-and-auto-r-73
- Issue: #73
- Generated: 2026-03-08T12:32:00Z
