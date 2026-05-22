# Pipeline Context Bundle

Generated: 2026-05-22T16:32:02Z
Stage: plan
Goal: Pipeline: add resync stage scaffold between audit and pr (basic git merge, no conflict handling)

---



### Common Pitfalls

---

# File Hotspots

From intelligence analysis:

(No file hotspot data in cache)

---

# Recent PR Outcomes

## Merged PRs (last 5)

feat(ci): pipeline-smoke gate for machinery PRs (closes #606) (author: ezigus, +183−4)
feat(telemetry): scope manifest events, escalation detection, drift report (author: ezigus, +98−2)
feat(scope-redaction): codify the out-of-scope agent edit invariant at all 6 prompt seams (author: ezigus, +453−7)
security(statusline): port execFileSync hardening from .js into .cjs; delete .js (author: ezigus, +20−11)
Reduce build-loop iteration ceiling — current 45/cycle × 3 cycles = (author: ezigus, +1126−193)

---

# Relevant Memory

## Failure Patterns

- **test_failure**: null
- **test_failure**: null
- **test_failure**: null
- **test_failure**: null
- **test_failure**: null

## Successful Patterns

- **repo**: ezigus/shipwright
- **captured_at**: 2026-05-22T16:32:01Z
- **project**: {"type":"node","framework":"","test_runner":"vitest","package_manager":"npm","language":"javascript"}
- **conventions**: {"source_dir":"","test_pattern":"*.test.js","import_style":"commonjs"}


---

# Relevant File Previews

## File: codex-additions.md

```
  # Repo-Specific Codex Additions
  
  Add repo-local instructions here. This file is preserved across installs.
```

## File: copilot-additions.md

```
  # Repo-Specific Copilot Additions
  
  Add repo-local Copilot notes here. This file is preserved across installs.
```

## File: 2026-02-28-compound-audit-and-shipyard-design.md

```
  # Compound Audit Architecture & Shipyard Simulation Design
  
  **Date**: 2026-02-28
  **Status**: Approved
  **Scope**: Three parallel workstreams
  
  ## 1. Compound Negative-Critical Audit Architecture
  
  ### Philosophy
  
  Every audit asks "What did we get wrong?" The questions:
  
  - What did we miss?
  - What did we not think through or consider?
  - What did we fail to test, audit, research, validate, or prove works E2E?
  - Where are we lying to ourselves about capability?
  
  ### 6 Audit Dimensions
  
  Evaluated against background-agents.com gold standard:
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

