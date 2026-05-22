# Pipeline Context Bundle

Generated: 2026-05-21T10:25:01Z
Stage: plan
Goal: Reduce build-loop iteration ceiling — current 45/cycle × 3 cycles = 135 invocations is excessive

---



### Common Pitfalls

---

# File Hotspots

From intelligence analysis:

(No file hotspot data in cache)

---

# Recent PR Outcomes

## Merged PRs (last 5)

fix(pipeline): F1-F4 reliability — session limits fatal, YAML-only reconciler, scoped findings, legible output (author: ezigus, +212−76)
fix(ci): PAT token plumbing, configurable CI wait, and auto-close (author: ezigus, +248−69)
fix(dod): configurable structural test-pairing for DoD verifier (author: app/github-actions, +1332−245)
fix(scope-label): use ITERATION counter; suppress absent outer stage label (author: ezigus, +12−8)
fix(ci): stop force-adding root pipeline-state files to WIP branches (author: ezigus, +34−8)

---

# Relevant Memory

## Failure Patterns

- **test_failure**: null
- **test_failure**: null
- **test_failure**: null
- **test_failure**: null

## Successful Patterns

- **repo**: ezigus/shipwright
- **captured_at**: 2026-05-21T10:25:01Z
- **project**: {"type":"node","framework":"","test_runner":"vitest","package_manager":"npm","language":"javascript"}
- **conventions**: {"source_dir":"","test_pattern":"*.test.js","import_style":"commonjs"}


---

# Relevant File Previews

## File: build-release.sh

```
  #!/usr/bin/env bash
  # ╔═══════════════════════════════════════════════════════════════════════════╗
  # ║  Shipwright — Build Release Artifacts                                   ║
  # ║  Creates platform tarballs and checksums for GitHub Releases            ║
  # ╚═══════════════════════════════════════════════════════════════════════════╝
  set -euo pipefail
  
  VERSION="3.6.1"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  DIST_DIR="$REPO_ROOT/dist"
  
  # ─── Cross-platform compatibility ──────────────────────────────────────────
  # shellcheck source=lib/compat.sh
  [[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
  
  # Canonical helpers (colors, output, events)
  # shellcheck source=lib/helpers.sh
  [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
  # Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
```

## File: pipeline-stages-build.sh

```
  # pipeline-stages-build.sh — test_first, build, test stages
  # Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
  [[ -n "${_PIPELINE_STAGES_BUILD_LOADED:-}" ]] && return 0
  _PIPELINE_STAGES_BUILD_LOADED=1
  
  stage_test_first() {
      CURRENT_STAGE_ID="test_first"
      info "Generating tests from requirements (TDD mode)"
  
      local plan_file="${ARTIFACTS_DIR}/plan.md"
      local goal_file="${PROJECT_ROOT}/.claude/goal.md"
      local requirements=""
      if [[ -f "$plan_file" ]]; then
          requirements=$(cat "$plan_file" 2>/dev/null || true)
      elif [[ -f "$goal_file" ]]; then
          requirements=$(cat "$goal_file" 2>/dev/null || true)
      else
          requirements="${GOAL:-}: ${ISSUE_BODY:-}"
      fi
  
```

## File: sw-pr-lifecycle.sh

```
  #!/usr/bin/env bash
  # ╔═══════════════════════════════════════════════════════════════════════════╗
  # ║  shipwright pr-lifecycle — Autonomous PR Management                       ║
  # ║  Auto-review · Auto-merge · Stale cleanup · Issue feedback                ║
  # ╚═══════════════════════════════════════════════════════════════════════════╝
  set -euo pipefail
  trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR
  
  # shellcheck disable=SC2034
  VERSION="3.6.1"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  
  # Derive PROJECT_ROOT: the user's git repo (distinct from shipwright install root)
  PROJECT_ROOT="${PROJECT_ROOT:-}"
  if [[ -z "$PROJECT_ROOT" ]]; then
      if [[ -d "${REPO_DIR}/.claude" ]]; then
          PROJECT_ROOT="$REPO_DIR"
      else
          PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$REPO_DIR")"
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

