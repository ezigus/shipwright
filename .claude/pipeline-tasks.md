# Pipeline Tasks — Interactive diagnostic mode for failed pipeline troubleshooting

## Implementation Checklist
- [ ] Task 1: Fix `collect_errors()` to support both error-summary.json formats
- [ ] Task 2: Fix `search_memory()` subshell bug
- [ ] Task 3: Add `analyze_stage_artifacts()` function
- [ ] Task 4: Add log excerpt display in verbose mode
- [ ] Task 5: Add `--stage <name>` flag for stage-specific filtering
- [ ] Task 6: Update `render_json()` to include memory matches and stage artifacts
- [ ] Task 7: Update `render_report()` to show stage artifact summary
- [ ] Task 8: Add test for real error-summary.json format (`.error_lines[]`)
- [ ] Task 9: Add test for stage artifact analysis
- [ ] Task 10: Add test for memory search (mock `memory_ranked_search`)
- [ ] Task 11: Add test for `--stage` flag
- [ ] Task 12: Add test for JSON output with all new fields
- [ ] Task 13: Run full test suite and verify all tests pass
- [ ] `shipwright diagnose` correctly parses real `error-summary.json` format from `write_error_summary()`
- [ ] Memory search results are displayed (subshell bug fixed)
- [ ] Stage artifacts (checkpoints, stuckness) are analyzed and shown
- [ ] `--verbose` includes log excerpts
- [ ] `--json` output includes memory matches, stage artifacts
- [ ] `--stage <name>` filters to specific stage
- [ ] Works with no pipeline state (clean message)

## Context
- Pipeline: standard
- Branch: feat/interactive-diagnostic-mode-for-failed-p-64
- Issue: #64
- Generated: 2026-03-08T12:19:01Z
