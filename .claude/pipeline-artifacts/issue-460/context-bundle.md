# Pipeline Context Bundle

Generated: 2026-05-19T00:21:09Z
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

fix(compound-quality): correct root causes for no-op LOOP:PASS and silent cycles (#460) (author: ezigus, +347−59)
revert(compound-quality): remove targeted-file list and iteration cap (T2.1) (author: ezigus, +4−96)
fix(pipeline): postmortem-460 hardening — scope guardrail, sidecar config, DoD validator (author: ezigus, +1683−112)
fix(pipeline): remediate #460 postmortem (F1-F15) + two audit passes (author: ezigus, +1203−60)
fix(pipeline): stop spurious cross-issue force-pushes + reliable WIP save on hard timeout (author: ezigus, +1041−62)

---

# Relevant Memory

## Failure Patterns

- **test_failure**: null
- **test_failure**: null

## Successful Patterns

- **repo**: ezigus/shipwright
- **captured_at**: 2026-05-19T00:21:08Z
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

## File: 2026-03-01-compound-audit-cascade-plan.md

```
  # Compound Audit Cascade — Implementation Plan
  
  > **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
  
  **Goal:** Replace the one-shot compound_quality stage with an adaptive multi-agent cascade that iteratively probes for bugs until confidence is high.
  
  **Architecture:** New library `compound-audit.sh` with four functions (run_cycle, dedup, escalate, converged). Integrates into existing `stage_compound_quality()` in `pipeline-intelligence.sh`. Agents run as parallel `claude -p --model haiku` calls. Dedup uses structural matching + haiku LLM judge. Convergence stops on no new critical/high OR >98% dup rate OR max_cycles.
  
  **Tech Stack:** Bash 3.2, `claude -p`, `jq`, audit-trail.sh JSONL events
  
  ---
  
  ### Task 1: Compound Audit Library — Core Scaffolding + Tests
  
  **Files:**
  - Create: `scripts/lib/compound-audit.sh`
  - Create: `scripts/sw-lib-compound-audit-test.sh`
  
  **Step 1: Write the test file scaffold**
  
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

