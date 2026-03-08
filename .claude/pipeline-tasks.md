# Pipeline Tasks — Interactive diagnostic mode for failed pipeline troubleshooting

## Implementation Checklist

- [x] Task 1: Create `sw-diagnose.sh` with error collection and classification
- [x] Task 2: Implement confidence-based ranking with bubble sort (Bash 3.2 compat)
- [x] Task 3: Add text report renderer with colored output
- [x] Task 4: Add JSON output mode (`--json` flag)
- [x] Task 5: Integrate memory pattern search
- [x] Task 6: Wire CLI route in `scripts/sw`
- [x] Task 7: Create test suite with 10 test scenarios
- [x] Task 8: Add to npm test suite
- [x] Task 9: Verify all tests pass
- [x] Task 10: Review for edge cases and code quality
- [x] Task 11: Create PR
- [x] `shipwright diagnose` reads latest failed pipeline state
- [x] Analyzes error-summary.json, error-log.jsonl, stage artifacts
- [x] Checks memory patterns for similar past failures
- [x] Outputs ranked list of likely causes with suggested fixes
- [x] Includes relevant log excerpts and file paths for investigation
- [x] Works without active pipeline (reads from artifacts)
- [x] Test coverage with mock failure scenarios (10 tests)
- [ ] All tests pass in CI
- [ ] PR created and reviewed

## Context

- Pipeline: standard
- Branch: feat/interactive-diagnostic-mode-for-failed-p-64
- Issue: #64
- Generated: 2026-03-08T06:32:24Z
