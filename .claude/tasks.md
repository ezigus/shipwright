# Tasks — bug(memory): failure analyst generates exit code freeform — not grounded against actual captured exit_code

## Status: Complete
Pipeline: autonomous | Branch: fix/bug-memory-failure-analyst-generates-exi-462

## Checklist
- [x] Task 1: Add `_exit_code_to_category()` helper in `sw-memory.sh`
- [x] Task 2: Add optional `exit_code` arg to `memory_capture_failure` and persist in failures.json schema
- [x] Task 3: Add optional `exit_code` arg to `memory_analyze_failure`; prepend ground-truth anchor to prompt
- [x] Task 4: Mechanically set `category` from exit code when in unambiguous set; ignore Claude's category in that case
- [x] Task 5: Add `_sanitize_root_cause()` to scrub hallucinated exit codes / signal names
- [x] Task 6: Filter `past_examples` to entries with matching or zero/missing `exit_code`
- [x] Task 7: Expose `TEST_EXIT_CODE` from `run_test_gate` in `sw-loop.sh` (declared alongside `TEST_PASSED`)
- [x] Task 8: Pass `TEST_EXIT_CODE` into both `memory_capture_failure` and `memory_analyze_failure` call sites in `sw-loop.sh`
- [x] Task 9a: Test — analyzer overrides hallucinated category with ground truth + sanitizes 143/SIGTERM
- [x] Task 9b: Test — capture persists `exit_code` field in failures.json
- [x] Task 9c: Test — back-compat: capture without exit_code defaults to 0
- [x] Task 9d: Test — past-examples filtered by exit_code (mismatched-ec entries excluded from prompt)
- [x] Task 10: `./scripts/sw-memory-test.sh` 28/28, `./scripts/sw-loop-test.sh` 256/256, `./scripts/sw-pipeline-test.sh` 84/84 all pass
- [x] Task 11: Manual smoke confirmed `GROUND TRUTH` block present in prompt with `SW_DEBUG=1`
- [x] Task 12: Bash 3.2 compat — no `declare -A`, `${var,,}`, `${var^^}`, `readarray`; portable `case` for ec→category map
- [x] `memory_analyze_failure` accepts `exit_code` and prepends a ground-truth block to the prompt
- [x] `failures.json` schema includes `exit_code` (additive, back-compat)
- [x] When the harness captures `exit_code=124`, the stored `category` is `timeout` regardless of Claude's output
- [x] When Claude returns `root_cause` containing a contradicting summary exit code or signal name, `root_cause` is sanitized
- [x] Both `sw-loop.sh` call sites pass the captured exit code

## Notes
- Generated from pipeline plan at 2026-05-03T02:26:01Z
- Implementation complete; all acceptance criteria satisfied
