# Tasks — bug: pipeline-tasks.md not cleared on resume — stale tasks injected into build loop

## Status: In Progress
Pipeline: autonomous | Branch: fix/bug-pipeline-tasks-md-not-cleared-on-res-232

## Checklist
- [ ] 1.1 Verify TASKS_FILE initialization across all entry points
- [ ] 1.2 Test extract_issue_from_tasks_file() with 5+ metadata formats
- [ ] 1.3 Trace issue number normalization (initialize → resume → build)
- [ ] 1.4 Check for concurrent pipeline race conditions
- [ ] 2.1 Unit test: extract_issue_from_tasks_file() edge cases
- [ ] 2.2 Integration test: stale tasks from issue #X don't inject into #Y
- [ ] 2.3 Regression test: exact scenario from #207 (issue #154→#232)
- [ ] 2.4 Edge case: resume after partial file deletion
- [ ] 2.5 Edge case: file exists but TASKS_FILE variable unset
- [ ] 3.1 Verify all three deletion paths in production code
- [ ] 3.2 Verify extract_issue_from_tasks_file() is sourced
- [ ] 3.3 Check no remnants of old "warn + continue" paths
- [ ] 4.1 Document task file metadata format requirements
- [ ] 4.2 Add ADR explaining three-layer validation
- [ ] 4.3 Verify warnings logged with debugging context

## Notes
- Generated from pipeline plan at 2026-03-30T00:39:30Z
- Pipeline will update status as tasks complete
