# Tasks — Interactive diagnostic mode for failed pipeline troubleshooting

## Status: In Progress
Pipeline: standard | Branch: feat/interactive-diagnostic-mode-for-failed-p-64

## Checklist
- [ ] Task 1: Create `scripts/sw-diagnose.sh` with header, argument parsing, and help text
- [ ] Task 2: Implement `load_pipeline_state()` to parse pipeline-state.md YAML frontmatter
- [ ] Task 3: Implement `collect_errors()` to read error-summary.json and error-log.jsonl
- [ ] Task 4: Implement `collect_events()` to extract failure events from events.jsonl
- [ ] Task 5: Implement `classify_errors()` with the error classification map
- [ ] Task 6: Implement `search_memory()` using memory_ranked_search
- [ ] Task 7: Implement `rank_diagnoses()` to score and sort findings
- [ ] Task 8: Implement `render_report()` for formatted text output
- [ ] Task 9: Implement `render_json()` for `--json` output mode
- [ ] Task 10: Add `diagnose` command to CLI router in `scripts/sw`
- [ ] Task 11: Create `scripts/sw-diagnose-test.sh` with mock failure scenarios
- [ ] Task 12: Add test to `package.json` scripts
- [ ] Task 13: Run tests and verify all pass
- [ ] `shipwright diagnose` reads latest failed pipeline state from artifacts
- [ ] Analyzes error-summary.json, error-log.jsonl, and stage artifacts
- [ ] Checks memory patterns for similar past failures via memory_ranked_search
- [ ] Outputs ranked list of likely causes with suggested fixes
- [ ] Includes relevant log excerpts and file paths for investigation
- [ ] Works without active pipeline (reads from artifacts on disk)
- [ ] `--json` flag produces valid, parseable JSON output

## Notes
- Generated from pipeline plan at 2026-03-08T05:07:19Z
- Pipeline will update status as tasks complete
