---
goal: "Add --json output flag to shipwright status command

## Plan Summary
The `--json` flag for `shipwright status` is **already fully implemented**. Here's the summary:

**Implementation** (`scripts/sw-status.sh:57-267`):
- `--json` flag parsing with `--help` documentation
- Collects all 11 data sections: `version`, `timestamp`, `tmux_windows`, `teams`, `task_lists`, `daemon`, `issue_tracker`, `heartbeats`, `remote_machines`, `connected_developers`, `database`
- Uses `jq` for safe JSON construction throughout
- Human-readable output is completely bypassed when `--json` is set (`exit 0` on line 266)

**Tests** (`scripts/sw-status-test.sh`): **All 30 tests pass**, covering:
- Valid JSON output
- All top-level keys present
- Fixture data correctness for every section
- No ANSI escape codes in JSON
- Empty state produces valid JSON
- Human-readable output still works without `--json`
- Subsection queries work (e.g., `jq '.daemon.active_jobs[].issue'`)

**All acceptance criteria from issue #4 are met.** No code changes are needed — the pipeline can proceed directly to PR.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{"error":"memory_search_failed","results":[]}

Discoveries from other pipelines:
[38;2;74;222;128m[1m✓[0m Injected 1 new discoveries
[design] Design completed for Add --json output flag to shipwright status command — Resolution: "
iteration: 0
max_iterations: 20
status: running
test_cmd: "(cd -- demo && npm test)"
test_cmd_auto: true
model: sonnet
agents: 1
loop_start_commit: 3bf2139f24f986ac18e79ac9dd79cf2102ef726b
started_at: 2026-02-25T20:19:39Z
last_iteration_at: 2026-02-25T20:19:39Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

