# Pipeline Context Bundle

Generated: 2026-05-20T10:55:51Z
Stage: plan
Goal: fix(dod): configurable structural test-pairing for DoD verifier

---



### Common Pitfalls

---

# File Hotspots

From intelligence analysis:

(No file hotspot data in cache)

---

# Recent PR Outcomes

## Merged PRs (last 5)

Upload cost-breakdown.json as GitHub Actions artifact for cross-machin (author: app/github-actions, +1825−191)
fix(ci): reset stale pipeline-state status before snapshot push (author: ezigus, +254−1)
fix(compound-quality): self-clear RETURN trap — prevent _cq_log_file unbound variable crash (#460) (author: ezigus, +87−3)
fix(pipeline): anchor polluted-commit detect + capture build stdout to log (author: ezigus, +150−5)
fix(ci): remove auto-cleanup workflow that destroyed live WIP branches (author: ezigus, +0−49)

---

# Relevant Memory

## Failure Patterns

- **test_failure**: null
- **test_failure**: null
- **test_failure**: null

## Successful Patterns

- **repo**: ezigus/shipwright
- **captured_at**: 2026-05-20T10:55:50Z
- **project**: {"type":"node","framework":"","test_runner":"vitest","package_manager":"npm","language":"javascript"}
- **conventions**: {"source_dir":"","test_pattern":"*.test.js","import_style":"commonjs"}


---

# Relevant File Previews

## File: bug-fix.json

```
  {
    "name": "bug-fix",
    "description": "Bug fix with reproducer, fixer, and verifier agents",
    "keywords": [
      "bug",
      "fix",
      "error",
      "crash",
      "broken",
      "failing",
      "regression"
    ],
    "agents": [
      {
        "name": "reproducer",
        "role": "Write a failing test that reproduces the bug, trace root cause",
        "focus": "*.test.ts, __tests__/, *.spec.ts"
      },
      {
        "name": "fixer",
```

## File: hotfix.json

```
  {
    "name": "hotfix",
    "description": "Urgent production fixes: intake → build → test → PR (all auto, minimal iteration)",
    "defaults": {
      "model": "opus",
      "agents": 1
    },
    "intelligence": {
      "adversarial_enabled": true,
      "architecture_enabled": true,
      "simulation_enabled": true
    },
    "stages": [
      {
        "id": "intake",
        "enabled": true,
        "gate": "auto",
        "config": {}
      },
      {
```

## File: PLATFORM-TODO-TRIAGE.md

```
  # Platform TODO/FIXME/HACK Triage (Phase 4)
  
  **Date:** 2026-02-16  
  **Source:** `rg -n "TODO|FIXME|HACK" scripts/ docs/ config/ .github/ .claude/` (comment-style markers only)
  
  This document categorizes all TODO/FIXME/HACK comment markers found in the codebase. Only actual technical-debt comment markers are included (not variable names like `STATUS_TODO`, grep patterns, or documentation references).
  
  ## Summary by Category
  
  | Category      | Count |
  | ------------- | ----- |
  | fix-now       | 0     |
  | github-issue  | 4     |
  | accepted-debt | 3     |
  | stale         | 0     |
  | **Total**     | **7** |
  
  ## Full Triage Table
  
  | File                          | Line | Marker | Text                                                                | Category      |
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

