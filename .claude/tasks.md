# Tasks — feat(ruflo): [01.3] queen collapse for ruflo_execute_review — dedup and rank hive findings

## Status: In Progress
Pipeline: autonomous | Branch: feat/feat-ruflo-01-3-queen-collapse-for-ruflo-415

## Checklist
- [ ] Task 1: Read `scripts/lib/ruflo-adapter.sh:957–986` carefully to confirm insertion point and surrounding bash quoting/style conventions.
- [ ] Task 2: Add `_synth_ns` variable declaration after artifact write.
- [ ] Task 3: Add `ruflo_store "review-union-findings"` seed call with 6000-byte cap.
- [ ] Task 4: Add NPX-branched `ruflo coordination orchestrate` synthesis call with `_synth_exit` capture.
- [ ] Task 5: Add NPX-branched `ruflo hive-mind memory --action list` read of synth namespace, gated on `_synth_exit -eq 0`.
- [ ] Task 6: Add conditional artifact_file overwrite with non-empty guard and `|| true` fail-open.
- [ ] Task 7: Add `emit_event "ruflo.review_synth_complete"` line.
- [ ] Task 8: Confirm bash 3.2 compatibility (no `declare -A`, no `${var,,}`).
- [ ] Task 9: Run `./scripts/sw-ruflo-adapter-test.sh` and verify all existing review tests still pass.
- [ ] Task 10: Run `npm test` and verify full suite.
- [ ] Task 11: Manually trace `RUFLO_HIVE_AVAILABLE=false` early-return path remains untouched (gate at line 901–904 unchanged).
- [ ] Task 12: Verify circuit-breaker timeout values are reasonable (120s for orchestrate, 10s for memory list — matches existing call patterns).
- [ ] A finding reported by 3 specialists appears once (deduplicated) — verified by reading the synthesis prompt's dedup instruction
- [ ] Findings are severity-ranked (Critical/Bug/Security/Warning/Suggestion) in the artifact when synthesis succeeds
- [ ] If synthesis orchestration fails (`_synth_exit != 0`), the union artifact is preserved unchanged (fail-open)
- [ ] `RUFLO_HIVE_AVAILABLE=false` path returns 1 before any synthesis logic executes
- [ ] `./scripts/sw-ruflo-adapter-test.sh` passes (all sections including section C gate checks)
- [ ] `npm test` passes
- [ ] Bash 3.2 compatibility maintained (no associative arrays, no `${var,,}`, no `readarray`)
- [ ] No new dependencies added

## Notes
- Generated from pipeline plan at 2026-04-25T14:45:47Z
- Pipeline will update status as tasks complete
