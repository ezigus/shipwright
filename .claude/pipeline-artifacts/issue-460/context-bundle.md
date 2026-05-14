# Pipeline Context Bundle

Generated: 2026-05-13T23:06:22Z
Stage: plan
Goal: Upload cost-breakdown.json as GitHub Actions artifact for cross-machine optimization

---



### Common Pitfalls

---

# File Hotspots

From intelligence analysis:

(No file hotspot data in cache)

---

# Recent PR Outcomes

## Merged PRs (last 5)

revert: restore actions/download-artifact@v4 (accept known arbitrary file write vulnerability) (author: app/copilot-swe-agent, +0−0)
fix: WIP code-push step + snapshot diagnostics + git_auto_commit improvements (#460) (author: ezigus, +166−11936)
fix(loop): holistic gate-findings funnel — surface all gate results per iteration (author: ezigus, +12536−78)
fix(build-prompt): surface gate failures, clean rules, strip DoD checkboxes (author: ezigus, +66−14)
fix(snapshot): always push local commits to WIP branch (#460) (author: ezigus, +31−6)

---

# Relevant Memory

## Successful Patterns

- **repo**: ezigus/shipwright
- **captured_at**: 2026-05-13T23:06:21Z
- **project**: {"type":"node","framework":"","test_runner":"vitest","package_manager":"npm","language":"javascript"}
- **conventions**: {"source_dir":"","test_pattern":"*.test.js","import_style":"commonjs"}


---

# Relevant File Previews

## File: interactions.ts

```
  // Hit testing, hover, click, zoom handlers for canvas
  
  import type { LayoutNode, StageColumn } from "./layout";
  
  export interface HoverState {
    node: LayoutNode | null;
    column: StageColumn | null;
  }
  
  export function hitTestNode(
    nodes: LayoutNode[],
    x: number,
    y: number,
  ): LayoutNode | null {
    for (const node of nodes) {
      const dx = x - node.x;
      const dy = y - node.y;
      if (dx * dx + dy * dy <= node.radius * node.radius) {
        return node;
      }
```

## File: sw-pipeline-artifact-push-test.sh

```
  #!/usr/bin/env bash
  # ╔═══════════════════════════════════════════════════════════════════════════╗
  # ║  sw-pipeline artifact push test — PAT push (loop + final artifact save)  ║
  # ╚═══════════════════════════════════════════════════════════════════════════╝
  set -euo pipefail
  trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR
  
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REAL_LOOP_SCRIPT="$SCRIPT_DIR/sw-loop.sh"
  REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/sw-pipeline.sh"
  
  # Normalize TMPDIR: macOS sets TMPDIR with a trailing slash; Linux may leave it unset.
  # Provide a /tmp default first (safe under set -u), then strip any trailing slash.
  _SW_TMPBASE="${TMPDIR:-/tmp}"
  _SW_TMPBASE="${_SW_TMPBASE%/}"
  
  # ─── Colors ───────────────────────────────────────────────────────────────────
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
```

## File: agent-task.md

```
  ---
  name: Agent Task
  about: Structured task for autonomous agent execution
  labels: ready-to-build
  ---
  
  ## Goal
  <!-- One clear sentence describing what needs to happen -->
  
  ## Context
  <!-- Background information, related issues, user requirements -->
  
  ## Acceptance Criteria
  - [ ] Criterion 1
  - [ ] Criterion 2
  
  ## Technical Notes
  <!-- Implementation hints, files to modify, constraints -->
  
  ## Definition of Done
```


---

# Architecture Decision Records

<!-- sw:auto-start -->
# Architecture

## Overview
**shipwright** is a typescript project with 72 source files and ~26527 lines of code.

## Entry Points
- No standard entry points detected

## Module Map
- `src/` — 1 files





## Infrastructure
- Docker: Dockerfile present
- Docker Compose: multi-service setup
- CI/CD: GitHub Actions workflows
<!-- sw:auto-end -->


---


# Plan Stage Guidance

## Focus Areas
- Break down goal into measurable milestones
- Identify dependencies and blockers
- Estimate scope and complexity
- Consider edge cases and error paths

## Key Questions
- What are the success criteria?
- What are the known constraints?
- What existing patterns apply here?
- Are there similar completed features to reference?

## Anti-patterns to Avoid
- Over-scoping the initial plan
- Missing edge cases in requirement analysis
- Ignoring technical debt in design phase

