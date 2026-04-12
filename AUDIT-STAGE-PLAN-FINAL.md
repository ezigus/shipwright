# Audit Stage Hive-Mind Integration: Final Plan

**Issue**: feat(ruflo): integrate audit stage with ruflo hive-mind specialist security agents  
**Status**: ✅ Implementation Complete | 📋 Validation Phase (8 Tasks)  
**Documents**: 
- `docs/AUDIT-STAGE-IMPLEMENTATION-SUMMARY.md` — What's implemented (file paths, signatures, architecture)
- `docs/AUDIT-STAGE-VALIDATION-PLAN.md` — What needs validation (8 executable tasks)

---

## Executive Summary

The audit stage feature is **functionally complete** across 4 commits (29d4ac94–2362a95e). All code is merged, unit tests pass (96/96), and the pipeline integration is working. This plan outlines the 8 concrete validation tasks required before moving to production.

### What's Done ✅
- `ruflo_execute_audit()` function (scripts/lib/ruflo-adapter.sh:1035–1182)
- Pipeline integration in `stage_audit()` (scripts/lib/pipeline-stages-review.sh:680–698)
- Event schema (config/event-schema.json)
- 96 unit tests passing

### What's Pending ⏳
- 8 validation tasks across 3 phases (35–50 hours)
- End-to-end pipeline integration testing
- Performance benchmarking
- Security validation
- Edge case hardening
- Final documentation & ADR

---

## Alternatives Considered

### 1. Skip Validation, Merge Immediately ❌
- **Pros**: Faster delivery (save 35–50 hours)
- **Cons**: Unvalidated production code; untested edge cases; silent failure risks
- **Verdict**: Rejected — Violates Shipwright's resilience philosophy

### 2. Full Validation Suite (This Plan) ✅
- **Pros**: Comprehensive testing; production-ready; all edge cases covered
- **Cons**: 35–50 hours; extends timeline
- **Verdict**: Chosen — Aligns with quality gates and compliance requirements

### 3. Partial Validation (Core Only) ❌
- **Pros**: Faster than full validation (~15 hours)
- **Cons**: Skips edge cases (truncation, timeouts, spawn failures)
- **Verdict**: Rejected — Core resilience untested

**Why Full Validation Chosen**: Hive-mind integration is a new external dependency. Resilience (timeout handling, circuit breaker, graceful fallback) must be tested. Edge cases (diff truncation, partial agent spawn) must be covered. Task 4 (timeout & circuit breaker) and Task 7 (agent spawn failure) are critical to prevent production outages.

---

## Task Decomposition (8 Executable Tasks)

### Phase 1: Core Validation (4 tasks, ~15 hours)

#### Task 1: End-to-End Pipeline Integration (4–6 hours)
- **Test File**: `tests/e2e/audit-stage-integration.test.js` (NEW)
- **What**: Verify hive agents spawn; audit stage completes; findings persisted
- **Test Cases**: 
  1. Hive spawns and completes successfully
  2. Graceful fallback when ruflo unavailable
  3. Hive findings appended to audit log
- **Acceptance**: All 3 test cases pass; audit <5min; findings in artifact file
- **Depends On**: None

#### Task 2: Performance Benchmarking (2–3 hours)
- **Test File**: `tests/perf/audit-stage-benchmarks.test.js` (NEW)
- **What**: Measure hive init, orchestration, total latency; establish baselines
- **Benchmarks**:
  1. Hive init: avg <5s (5 iterations)
  2. Small diff (<1KB) orchestration: avg <30s (3 iterations)
  3. Large diff (~8KB) orchestration: avg <60s (3 iterations)
  4. Total audit stage: <90s (2 iterations)
- **Acceptance**: All 4 benchmarks meet targets; baseline documented
- **Depends On**: Task 1 must pass

#### Task 3: Security Validation (2–3 hours)
- **Test File**: `tests/security/audit-stage-security.test.js` (NEW)
- **What**: Verify specialist agents produce findings; no secrets leaked
- **Test Cases**:
  1. CVE scanner finds vulnerable dependency
  2. Secrets detector finds exposed API key
  3. OWASP auditor finds SQL injection risk
  4. Compliance checker validates ADR constraints
  5. No hardcoded secrets in code
  6. Artifacts in git-ignored directory
- **Acceptance**: All 4 agents produce findings; no secrets in code; artifacts secure
- **Depends On**: Task 1 must pass

#### Task 4: Timeout & Circuit Breaker Testing (2–3 hours)
- **Test File**: `tests/resilience/audit-circuit-breaker.test.js` (NEW)
- **What**: Test resilience when hive fails; timeout & circuit breaker recovery
- **Test Cases**:
  1. Orchestration timeout kills after 300s
  2. Circuit breaker increments on failure
  3. Circuit breaker disables ruflo after threshold
  4. Hive cleanup on SIGTERM (graceful shutdown)
- **Acceptance**: Timeout works; circuit breaker tracks failures; cleanup verified
- **Depends On**: None (independent testing)

---

### Phase 2: Hardening & Edge Cases (3 tasks, ~15 hours)

#### Task 5: Cross-Stage Context Injection (3–4 hours)
- **Test File**: `tests/integration/audit-context-injection.test.js` (NEW)
- **What**: Verify prior review findings and ADRs injected; used downstream
- **Test Cases**:
  1. Prior review findings injected into compliance_checker
  2. ADR context available in compliance check
  3. Findings persisted to pipeline namespace (downstream consumption)
- **Acceptance**: All findings injected; compliance agent flags violations; results in pipeline NS
- **Depends On**: Task 1 & 2 must pass

#### Task 6: Diff Truncation Edge Cases (2–3 hours)
- **Test File**: `tests/edge-cases/audit-diff-truncation.test.js` (NEW)
- **What**: Test audit behavior with large diffs; verify truncation handling
- **Test Cases**:
  1. Diff <8KB processed fully (no truncation)
  2. Diff >8KB truncated with warning
  3. Agents find issues in truncated region
  4. Large diffs don't cause memory exhaustion
- **Acceptance**: <8KB diffs untouched; >8KB diffs truncated with warning; agents find issues
- **Depends On**: Task 1 must pass

#### Task 7: Agent Spawn Failure Resilience (2–3 hours)
- **Test File**: `tests/resilience/audit-agent-spawn-failure.test.js` (NEW)
- **What**: Test audit behavior when agent spawn fails; graceful degradation
- **Test Cases**:
  1. Orchestration proceeds with partial agent spawn (non-fatal)
  2. Findings aggregated from N available agents (N < 4)
  3. Empty diff triggers early return
  4. Hive init failure detected and handled
- **Acceptance**: Audit continues even if spawn fails; findings from available agents; graceful fallback
- **Depends On**: Task 1 must pass

---

### Phase 3: Finalization & Documentation (1 task, ~10 hours)

#### Task 8: Documentation & Architecture Decision Record (6–8 hours)
- **Files to Create**:
  - `docs/ADR-AUDIT-STAGE-HIVE.md` (NEW) — Architecture Decision Record
  - `docs/AUDIT-STAGE-CONFIG.md` (NEW) — Configuration & operations guide
- **What**: Document architecture decisions; publish configuration guide
- **Content**:
  - ADR: Context, decision, consequences, alternatives, trade-offs
  - Config guide: Environment variables, configuration file, specialist roles, failure scenarios
- **Acceptance**: ADR approved; config guide published; all specialist roles documented
- **Depends On**: All Phase 1 & 2 tasks must pass

---

## Risk Analysis

| Risk | Probability | Impact | Mitigation | Status |
|------|-------------|--------|-----------|--------|
| **Validation exceeds 50 hours** | Medium | Medium | Break tasks into smaller batches; Task 4 can run parallel | 🔄 Monitoring |
| **Timeout handling missed** | Low | High | Task 4 explicitly tests SIGTERM + timeout scenarios | ✅ Covered |
| **Agent spawn failure breaks findings** | Low | High | Task 7 validates partial spawn failure recovery | ✅ Covered |
| **Diff truncation hides vulnerabilities** | Medium | High | Task 6 tests truncation edge cases; native fallback catches issues | ✅ Covered |
| **Cross-stage context not propagated** | Low | High | Task 5 validates ADR + review context injection | ✅ Covered |
| **Performance regression post-merge** | Low | Medium | Task 2 establishes baselines; monitor post-merge | ✅ Covered |
| **Documentation outdated by future changes** | Medium | Low | ADR + config guide in docs/; update on design changes | ✅ Covered |

---

## Definition of Done

### For Implementation ✅
- [x] `ruflo_execute_audit()` function implemented (scripts/lib/ruflo-adapter.sh:1035–1182)
- [x] Pipeline integration complete (scripts/lib/pipeline-stages-review.sh:680–698)
- [x] Event schema defined (config/event-schema.json)
- [x] 96 unit tests passing (scripts/sw-ruflo-adapter-test.sh)
- [x] Error handling & circuit breaker implemented
- [x] Fail-open design with native fallback
- [x] EXIT trap for SIGTERM-safe hive cleanup
- [x] Context injection (diff, ADRs, review findings)

### For Validation ⏳
- [ ] **Task 1**: E2E pipeline integration tests pass
- [ ] **Task 2**: Performance baselines established (<90s total)
- [ ] **Task 3**: Security validation complete (no secrets, all specialists produce findings)
- [ ] **Task 4**: Timeout & circuit breaker resilience verified
- [ ] **Task 5**: Cross-stage context injection verified
- [ ] **Task 6**: Diff truncation edge cases handled gracefully
- [ ] **Task 7**: Agent spawn failure resilience verified
- [ ] **Task 8**: ADR + configuration guide published
- [ ] All tests passing (unit + integration + resilience)
- [ ] Zero hardcoded secrets
- [ ] Performance targets met
- [ ] Ready for merge to main

---

## Implementation Details (For Reviewers)

### Core Function: `ruflo_execute_audit()`
- **File**: `scripts/lib/ruflo-adapter.sh`
- **Lines**: 1035–1182
- **Signature**: `ruflo_execute_audit(diff_content, artifact_file)`
- **Returns**: 0 (success, findings written) or 1 (failure, fallback to native)
- **Key Features**:
  - Hive init with topology=hierarchical, max_agents=4
  - Spawns 4 specialist agents (CVE, secrets, OWASP, compliance)
  - Stores diff, prior review, ADRs in shared hive memory
  - Orchestrates parallel audit (15 max turns, 300s timeout)
  - Aggregates findings via union (all additive)
  - Graceful hive shutdown (EXIT trap for SIGTERM)
  - Persists results to artifact file + pipeline namespace

### Pipeline Integration: `stage_audit()`
- **File**: `scripts/lib/pipeline-stages-review.sh`
- **Lines**: 680–698 (hive integration)
- **Behavior**:
  - Checks if ruflo available
  - Reads diff from `$ARTIFACTS_DIR/review-diff.patch`
  - Calls `ruflo_execute_audit()`
  - On success: Appends findings to audit log
  - On failure: Emits `ruflo.audit_fallback` event, continues
  - Always runs native sequential checks (secret scan, perms, etc.)

### Event Schema
- **File**: `config/event-schema.json`
- **Events**:
  - `ruflo.audit_start` (max_agents)
  - `ruflo.audit_complete` (hive_id, stage)
  - `ruflo.audit_failed` (reason)
  - `ruflo.audit_fallback` (reason)

---

## Execution Roadmap

### Immediate (Week 1)
1. **Approve this plan** with team lead
2. **Create Task 1 test file** (`tests/e2e/audit-stage-integration.test.js`)
3. **Run Task 1** (E2E integration tests)
4. **Report findings** (any regressions or unexpected behavior)

### Short-term (Week 2)
5. **Run Tasks 2, 3 parallel** (Performance benchmarking, Security validation)
6. **Run Task 4** (Timeout & circuit breaker) — can run parallel with 2/3
7. **Report Phase 1 complete** once all 4 tasks pass

### Medium-term (Week 3)
8. **Run Tasks 5, 6, 7 sequentially** (Cross-stage context, diff truncation, spawn failure)
9. **Report Phase 2 complete**

### Long-term (Week 4)
10. **Run Task 8** (Documentation & ADR)
11. **Merge to main** once all tasks pass
12. **Release** (include in next Shipwright version)

---

## Success Metrics

| Metric | Target | Validation Task | Status |
|--------|--------|-----------------|--------|
| Hive init latency | <5s avg | Task 2 | ⏳ Pending |
| Orchestration latency (8KB diff) | <60s avg | Task 2 | ⏳ Pending |
| Total audit stage | <90s | Task 2 | ⏳ Pending |
| Test pass rate | 100% (all phases) | Tasks 1–7 | ⏳ Pending |
| Timeout handling | Kills after 300s | Task 4 | ⏳ Pending |
| Agent spawn resilience | Works with N-1 agents | Task 7 | ⏳ Pending |
| Context injection | 100% propagation | Task 5 | ⏳ Pending |
| Diff truncation | Warns at 8KB, truncates cleanly | Task 6 | ⏳ Pending |
| Zero secrets | No hardcoded credentials | Task 3 | ⏳ Pending |
| E2E integration | Full pipeline works | Task 1 | ⏳ Pending |

---

## Related Documents

- **Implementation Details**: `docs/AUDIT-STAGE-IMPLEMENTATION-SUMMARY.md` (file paths, signatures, architecture)
- **Validation Tasks**: `docs/AUDIT-STAGE-VALIDATION-PLAN.md` (8 executable validation tasks)
- **Architecture Plan (Previous)**: `docs/AUDIT-STAGE-IMPLEMENTATION-PLAN.md` (design rationale, threat model)

---

## Approval & Tracking

### Approvals Needed
- [ ] Team lead approval of this validation plan
- [ ] Security review of threat model & mitigations
- [ ] Performance review of latency targets

### Tracking Checkpoints
- [ ] **Week 1**: Task 1 complete (E2E integration)
- [ ] **Week 2**: Phase 1 complete (Tasks 1–4)
- [ ] **Week 3**: Phase 2 complete (Tasks 5–7)
- [ ] **Week 4**: Phase 3 complete (Task 8)
- [ ] **Ready for merge**: All 8 tasks pass, ADR approved

---

## Contact & Questions

**Implementation Owner**: ezigus  
**Branch**: `feat/feat-ruflo-integrate-audit-stage-with-ru`  
**Issue**: #325

For questions on implementation details, see `docs/AUDIT-STAGE-IMPLEMENTATION-SUMMARY.md`.  
For execution details on validation tasks, see `docs/AUDIT-STAGE-VALIDATION-PLAN.md`.

