# Pipeline Context Bundle

Generated: 2026-05-22T19:49:18Z
Stage: plan
Goal: Pipeline: resync stage — agent conflict resolution with retry budget and escalation

---



### Common Pitfalls

---

# File Hotspots

From intelligence analysis:

(No file hotspot data in cache)

---

# Recent PR Outcomes

## Merged PRs (last 5)

Pipeline: add resync stage scaffold between audit and pr (basic git me (author: ezigus, +1166−196)
feat(ci): pipeline-smoke gate for machinery PRs (closes #606) (author: ezigus, +183−4)
feat(telemetry): scope manifest events, escalation detection, drift report (author: ezigus, +98−2)
feat(scope-redaction): codify the out-of-scope agent edit invariant at all 6 prompt seams (author: ezigus, +453−7)
security(statusline): port execFileSync hardening from .js into .cjs; delete .js (author: ezigus, +20−11)

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
- **captured_at**: 2026-05-22T19:49:18Z
- **project**: {"type":"node","framework":"","test_runner":"vitest","package_manager":"npm","language":"javascript"}
- **conventions**: {"source_dir":"","test_pattern":"*.test.js","import_style":"commonjs"}


---

# Relevant File Previews

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

## File: AGENTS.md

```
  # Agent Instructions (Codex Self-Contained)
  
  Use centralized standards as source of truth:
  
  - /Users/ericziegler/code/standards/ai-agent-standards/core/core-policy.md
  - /Users/ericziegler/code/standards/ai-agent-standards/adapters/codex-adapter.md
  - /Users/ericziegler/code/standards/ai-agent-standards/repo-overrides/shipwright.md
  - /Users/ericziegler/code/standards/ai-agent-standards/resolution/profile-resolution-matrix.md
  - /Users/ericziegler/code/standards/ai-agent-standards/resolution/shipwright-detection-contract.md
  
  Default profile eligibility for this repo: shipwright.
  Shipwright profile is conditional per detection contract.
  
  Canonical source of truth:
  
  - /Users/ericziegler/code/standards/ai-agent-standards
  
  This file is self-contained for Codex and inlines critical directives.
  Generated source snapshot:
  
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

