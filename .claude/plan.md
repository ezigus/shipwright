# Design: Add --json output flag to shipwright status command

## Context

The `shipwright status` command (`scripts/sw-status.sh`) provides a human-readable dashboard showing tmux windows, team configs, task lists, daemon state, heartbeats, remote machines, connected developers, and database health. Issue #4 requests a `--json` flag that emits the same data as machine-readable JSON so other tools (CI scripts, dashboards, fleet orchestrators, monitoring) can consume it programmatically.

Constraints:

- Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- `set -euo pipefail` required
- `jq` is a project prerequisite (used broadly across Shipwright)
- JSON assembly must avoid string interpolation for values (use `jq --arg`/`--argjson`)
- The human-readable path must remain unchanged when `--json` is not passed

## Decision

Implement `--json` as an early-exit code path in `scripts/sw-status.sh`. When the flag is set:

1. **Argument parsing** (lines 57-71): A `JSON_OUTPUT` flag is set by `--json`. Unknown flags error with exit 1. `--help` documents the new flag.

2. **Guard clause** (lines 74-78): If `jq` is not installed, emit a clear error to stderr and exit 1 — the human-readable path does not require `jq`, so this is JSON-specific.

3. **Data collection** (lines 80-238): Each of the 11 data sections is collected independently into shell variables (`WINDOWS_JSON`, `TEAMS_JSON`, `TASKS_JSON`, `DAEMON_JSON`, `TRACKER_JSON`, `HEARTBEATS_JSON`, `MACHINES_JSON`, `DEVELOPERS_JSON`, `DATABASE_JSON`). Each section:
   - Defaults to a safe empty value (`[]` for arrays, `null` for optional objects)
   - Falls back to the default on any `jq` or I/O error (`|| SECTION_JSON="[]"`)
   - Uses `jq -n --arg`/`--argjson` for safe JSON construction — never raw string interpolation for values

4. **Assembly** (lines 240-265): A single `jq -n` call assembles all sections into the final JSON envelope with keys: `version`, `timestamp`, `tmux_windows`, `teams`, `task_lists`, `daemon`, `issue_tracker`, `heartbeats`, `remote_machines`, `connected_developers`, `database`.

5. **Early exit** (line 266): `exit 0` prevents any human-readable output from being emitted.

**Key design properties:**

- **No shared code path with human-readable output.** The JSON branch collects data independently, so changes to the human-readable formatting cannot break JSON output and vice versa.
- **Graceful degradation per section.** If any single data source (heartbeat dir, daemon state file, sqlite DB) is missing or corrupted, that section defaults to `[]` or `null` — the envelope is always valid JSON.
- **No new dependencies.** `jq` is already required by the project.
- **Schema:** Top-level keys are stable. `version` (string, semver), `timestamp` (string, ISO-8601 UTC), `tmux_windows` (array), `teams` (array), `task_lists` (array), `daemon` (object|null), `issue_tracker` (object|null), `heartbeats` (array), `remote_machines` (array), `connected_developers` (object|null), `database` (object|null).

## Alternatives Considered

1. **Shared data collection with format switch at output time** — Pros: eliminates ~190 lines of duplication between JSON and human-readable paths / Cons: couples the two paths tightly; changes to human-readable formatting could break JSON assembly; harder to reason about error handling when one path needs `jq` and the other doesn't; the human-readable path uses shell variables and printf, not structured data. Rejected in favor of independent paths for robustness.

2. **Output as line-delimited JSON (JSONL) per section** — Pros: streamable, each section independently parseable / Cons: not a single queryable document (can't do `jq '.daemon.active_jobs'` in one pass); breaks user expectation of `--json` producing a JSON object; no ecosystem precedent in Shipwright. Rejected.

3. **Python/Node helper for JSON assembly** — Pros: richer JSON manipulation, eliminates `jq` dependency in the critical path / Cons: adds a runtime dependency; all other Shipwright scripts are pure bash + `jq`; inconsistent with project architecture. Rejected.

## Implementation Plan

- Files to create: none (all files already exist)
- Files to modify: `scripts/sw-status.sh` (lines 57-267 — already modified), `scripts/sw-status-test.sh` (30 tests — already written)
- Dependencies: none new (`jq` already required)
- Risk areas:
  - **`cmd | while read` subshell variable loss** (lines 83-91, 184-192): The tmux windows and heartbeats sections pipe into `while read` loops. Variables set inside the loop are lost, but this is handled correctly — JSON fragments are emitted via `printf` to stdout and collected by `jq -s '.'`.
  - **Dashboard curl timeout** (line 208): The connected developers section calls `curl --max-time 3` to the dashboard API. If the dashboard is slow, the 3-second timeout prevents the JSON output from hanging, but adds up to 3s of latency. Acceptable for a status command that a user invokes interactively or a monitor polls infrequently.
  - **Large daemon state** (line 154): `recent_completions` is capped at 20 entries via `jq` slice (`reverse | .[:20]`), preventing unbounded output growth.
  - **Task list `find` in subshell** (lines 116-132): Task counting uses `while read` from a process substitution (`< <(find ...)`), which correctly preserves variable state in the parent shell. This is the right pattern per project conventions.

## Validation Criteria

- [x] `shipwright status --json` produces valid JSON (`jq empty` succeeds)
- [x] All 11 top-level keys are present in output
- [x] `version` field matches semver pattern `X.Y.Z`
- [x] `timestamp` is ISO-8601 UTC format
- [x] No ANSI escape codes appear in JSON output
- [x] Empty state (no daemon, no teams, no heartbeats) produces valid JSON with safe defaults (`[]`, `null`)
- [x] Human-readable output (`shipwright status` without `--json`) is unaffected
- [x] `--help` documents the `--json` flag
- [x] Unknown flags produce error and exit 1
- [x] Missing `jq` produces clear error to stderr and exit 1
- [x] Subsections are independently queryable (e.g., `jq '.daemon.active_jobs[].issue'`)
- [x] All 30 tests in `scripts/sw-status-test.sh` pass
