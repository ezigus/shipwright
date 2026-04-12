# Audit Stage Validation & Hardening Plan

**Issue**: feat(ruflo): integrate audit stage with ruflo hive-mind specialist security agents  
**Status**: Implementation Complete → Validation Phase  
**Target Completion**: 8 executable validation tasks  

---

## Overview

The audit stage hive-mind integration is **functionally complete** (commits 29d4ac94–2362a95e). This plan defines the 8 concrete validation and hardening tasks required to move from implementation to production-ready code.

**What's Already Done**:
- ✅ `ruflo_execute_audit()` function (scripts/lib/ruflo-adapter.sh:1035–1182)
- ✅ Pipeline integration in `stage_audit()` (scripts/lib/pipeline-stages-review.sh:680–698)
- ✅ Event schema definitions (config/event-schema.json)
- ✅ 96 unit tests passing (scripts/sw-ruflo-adapter-test.sh)

**What Remains**: 8 validation tasks split across 3 phases (35–50 hours total).

---

## Alternatives Considered

### Alternative 1: Skip Validation, Merge to Main
- **Pros**: Faster delivery
- **Cons**: Unvalidated production code; risk of silent failures; untested edge cases
- **Verdict**: ❌ Rejected — Shipwright's resilience philosophy requires validation

### Alternative 2: Full Validation Suite (This Plan)
- **Pros**: Comprehensive testing; all edge cases covered; production-ready code
- **Cons**: 35–50 hours; extends timeline
- **Verdict**: ✅ Chosen — Aligns with quality gates and compliance requirements

### Alternative 3: Partial Validation (Core Only, Skip Hardening)
- **Pros**: Faster than full validation (~15 hours)
- **Cons**: Edge cases (truncation, timeouts, spawn failures) untested
- **Verdict**: ❌ Rejected — Circuit breaker and resilience are core to the design

---

## Task Decomposition & Dependencies

### Phase 1: Core Validation (4 tasks, ~15 hours)

**Task 1 → Task 2 → Task 3** (sequential dependencies)  
**Task 4** (parallel with Tasks 1–3)

#### Task 1: End-to-End Pipeline Integration (4–6 hours)

**What**: Run full pipeline with audit stage enabled; verify hive agents spawn and execute.

**Files to Create/Modify**:
- `tests/e2e/audit-stage-integration.test.js` (NEW) — E2E test suite
- `scripts/lib/pipeline-stages-review.sh` — Add instrumentation for audit hive (read-only, no changes needed if already done)

**Implementation Steps**:
1. Create test file with vitest structure (following project conventions)
2. Test case: "Audit stage spawns hive and completes successfully"
   - Set `RUFLO_AVAILABLE=true` env var
   - Mock `ruflo` CLI to return valid hive_id
   - Call `stage_audit()` with sample diff
   - Assert `ruflo_execute_audit()` is called
   - Assert audit findings file exists
   - Assert no pipeline errors
3. Test case: "Audit stage gracefully falls back when ruflo unavailable"
   - Set `RUFLO_AVAILABLE=false`
   - Call `stage_audit()`
   - Assert native checks still run
   - Assert no fatal errors
4. Test case: "Hive audit findings appended to audit log"
   - Mock `ruflo_execute_audit()` to return findings file with test data
   - Call `stage_audit()`
   - Assert findings appear in `$ARTIFACTS_DIR/audit.log`

**Acceptance Criteria**:
- [ ] All 3 test cases pass
- [ ] Audit stage completes in <5 minutes
- [ ] Hive agents spawn (verify via event log: `ruflo.audit_start` event)
- [ ] Findings persisted to `$ARTIFACTS_DIR/audit-hive-context.md`
- [ ] Native checks run even if hive fails

**Dependencies**: None (Task 1 is independent)

---

#### Task 2: Performance Benchmarking (2–3 hours)

**What**: Measure hive init, orchestration, and total audit latency; verify targets.

**Files to Create**:
- `tests/perf/audit-stage-benchmarks.test.js` (NEW) — Performance test suite
- `docs/AUDIT-STAGE-PERF-BASELINE.md` (NEW) — Baseline documentation

**Implementation Steps**:
1. Create benchmark test file
2. Benchmark: "Hive init latency"
   - Measure time from `hive-mind init` call to agents ready
   - Run 5 iterations, report min/max/avg
   - Assert average <5s
3. Benchmark: "Orchestration latency (small diff <1KB)"
   - Measure time from `coordination orchestrate` start to findings ready
   - Run 3 iterations with 500-byte diff
   - Assert average <30s
4. Benchmark: "Orchestration latency (large diff <8KB)"
   - Measure time with 7KB diff (near truncation limit)
   - Run 3 iterations
   - Assert average <60s
5. Benchmark: "Total audit stage latency"
   - Measure complete `stage_audit()` execution
   - Run 2 iterations with realistic pipeline state
   - Assert <90s end-to-end

**Acceptance Criteria**:
- [ ] Hive init: avg <5s (5 iterations)
- [ ] Small diff orchestration: avg <30s (3 iterations)
- [ ] Large diff orchestration: avg <60s (3 iterations)
- [ ] Total audit stage: <90s (2 iterations)
- [ ] Baseline documented in `AUDIT-STAGE-PERF-BASELINE.md`

**Dependencies**: Requires Task 1 to pass (need working E2E integration)

---

#### Task 3: Security Validation (2–3 hours)

**What**: Verify all 4 specialist agents produce findings; no hardcoded secrets; artifacts secure.

**Files to Create**:
- `tests/security/audit-stage-security.test.js` (NEW) — Security validation suite

**Implementation Steps**:
1. Test case: "CVE scanner agent finds vulnerable dependency"
   - Create mock diff with `npm pkg@1.0.0` (known vuln version)
   - Mock agent to return CVE finding
   - Assert finding appears in aggregated results
   - Assert finding includes CVE ID, severity, remediation
2. Test case: "Secrets detector finds exposed API key"
   - Create mock diff with `export API_KEY=sk-ant-abc123xyz`
   - Mock agent to return secret finding
   - Assert secret pattern detected
   - Assert finding marked high severity
3. Test case: "OWASP auditor finds SQL injection risk"
   - Create mock diff with unsafe string concatenation in SQL query
   - Mock agent to return OWASP A03 finding
   - Assert finding references specific OWASP category
4. Test case: "Compliance checker validates ADR constraints"
   - Store sample ADRs in `adrs-<repo_hash>` namespace
   - Create mock diff violating documented constraint
   - Mock agent to return compliance violation
   - Assert finding references violated ADR
5. Test case: "No hardcoded secrets in audit code"
   - Grep `scripts/lib/ruflo-adapter.sh` for secret patterns
   - Assert no API keys, tokens, or credentials found
6. Test case: "Audit artifacts written to git-ignored directory"
   - Verify `$ARTIFACTS_DIR/audit-hive-context.md` path
   - Verify `.gitignore` includes `/.claude/pipeline-artifacts/`
   - Assert findings not leaked to version control

**Acceptance Criteria**:
- [ ] All 4 specialist agents produce findings in aggregated results
- [ ] Each finding includes severity, category, remediation
- [ ] No hardcoded secrets in ruflo-adapter.sh
- [ ] No credentials in CLI arguments (using memory NS instead)
- [ ] Artifacts in git-ignored directory
- [ ] Diff content bounded to 8KB (no truncation of critical issues)

**Dependencies**: Requires Task 1 to pass

---

#### Task 4: Timeout & Circuit Breaker Testing (2–3 hours)

**What**: Verify resilience when hive fails; test timeout recovery and circuit breaker logic.

**Files to Create**:
- `tests/resilience/audit-circuit-breaker.test.js` (NEW) — Circuit breaker test suite

**Implementation Steps**:
1. Test case: "Orchestration timeout stops after 300s"
   - Mock `ruflo coordination orchestrate` to hang indefinitely
   - Call `ruflo_execute_audit()` with 30s mock timeout (for test speed)
   - Assert orchestration process killed after timeout
   - Assert `ruflo.audit_failed` event with `reason=timeout`
   - Assert native checks still run
2. Test case: "Circuit breaker increments on hive failure"
   - Call `ruflo_execute_audit()` with failing hive init (5 times)
   - Assert `RUFLO_FAILURE_COUNT` increments after each failure
   - Assert event logged for each failure
3. Test case: "Circuit breaker disables ruflo after threshold"
   - Set `RUFLO_CIRCUIT_BREAKER_THRESHOLD=3` (from config or env)
   - Trigger 3 hive failures
   - On 4th call, assert ruflo skipped (circuit open)
   - Assert fallback to native checks
4. Test case: "Hive cleanup on SIGTERM (graceful shutdown)"
   - Mock `hive-mind shutdown` 
   - Send SIGTERM to `ruflo_execute_audit()` mid-orchestration
   - Assert EXIT trap fires
   - Assert `_ruflo_hive_shutdown()` called
   - Assert no orphaned agents left in system

**Acceptance Criteria**:
- [ ] Orchestration timeout kills process after threshold
- [ ] Circuit breaker tracks failure count correctly
- [ ] Ruflo disabled after N consecutive failures
- [ ] Native checks always run as fallback
- [ ] Graceful hive shutdown on SIGTERM (no orphaned processes)
- [ ] All failure modes emit events for audit trail

**Dependencies**: None (independent testing)

---

### Phase 2: Hardening & Edge Cases (3 tasks, ~15 hours)

**Task 5 → Task 6 → Task 7** (sequential dependencies)

#### Task 5: Cross-Stage Context Injection (3–4 hours)

**What**: Verify prior review findings and ADRs injected into audit agents; findings used downstream.

**Files to Create**:
- `tests/integration/audit-context-injection.test.js` (NEW)

**Files to Read/Understand** (no changes):
- `scripts/lib/ruflo-adapter.sh` — Lines 1097–1114 (context injection)
- `scripts/lib/pipeline-stages-review.sh` — Lines 659–693 (pipeline integration)

**Implementation Steps**:
1. Test case: "Prior review findings injected into compliance_checker"
   - Store sample review findings in `stage-review-result` key
   - Create mock diff with architectural change
   - Call `ruflo_execute_audit()`
   - Assert `audit-review-context` stored in hive namespace
   - Assert compliance_checker receives context (verify via memory list)
2. Test case: "ADR context available in compliance check"
   - Store sample ADRs (e.g., "Use TypeScript for all src/"):
     - Key: `architecture decisions`
     - Namespace: `adrs-<repo_hash>`
   - Create mock diff adding JavaScript file
   - Call `ruflo_execute_audit()`
   - Assert `audit-adrs` stored in audit namespace
   - Assert compliance finding flagged JavaScript file as ADR violation
3. Test case: "Findings persisted to pipeline namespace"
   - Call `ruflo_execute_audit()`
   - Assert `stage-audit-result` stored in `pipeline-${SHIPWRIGHT_PIPELINE_ID}` namespace
   - Assert result readable by downstream stages (deploy, monitor)

**Acceptance Criteria**:
- [ ] Prior review findings injected into audit hive
- [ ] ADR context available to compliance_checker agent
- [ ] Compliance agent flags ADR violations
- [ ] Stage results persisted to pipeline namespace
- [ ] Downstream stages can access audit findings

**Dependencies**: Requires Tasks 1 & 2 to pass

---

#### Task 6: Diff Truncation Edge Cases (2–3 hours)

**What**: Test audit behavior with large diffs; verify truncation handling.

**Files to Create**:
- `tests/edge-cases/audit-diff-truncation.test.js` (NEW)

**Implementation Steps**:
1. Test case: "Diff <8KB processed fully"
   - Create 7KB diff
   - Call `ruflo_execute_audit()`
   - Assert full diff stored in hive memory (verify via memory list)
   - Assert no truncation warning in logs
2. Test case: "Diff >8KB truncated with warning"
   - Create 10KB diff
   - Call `ruflo_execute_audit()`
   - Assert diff truncated to first 8KB
   - Assert warning logged: "audit diff exceeds 8KB"
   - Assert warning includes byte count
3. Test case: "Agents find issues in truncated content"
   - Create 10KB diff where:
     - First 7KB contains secret (within truncation)
     - Last 3KB contains CVE (truncated away)
   - Call `ruflo_execute_audit()`
   - Assert secret finding present
   - Assert CVE finding absent (expected, truncated)
   - Assert native fallback detects CVE
4. Test case: "Truncation bound prevents memory exhaustion"
   - Create artificially large diff (100KB)
   - Call `ruflo_execute_audit()`
   - Assert process completes (no OOM)
   - Assert audit findings still produced

**Acceptance Criteria**:
- [ ] Diffs <8KB processed without truncation
- [ ] Diffs >8KB truncated to first 8000 bytes
- [ ] Warning logged on truncation with actual byte count
- [ ] Agents find issues in truncated region
- [ ] Process survives large diffs (no memory exhaustion)

**Dependencies**: Requires Task 1 to pass

---

#### Task 7: Agent Spawn Failure Resilience (2–3 hours)

**What**: Test audit behavior when agent spawn fails; verify graceful degradation.

**Files to Create**:
- `tests/resilience/audit-agent-spawn-failure.test.js` (NEW)

**Implementation Steps**:
1. Test case: "Orchestration proceeds with partial agent spawn"
   - Mock `hive-mind spawn` to return exit 1 (fail)
   - Call `ruflo_execute_audit()`
   - Assert orchestration proceeds (spawn failure is non-fatal per code: `|| true`)
   - Assert findings aggregated from available agents (if any started)
2. Test case: "Findings aggregated from N available agents (N < 4)"
   - Mock spawn to start only 2 of 4 agents
   - Call `ruflo_execute_audit()`
   - Assert orchestration runs with 2 agents
   - Assert findings from 2 agents aggregated
   - Assert audit_complete event emitted
3. Test case: "Empty diff with available agents"
   - Pass empty diff to `ruflo_execute_audit()`
   - Assert function returns 1 (fail) due to empty diff check
   - Assert native checks run as fallback
4. Test case: "Hive init failure triggers fallback"
   - Mock `hive-mind init` to return invalid JSON
   - Call `ruflo_execute_audit()`
   - Assert hive_id extraction fails
   - Assert returns 1 (fail)
   - Assert `ruflo.audit_failed` event emitted
   - Assert native checks run

**Acceptance Criteria**:
- [ ] Audit continues even if agent spawn fails
- [ ] Findings aggregated from available agents
- [ ] Partial results still valuable (better than none)
- [ ] Hive init failure detected and handled
- [ ] Graceful fallback to native checks on any hive failure

**Dependencies**: Requires Task 1 to pass

---

### Phase 3: Finalization & Documentation (1 task, ~10 hours)

#### Task 8: Documentation & Architecture Decision Record (6–8 hours)

**What**: Create ADR documenting the audit stage hive-mind architecture; publish configuration guide.

**Files to Create**:
- `docs/ADR-AUDIT-STAGE-HIVE.md` (NEW) — Architecture Decision Record
- `docs/AUDIT-STAGE-CONFIG.md` (NEW) — Configuration & operations guide

**Implementation Steps**:

**Part A: ADR Document (3–4 hours)**
1. Create `docs/ADR-AUDIT-STAGE-HIVE.md` with structure:
   ```
   # ADR-XXX: Hive-Mind Parallel Security Audit Stage
   
   ## Status
   ACCEPTED (2026-04-12)
   
   ## Context
   - Single-threaded native audit too slow for complex diffs
   - No CVE scanning, OWASP analysis, or compliance checking
   - Need parallel specialist expertise
   
   ## Decision
   Implement ruflo_execute_audit() spawning 4 specialist agents:
   - cve_scanner, secrets_detector, owasp_auditor, compliance_checker
   - Parallel via hive-mind coordination
   - Fail-open (native checks always run)
   
   ## Consequences
   - +Parallel execution (3-4x faster)
   - +Specialist expertise (CVE, secrets, OWASP, ADRs)
   - -External dependency (ruflo)
   - -~300s timeout overhead on hive failure
   
   ## Alternatives Considered
   [Reference Alternatives 1-3 from above]
   
   ## Trade-offs Accepted
   [List all trade-offs from design]
   ```

**Part B: Configuration Guide (3–4 hours)**
2. Create `docs/AUDIT-STAGE-CONFIG.md`:
   ```
   # Audit Stage Configuration Guide
   
   ## Overview
   Parallel security audit via ruflo hive-mind.
   
   ## Environment Variables
   - RUFLO_AUDIT_MAX_AGENTS (default: 4)
   - RUFLO_USE_NPX (default: false, set true if no ruflo in PATH)
   - RUFLO_CIRCUIT_BREAKER_THRESHOLD (default: 5)
   
   ## Configuration File (.shipwright/defaults.json)
   ```json
   {
     "ruflo": {
       "max_agents": 4,
       "circuit_breaker_timeout_s": 300,
       "learning_bridge": true
     }
   }
   ```
   
   ## Specialist Agent Roles
   - **cve_scanner**: Dependency scanning (npm audit + SBOM)
   - **secrets_detector**: Credential leak analysis
   - **owasp_auditor**: Top-10 vulnerability assessment
   - **compliance_checker**: ADR constraint validation
   
   ## Failure Scenarios & Recovery
   [Document each failure mode and recovery steps]
   ```

3. Document each specialist agent:
   - Input: diff content, prior review findings, ADRs
   - Output: findings with severity, category, remediation
   - Success/failure criteria

4. Document configuration options:
   - Max agents (memory/compute trade-off)
   - Timeout values (latency vs. stability)
   - Circuit breaker threshold

5. Document failure scenarios:
   - Ruflo unavailable → native checks
   - Hive init failure → return 1
   - Orchestration timeout → kill after 300s
   - Agent spawn failure → continue with available agents
   - Diff truncation → warning logged, truncated to 8KB

**Acceptance Criteria**:
- [ ] ADR created with full context/decision/consequences
- [ ] ADR reviewed and accepted (document approval)
- [ ] Configuration guide published with examples
- [ ] Specialist roles documented with input/output contracts
- [ ] Failure scenarios documented with recovery procedures
- [ ] Configuration guide includes troubleshooting section

**Dependencies**: Requires all Phase 1 & 2 tasks to pass

---

## Risk Analysis

| Risk | Probability | Impact | Mitigation | Status |
|------|-------------|--------|-----------|--------|
| **Validation takes >50 hours** | Medium | Medium | Break into smaller batches; parallelize independent tasks (Task 4) | 🔄 Monitoring |
| **Hive timeout handling missed** | Low | High | Task 4 explicitly tests timeout + SIGTERM scenarios | ✅ Covered |
| **Agent spawn failure silently breaks findings** | Low | High | Task 7 validates partial spawn failure recovery | ✅ Covered |
| **Diff truncation hides critical vulns** | Medium | High | Task 6 tests truncation edge cases; native fallback catches issues | ✅ Covered |
| **Cross-stage context not propagated** | Low | High | Task 5 validates ADR + review context injection downstream | ✅ Covered |
| **Performance regression after validation** | Low | Medium | Task 2 establishes baselines; monitor regressions post-merge | ✅ Covered |
| **Documentation outdated by future changes** | Medium | Low | ADR + config guide in docs/; update on design changes | ✅ Covered |

---

## Definition of Done

### For Each Validation Task
- [ ] Test file created (`.test.js` following project conventions)
- [ ] All test cases pass
- [ ] Acceptance criteria explicitly verified
- [ ] Code coverage >80% for tested functionality
- [ ] No manual workarounds or hacks

### For Phase 1 (Core Validation)
- [ ] Task 1: E2E integration tests pass
- [ ] Task 2: Performance baselines established and documented
- [ ] Task 3: Security validation complete (no secrets, findings verified)
- [ ] Task 4: Resilience tests pass (timeout, circuit breaker, graceful shutdown)

### For Phase 2 (Hardening)
- [ ] Task 5: Cross-stage context verified in downstream stages
- [ ] Task 6: Diff truncation edge cases handled gracefully
- [ ] Task 7: Partial agent spawn failure doesn't break audit

### For Phase 3 (Finalization)
- [ ] Task 8: ADR approved and configuration guide published

### Overall Done
- [x] Implementation complete (commits 29d4ac94–2362a95e)
- [ ] Phase 1 validation complete (Tasks 1–4)
- [ ] Phase 2 hardening complete (Tasks 5–7)
- [ ] Phase 3 finalization complete (Task 8)
- [ ] All tests passing (unit + integration + resilience)
- [ ] Performance targets met (<90s total audit stage)
- [ ] Zero hardcoded secrets
- [ ] Artifacts in git-ignored directory
- [ ] ADR + configuration guide published
- [ ] Ready for merge to main and release

---

## Success Metrics

| Metric | Target | Validation Task |
|--------|--------|-----------------|
| Hive init latency | <5s avg | Task 2 |
| Orchestration latency | <60s (8KB diff) | Task 2 |
| Total audit stage | <90s | Task 2 |
| Test pass rate | 100% (all phases) | Tasks 1–7 |
| Agent spawn resilience | Works with N-1 agents | Task 7 |
| Timeout handling | Kills after 300s | Task 4 |
| Context injection | 100% propagation to downstream | Task 5 |
| Diff truncation | Warns at 8KB, truncates cleanly | Task 6 |

---

## Next Steps (Immediate Actions)

1. **Create Task 1 test file** (`tests/e2e/audit-stage-integration.test.js`)
   - Copy vitest structure from existing tests (e.g., `tests/policy/*.test.js`)
   - Implement 3 test cases (spawn, fallback, findings)
   - Run: `npm test -- audit-stage-integration.test.js`

2. **Run Phase 1 sequentially** (Tasks 1→2→3, Task 4 parallel)
   - Task 1: E2E integration (4–6h)
   - Task 2: Performance benchmarks (2–3h)
   - Task 3: Security validation (2–3h)
   - Task 4: Timeout & circuit breaker (2–3h parallel)

3. **Report after Phase 1**
   - Summary of findings
   - Any regressions or unexpected behavior
   - Blockers for Phase 2

---

## Related Files & Commit History

| Item | Location |
|------|----------|
| Implementation | commits 29d4ac94–2362a95e |
| Core function | scripts/lib/ruflo-adapter.sh:1035–1182 |
| Pipeline integration | scripts/lib/pipeline-stages-review.sh:680–698 |
| Unit tests | scripts/sw-ruflo-adapter-test.sh (96 passing) |
| Event schema | config/event-schema.json |
| Issue | #325 |

---

## Approval & Tracking

- [ ] Plan approved by team lead
- [ ] Task 1 started
- [ ] Phase 1 complete
- [ ] Phase 2 complete
- [ ] Phase 3 complete
- [ ] Merged to main

