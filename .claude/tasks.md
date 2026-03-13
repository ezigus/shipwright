# Tasks — Build loop iteration checkpoint and crash recovery system

## Status: In Progress
Pipeline: standard | Branch: arch/build-loop-iteration-checkpoint-and-cras-155

## Checklist
- [ ] Task 1: Add `save_iteration_checkpoint()` function to `sw-loop.sh`
- [ ] Task 2: Add `clear_build_checkpoint()` function to `sw-loop.sh`
- [ ] Task 3: Call `save_iteration_checkpoint()` after `write_state` in main loop body
- [ ] Task 4: Call `clear_build_checkpoint()` on successful loop completion
- [ ] Task 5: Refactor `cleanup()` to use `save_iteration_checkpoint()` (DRY)
- [ ] Task 6: Remove duplicated context-save block at end-of-iteration (lines 2240-2248)
- [ ] Task 7: Add `detect_interrupted_loop()` to `scripts/lib/loop-restart.sh`
- [ ] Task 8: Wire auto-detection into `run_single_agent_loop()` startup
- [ ] Task 9: Add iteration checkpoint cycle tests to `sw-checkpoint-test.sh`
- [ ] Task 10: Add cleanup-on-completion tests to `sw-checkpoint-test.sh`
- [ ] Task 11: Add crash detection tests to `sw-checkpoint-test.sh`
- [ ] Task 12: Run `npm test` and verify all tests pass
- [ ] Full checkpoint (JSON + context) saved after every completed build loop iteration
- [ ] Interrupted build loop detected automatically on restart
- [ ] Resume from checkpoint injects previous iteration context correctly (verified by existing `compose_prompt` resume section)
- [ ] `--resume` flag continues to work as before (no regression)
- [ ] Checkpoints cleaned up after successful loop completion
- [ ] Stale checkpoints cleaned up by existing `expire` command (no new work needed)
- [ ] Test coverage for: save/restore cycle, cleanup, crash detection, no false positives
- [ ] `npm test` passes with no regressions

## Notes
- Generated from pipeline plan at 2026-03-13T20:53:19Z
- Pipeline will update status as tasks complete
