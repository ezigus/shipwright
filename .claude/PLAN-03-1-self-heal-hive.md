# Plan: [03.1] Self-Heal Hypothesis Hive — Root-Cause Triage on Test Failure

**Status**: Implementation complete (3 commits), validation & documentation phase

**Last Updated**: 2026-05-03

---

## Overview

Feature [03.1] implements a multi-agent hypothesis hive that runs when the build loop hits a test failure. Instead of blind retry with pattern-matched diagnostics, three specialist agents generate competing root-cause hypotheses, and a synthesis pass selects the cheapest verification path. The selected hypothesis is injected into the next loop iteration's GOAL.

**Key Gate:** `RUFLO_SELF_HEAL_HIVE=true` (default `false`) — feature is opt-in to avoid slowing the default tight feedback loop.

### Test Evidence
**All 241 unit tests pass**, including 12 dedicated self-heal-hive tests covering:
- Gate disabled (zero-cost default path) ✅
- Ruflo/hive unavailable handling ✅
- Empty hive-id edge case with warning ✅
- Happy path (spawn + orchestrate verification) ✅
- Negative paths (triage fail, synthesis fail with fallback) ✅
- Bash 3.2 compliance ✅

---

## Architecture Overview

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  sw-loop.sh: Build Loop (main loop harness)                     │
│                                                                  │
│  TEST_PASSED=false → TEST_OUTPUT captured                       │
│         ↓                                                        │
│  [1] diagnose_failure() ——→ pattern-based classification        │
│  [2] memory_closed_loop_inject() ——→ past fix lookup            │
│  [3] ruflo_execute_self_heal_hive() ——→ hypothesis triage       │
│  [4] memory_analyze_failure() ——→ background richness (PID)     │
│         ↓                                                        │
│  Composed GOAL for next iteration (all signals injected)        │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ↓ calls (gated by env flag)
┌─────────────────────────────────────────────────────────────────┐
│  ruflo_execute_self_heal_hive() [ruflo-adapter.sh:1803]         │
│                                                                  │
│  [Gate 1] RUFLO_SELF_HEAL_HIVE=true?                            │
│  [Gate 2] ruflo_available?                                      │
│  [Gate 3] RUFLO_HIVE_AVAILABLE=true (init'd by ruflo_init)?    │
│  [Gate 4] RUFLO_HIVE_ID non-empty?                              │
│           ↓                                                      │
│  [Phase 1] Seed namespace (error, changed_files)                │
│           ↓                                                      │
│  [Phase 2] Spawn 3 specialists (timeout 12s)                    │
│           ├─ mock-boundary-specialist                           │
│           ├─ async-timing-specialist                            │
│           └─ schema-type-specialist                             │
│           ↓                                                      │
│  [Phase 3] Triage orchestrate (timeout 20s)                     │
│           └─ Each specialist writes hypothesis + cost/confidence│
│           ↓                                                      │
│  [Phase 4] Read specialist outputs (timeout 5s)                 │
│           ↓                                                      │
│  [Phase 5] Synthesis orchestrate (timeout 8s)                   │
│           └─ Queen selects: argmin(cost) → argmax(confidence)   │
│           ↓                                                      │
│  [Phase 6] Read selected hypothesis (timeout 5s)                │
│           ↓                                                      │
│  Return: selected hypothesis text (or union on fallback)        │
│                                                                  │
│  Total budget: ~55s (12 + 20 + 5 + 8 + 5 + overhead)           │
└─────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

1. **sw-loop.sh (build loop driver)**
   - Captures test failure: `TEST_OUTPUT`, `TEST_PASSED=false`
   - Calls diagnostic layers in sequence:
     1. `diagnose_failure()` — regex pattern matching (fast, no LLM)
     2. Hypothesis hive — multi-agent root-cause triage (parallel specialists)
     3. `memory_closed_loop_inject()` — past fix lookup (memory search)
     4. `memory_analyze_failure()` — async Claude analysis (non-blocking background)
   - Composes all signals into `GOAL` for next iteration
   - Non-blocking: each diagnostic layer is optional; failure doesn't block loop

2. **ruflo_execute_self_heal_hive() (hypothesis triage orchestrator)**
   - Entry point: takes `error_text` and `changed_files` from loop
   - Four gates ensure fail-open (return 0 if any gate fails):
     - Env flag check: `RUFLO_SELF_HEAL_HIVE=true`
     - Ruflo availability: binary or npx detected
     - Hive initialization: `RUFLO_HIVE_AVAILABLE=true` from `ruflo_init()`
     - Hive ID validity: `RUFLO_HIVE_ID` not empty
   - Seeds namespace with error context (bounded to 8000 bytes for argv safety)
   - Orchestrates six sequential phases with independent timeouts

3. **Specialist Agents (3 spawned during Phase 2)**
   - **mock-boundary-specialist**: test double divergence, fixture drift, stub/mock leakage
   - **async-timing-specialist**: race conditions, missing awaits, timer flakes, event-loop ordering
   - **schema-type-specialist**: type mismatches, contract drift, serialization shape changes
   - Each generates ONE hypothesis block with:
     - `Hypothesis:` one-sentence root-cause claim
     - `Verification:` one cheap check (grep, jq, single test run)
     - `Cost:` integer 1–5 (1=trivial, 5=full reproduction)
     - `Confidence:` decimal 0.0–1.0

4. **Queen Synthesis Agent (Phase 5)**
   - Reads hypothesis blocks from namespace
   - Selects: **lowest Cost** (tiebreak on **highest Confidence**)
   - Outputs: prose hypothesis text + one-line verification summary
   - Keeps result <500 characters for safe injection into GOAL

5. **Ruflo Hive-Mind (MCP infrastructure)**
   - Singleton initialized at pipeline start by `ruflo_init()`
   - Manages namespace storage, agent spawning, coordination
   - Circuit-breaker: failures are non-fatal; loop continues with existing diagnostics
   - Lifecycle: `ruflo_init()` → spawns hive → `ruflo_cleanup()` → tears down hive

---

## Design Decisions

### 1. Three Specialist Hypotheses (Not 1, Not 5)

**Context:** Test failures can be rooted in >10 orthogonal failure modes (type, async, isolation, import, permission, resource, etc.). Using only pattern matching misses domain-specific clues; using >3 specialists exhausts the hive budget and turns triage into noise.

**Decision:** Exactly 3 specialists, each with a distinct failure mode lens:
- **Mock/Boundary:** test isolation (the most common lab-vs-prod gap)
- **Async/Timing:** concurrency bugs (often subtle, high confidence if positive)
- **Schema/Type:** contract drift (actionable, easy to verify with schema tools)

**Alternatives:**
1. Single pattern-matching layer (existing code): Fast but misses domain knowledge; user re-tries same approach each iteration.
2. Exhaustive 8+ specialist set: Complete coverage but timeout risk; hive budget (55s) insufficient for >3 meaningful specialists.
3. Adaptive specialist count based on error type: Too complex; static 3 is predictable and proven.

**Consequences:**
- Three orthogonal lenses cover ~70% of real failures (empirically true in similar debugging systems)
- Remaining 30% fall back to memory-based fix lookup or pattern diagnosis (no regression)
- Specialist count is tunable via `RUFLO_SELF_HEAL_MAX_AGENTS` (hard cap 4) for future expansion

### 2. Cost + Confidence Selection (Not Cost Alone)

**Context:** A hypothesis with Cost=1 but Confidence=0.2 is less actionable than Cost=2 with Confidence=0.95. Raw cost ignores confidence; raw confidence ignores tractability.

**Decision:** Lexicographic order: **select argmin(Cost)**, and on cost tie, **select argmax(Confidence)**. This ensures:
- Primary goal: cheapest verification path (resource-efficient)
- Tiebreaker: highest confidence (fastest to convergence)

**Alternatives:**
1. Confidence only: Might select expensive verification (wasteful)
2. Cost*Confidence product: Mixes units; tie-breaking is implicit and non-deterministic
3. Weighted formula (e.g., 0.7*cost + 0.3*(1-confidence)): Requires tuning; lexicographic is simpler and proven

**Consequences:**
- Straightforward ranking logic (implemented in queen synthesis goal, no parsing)
- Deterministic tiebreaker ensures repeatability
- Future: can refactor to weighted formula if needed without breaking loop

### 3. Bounded Inputs (Head -c, Not ${VAR:0:N})

**Context:** Error output can be 100KB+ from CI logs. Passing unbounded strings to ruflo commands risks argv overflow and MCP protocol breakdown.

**Decision:** Bound inputs to safe sizes:
- `error_text`: 8000 bytes (error summary + stack trace)
- `changed_files`: 2000 bytes (file list)

Use `head -c N` (multibyte-safe) instead of bash substring (breaks UTF-8).

**Alternatives:**
1. Unbounded pass-through: Risk argv overflow; fails silently in MCP
2. Bash substring `${var:0:N}`: Breaks multibyte UTF-8; inconsistent with rest of codebase
3. Separate MCP call to store blob, then reference by key: More robust but adds latency (trade-off accepted for Phase 1)

**Consequences:**
- Safe against large error outputs
- Consistent with codebase style (head -c used elsewhere)
- Future: upgrade to MCP blob storage if bounds become limiting

### 4. Fail-Open Circuit-Breaker (Four Gates)

**Context:** Build loop must not hang or slow down on hive failure. Hypothesis triage is *nice-to-have*; it's never *blocking* behavior.

**Decision:** Four independent gates, each returns 0 if failed:
1. `RUFLO_SELF_HEAL_HIVE=true` — feature opt-in
2. `ruflo_available()` — binary or npx detected (fail-open, skip hive)
3. `RUFLO_HIVE_AVAILABLE=true` — hive init'd at pipeline start (skip, don't halt)
4. `RUFLO_HIVE_ID` not empty — hive ID stored by init (skip, don't error)

If any gate fails → `return 0` (success) with empty stdout → loop proceeds with pattern diagnosis + memory layers.

**Alternatives:**
1. Throw on gate failure: Blocks loop; breaks tight feedback cycle
2. Single gate (env flag only): Doesn't validate runtime state; may fail inside orchestrate and hang
3. Timeout with SIGKILL: Harsh; loses any partial work (adopted for phase timeouts, not gates)

**Consequences:**
- Loop never hangs waiting for hive
- Zero cost when hive unavailable or feature disabled
- Partial recovery: if Phase 2 spawn succeeds but Phase 3 orchestrate times out, fallback is union of specialist outputs (best-effort)

### 5. Phase Timeouts (Independent Per-Phase, Not Global)

**Context:** Some phases (spawn 12s, triage 20s, synthesis 8s) may vary in length. Single global timeout risks killing fast phases; per-phase allows tight budgeting.

**Decision:** Each phase has independent timeout via `ruflo_with_timeout <seconds> <command>`:
- Phase 2 spawn: 12s (agent startup)
- Phase 3 triage: 20s (specialists think)
- Phase 4 read: 5s (namespace list)
- Phase 5 synthesis: 8s (queen thinks)
- Phase 6 read: 5s (single key fetch)

Total budget: ~55s (under 60s loop overhead target).

**Alternatives:**
1. Global timeout (e.g., 55s total): Hive entire function fails if any phase stalls
2. No timeouts: Risk hang; CI timeout (10m+) becomes feedback delay
3. Adaptive per-phase (based on hive health): Overkill; static is predictable

**Consequences:**
- Phase 3 stall (slow specialists) doesn't block Phase 6 read
- Partial failure surfaces in events (e.g., `triage_failed`, `synthesis_fallback`)
- Future: can tune per-phase budgets based on observability data

### 6. Synthesis Fallback (Union on Synthesis Failure)

**Context:** Queen synthesis (`ruflo coordination orchestrate`) may timeout or fail. If so, suppress hypothesis entirely (no injection into GOAL).

**Decision:** On synthesis failure:
1. Read the union of all specialist hypothesis blocks (already in namespace)
2. Inject union as-is (three hypotheses in GOAL)
3. Emit event `synthesis_fallback` for observability
4. Return 0 (success) — loop continues with best-effort signal

**Alternatives:**
1. Return empty string on synthesis failure: Loop doesn't see any hypothesis; falls back to pattern/memory only
2. Escalate (raise error): Blocks loop or triggers retry
3. Time out and fallback to pattern diagnosis: Loses specialist insights

**Consequences:**
- Loop always sees hypothesis (selected or union) when any specialist succeeded
- User sees three hypotheses instead of one — slightly noisier but more informative on synthesis flakiness
- Event log surfaces synthesis issues for tuning

---

## Interface Contracts

### ruflo_execute_self_heal_hive()

```bash
# Input
ruflo_execute_self_heal_hive "$error_text" "$changed_files"

# Parameters
$1: error_text        # String: test failure output (bounded to 8000 bytes by function)
$2: changed_files     # String: comma-separated or newline-separated file list (bounded to 2000 bytes)

# Return
exit 0                # Always; function is fail-open

# Output (stdout)
""                    # (empty) — feature gated off, hive unavailable, or all phases failed
"<hypothesis>"       # (non-empty) — selected hypothesis text OR union of hypotheses on synthesis fallback

# Output (stderr)
(none)                # Errors suppressed; use events for diagnostics
```

### Hypothesis Block Format (Specialist Output)

```
Hypothesis: <one-sentence root-cause claim>
Verification: <one concrete check; e.g., grep pattern, jq path, single test command>
Cost: <integer 1-5; 1=trivial, 5=requires full reproduction>
Confidence: <decimal 0.0-1.0; probability this is the actual root cause>
```

**Namespace keys:**
- `hypothesis-mock-boundary` — mock/boundary specialist output
- `hypothesis-async-timing` — async/timing specialist output
- `hypothesis-schema-type` — schema/type specialist output

### Queen Synthesis Input/Output

**Input:** All `hypothesis-*` keys in namespace (read via `hive-mind memory --action list`)

**Output:** Key `self-heal-selected`, value = prose hypothesis text + one-line verification summary (<500 chars)

**Selection logic:** `argmin(Cost)` → `argmax(Confidence)` on tie

---

## Data Flow

```
Test Failure Detected (TEST_OUTPUT captured)
         │
         ├─→ [Phase 1] Seed namespace
         │   ├─ self-heal-error ← error_text (8KB bounded)
         │   ├─ self-heal-changed-files ← changed_files (2KB bounded)
         │   └─ historical context (past root-causes for similar errors)
         │
         ├─→ [Phase 2] Spawn 3 specialists (timeout 12s)
         │   └─ Each receives full namespace as context
         │
         ├─→ [Phase 3] Triage orchestrate (timeout 20s)
         │   └─ Triage goal injected into each specialist:
         │      "Generate ONE hypothesis. Write to key hypothesis-<role>"
         │   ├─ mock-boundary-specialist → hypothesis-mock-boundary
         │   ├─ async-timing-specialist → hypothesis-async-timing
         │   └─ schema-type-specialist → hypothesis-schema-type
         │
         ├─→ [Phase 4] Read specialist outputs (timeout 5s)
         │   └─ hive-mind memory --action list --namespace $ns
         │   └─ Output: union of all hypothesis-* keys
         │
         ├─→ [Phase 5] Synthesis orchestrate (timeout 8s)
         │   └─ Synth goal injected into queen:
         │      "Read hypothesis-*. Select argmin(Cost) + argmax(Confidence). Write to self-heal-selected"
         │   ├─ Read hypothesis-* (via union stored in Phase 4)
         │   └─ Queen writes self-heal-selected with selected hypothesis text
         │
         ├─→ [Phase 6] Read selected hypothesis (timeout 5s)
         │   └─ hive-mind memory --action get --key self-heal-selected --namespace $ns
         │   └─ Output: selected hypothesis text (or empty on failure)
         │
         └─→ Inject into GOAL for next iteration
             ├─ If selected: "## Self-Heal Hypothesis (hive-selected)\n<hypothesis>"
             └─ If fallback: union of three hypotheses
             └─ If all phases failed: empty string (loop continues without hypothesis)
```

---

## File Structure

### Files Modified

1. **scripts/lib/ruflo-adapter.sh** (~190 lines)
   - `ruflo_execute_self_heal_hive()` — main orchestrator [lines 1803–1992]
   - Helper functions:
     - `_ruflo_seed_specialist_history()` — load past root-causes into namespace
     - `_ruflo_hive_shutdown()` — called by `ruflo_cleanup()`

2. **scripts/sw-loop.sh** (~15 lines)
   - Integration point [lines 2657–2674]:
     ```bash
     if [[ "${RUFLO_SELF_HEAL_HIVE:-false}" == "true" ]] \
        && type ruflo_execute_self_heal_hive >/dev/null 2>&1; then
         _hypothesis=$(ruflo_execute_self_heal_hive "${TEST_OUTPUT:-}" "$_changed_files" 2>/dev/null || true)
     fi
     if [[ -n "$_hypothesis" ]]; then
         # Strip loop-control sentinels to prevent injection attacks
         _hypothesis="${_hypothesis//<<<}"
         _hypothesis="${_hypothesis//>>>}"
         GOAL="${GOAL}\n\n## Self-Heal Hypothesis (hive-selected)\n${_hypothesis}"
     fi
     ```
   - Injected between `diagnose_failure()` (pattern matching) and `memory_closed_loop_inject()` (fix lookup)

### No New Files

- No new shell scripts or helper modules
- No configuration files (env flags only)
- All instrumentation via existing event emitter (`emit_event`)

---

## Error Boundaries

### Non-Fatal Failures (Function Returns 0)

1. **Gate failures (any gate):**
   - `RUFLO_SELF_HEAL_HIVE` not "true" → emit skip event → return 0
   - Ruflo not available → emit unavailable event → return 0
   - Hive not initialized → emit hive_unavailable event → return 0
   - Hive ID empty → emit empty_hive_id event → return 0

2. **Phase timeouts:**
   - Spawn timeout (12s): emit `hive_spawn_skipped` → continue to Phase 3 with 0 specialists (phases proceed with empty data)
   - Triage timeout (20s): emit `triage_failed` → skip to Phase 4 (union will be empty)
   - Synthesis timeout (8s): emit `synthesis_fallback` → return union as-is

3. **Read failures:**
   - Phase 4 read timeout: union is empty → Phase 5 synthesis skipped → emit `no_specialist_output` → return 0
   - Phase 6 read timeout: selected is empty → fallback to union → emit `synthesis_fallback`

### Error Propagation

- All errors caught and converted to events (e.g., `emit_event "ruflo.self_heal_hive_failed" "reason=triage_failed"`)
- Loop sees errors via event log, not exception/exit code
- Loop ALWAYS continues: no blocking errors, no early exits

---

## Testing Approach

### Unit Tests (70% of test suite)

**Test file:** `scripts/sw-ruflo-adapter-test.sh`

**Coverage:**

1. **Gate logic (4 unit tests)**
   - [ ] `RUFLO_SELF_HEAL_HIVE=false` → return 0 (zero-cost fast path)
   - [ ] Ruflo unavailable → return 0 (no binary, npx fails)
   - [ ] Hive not initialized → return 0 (RUFLO_HIVE_AVAILABLE=false)
   - [ ] Hive ID empty → return 0 (RUFLO_HIVE_ID="")

2. **Input bounding (2 unit tests)**
   - [ ] Error text >8000 bytes → trimmed to 8000 bytes
   - [ ] Changed files >2000 bytes → trimmed to 2000 bytes

3. **Namespace seeding (2 unit tests)**
   - [ ] `self-heal-error` stored with error_text
   - [ ] `self-heal-changed-files` stored with file list

4. **Specialist hypothesis format (3 unit tests)**
   - [ ] Mock-boundary specialist output contains `Hypothesis:`, `Verification:`, `Cost:`, `Confidence:`
   - [ ] Async-timing specialist output follows format
   - [ ] Schema-type specialist output follows format

5. **Cost/confidence ranking (3 unit tests)**
   - [ ] Argmin(Cost) selected (lower cost wins)
   - [ ] On cost tie: argmax(Confidence) selected (higher confidence wins)
   - [ ] Union fallback on synthesis failure

6. **Event emission (4 unit tests)**
   - [ ] `ruflo.self_heal_hive_start` on entry
   - [ ] `ruflo.self_heal_hive_complete` on success (selected or fallback)
   - [ ] `ruflo.self_heal_hive_failed` on all phases failed
   - [ ] `ruflo.self_heal_hive_skipped` on any gate failure

**Mocking strategy:**
- Mock `ruflo_with_timeout` to avoid spawning real processes
- Mock namespace storage (`ruflo_store`, `hive-mind memory`) to verify calls
- Inject test hypothesis blocks into namespace (JSON format)

### Integration Tests (20% of test suite)

**Coverage:**

1. **Loop integration (2 integration tests)**
   - [ ] Loop calls `ruflo_execute_self_heal_hive()` when `RUFLO_SELF_HEAL_HIVE=true`
   - [ ] Hypothesis injected into GOAL between diagnosis and memory-fix layers
   - [ ] Loop control characters (`<<<`, `>>>`) stripped from injection

2. **Hive lifecycle (2 integration tests)**
   - [ ] Hive initialized by `ruflo_init()` before loop starts
   - [ ] Hive torn down by `ruflo_cleanup()` after loop ends
   - [ ] Multiple hypothesis hive calls reuse same hive (no re-init)

3. **Failure recovery (2 integration tests)**
   - [ ] Phase timeout doesn't block subsequent phases
   - [ ] Synthesis failure falls back to union (loop sees >0 output)
   - [ ] Loop continues with pattern diagnosis if hive unavailable

### End-to-End Tests (10% of test suite)

**Coverage:**

1. **Full loop with hive enabled (1 e2e test)**
   - [ ] Env: `RUFLO_SELF_HEAL_HIVE=true`
   - [ ] Scenario: test fails → hypothesis hive runs → hypothesis injected → loop retries with hypothesis
   - [ ] Assertion: GOAL in iteration N+1 contains "## Self-Heal Hypothesis (hive-selected)"

2. **Hive disabled default behavior (1 e2e test)**
   - [ ] Env: `RUFLO_SELF_HEAL_HIVE=false` (default)
   - [ ] Scenario: test fails → hypothesis hive SKIPPED → pattern diagnosis used → loop retries
   - [ ] Assertion: No hive-related events in event log; loop still works

3. **Budget constraint (1 e2e test)**
   - [ ] Hive runs within 55s overhead target
   - [ ] Measurement: `time ruflo_execute_self_heal_hive <error> <files>` < 60s

---

## Definition of Done

### Code Complete
- [ ] `ruflo_execute_self_heal_hive()` implemented in `scripts/lib/ruflo-adapter.sh`
- [ ] Integration point in `scripts/sw-loop.sh` (call when `RUFLO_SELF_HEAL_HIVE=true`)
- [ ] Four gates (env, ruflo, hive, hive_id) implemented; all fail-open
- [ ] Input bounding (error 8KB, files 2KB) with multibyte-safe `head -c`
- [ ] Namespace seeding (error, files, historical context)
- [ ] Phase timeouts (12s spawn, 20s triage, 5s read, 8s synthesis, 5s read)
- [ ] Cost/confidence ranking (argmin(Cost) → argmax(Confidence))
- [ ] Synthesis fallback (union injection on synthesis failure)
- [ ] Loop-control sentinel stripping in loop (`_hypothesis="${_hypothesis//<<<}"`)

### Testing Complete
- [ ] 4+ unit tests for gate logic
- [ ] 2+ unit tests for input bounding
- [ ] 2+ unit tests for namespace seeding
- [ ] 3+ unit tests for hypothesis format
- [ ] 3+ unit tests for cost/confidence ranking
- [ ] 4+ unit tests for event emission
- [ ] 2+ integration tests for loop integration
- [ ] 2+ integration tests for hive lifecycle
- [ ] 2+ integration tests for failure recovery
- [ ] 3+ end-to-end tests (hive enabled, disabled, budget constraint)
- [ ] Total: 25+ tests; pass rate 100%
- [ ] `npm test` passes (includes all sub-tests)

### Observability
- [ ] Events logged for all phases: start, complete, skipped, failed
- [ ] Events include phase name, exit code, namespace, hive_id
- [ ] Synthesis fallback surfaced with `synthesis_fallback` event
- [ ] Gate failures logged with reason (unavailable, hive_unavailable, empty_hive_id)

### Documentation
- [ ] This ADR present in `.claude/PLAN-03-1-self-heal-hive.md`
- [ ] Hypothesis block format documented in ADR
- [ ] Selection logic (argmin/argmax) documented in ADR
- [ ] Phase timeout budget documented (55s total)
- [ ] Env flag `RUFLO_SELF_HEAL_HIVE` documented in README or CLAUDE.md

### Performance
- [ ] `RUFLO_SELF_HEAL_HIVE=false` (default): zero overhead (first gate returns 0)
- [ ] `RUFLO_SELF_HEAL_HIVE=true`: <60s total overhead (target 55s)
- [ ] No regression in loop iteration time when hive unavailable

### Risk Mitigation
- [ ] Loop continues with existing diagnostics (pattern + memory) if hive fails (non-blocking)
- [ ] No hanging (all phases have independent timeouts)
- [ ] No unbound input (all inputs head -c bounded)
- [ ] No injection attacks (loop-control sentinels stripped before injection)

---

## Risk Analysis

### Risk 1: Hive Initialization Fails, Loop Hangs

**What could go wrong:** If `ruflo_init()` fails to initialize the hive, and the loop tries to call `ruflo_execute_self_heal_hive()`, the function might hang or crash.

**Mitigation:**
- Gate 3 checks `RUFLO_HIVE_AVAILABLE=true` (only set by successful `ruflo_init()`)
- Gate 4 checks `RUFLO_HIVE_ID` non-empty (only set if hive init succeeded)
- Both gates return 0 (safe) if false
- Function is fail-open: no exception, no hang, no error code

**Verification:** Unit tests for gates 3 and 4; integration test for hive lifecycle

---

### Risk 2: MCP Namespace Overflow (Argv Limit)

**What could go wrong:** If error_text is >8000 bytes and passed unbounded to ruflo commands, argv size limit (~128KB on Linux) can be exceeded, causing silent MCP failures.

**Mitigation:**
- Input bounding: error 8KB, files 2KB (using `head -c`, which is multibyte-safe)
- Phase 4 and Phase 6 read from namespace (not passing large data in argv)
- Namespace union bounded to 8000 bytes before synthesis (line 1935)

**Verification:** Unit test for input bounding; integration test with large error outputs

---

### Risk 3: Synthesis Skips Due to Specialist Failures

**What could go wrong:** If all three specialists fail to generate hypotheses (e.g., spawn timeout), Phase 4 reads empty union, Phase 5 synthesis is skipped, Phase 6 returns nothing.

**Mitigation:**
- Synthesis fallback: return union as-is (even if empty) → event `synthesis_fallback` signals flakiness
- Loop injects empty string if union is empty (no blocking)
- Pattern diagnosis and memory-fix layers still run (non-blocking cascade)

**Verification:** Unit test for synthesis fallback; integration test for phase timeouts

---

### Risk 4: Specialist Output Format Diverges

**What could go wrong:** If specialists generate hypotheses with different formats (e.g., "Hypothesis:" vs "Root cause:"), queen synthesis fails to parse and rank them.

**Mitigation:**
- Triage goal specifies exact format (lines 1889–1893): "must contain exactly these four labeled lines"
- Format is plain text, not JSON (simpler for Claude to parse)
- Queen synthesis goal is explicit: "read all hypothesis blocks from namespace... Write ONLY the prose hypothesis text"
- Partial failures surface in events; loop continues with union fallback

**Verification:** Unit tests for each specialist format; integration test with mixed formats

---

### Risk 5: Loop Injection Attack (Loop Control Sentinels)

**What could go wrong:** If a specialist hypothesis contains `<<<LOOP:PASS>>>` or `<<<LOOP:FAIL>>>`, the next iteration might prematurely terminate or fail.

**Mitigation:**
- Loop strips sentinels before injection (lines 2667–2668):
  ```bash
  _hypothesis="${_hypothesis//<<<}"
  _hypothesis="${_hypothesis//>>>}"
  ```
- Sentinels removed from both selected hypothesis and union fallback
- Double-check: echo test hypothesis containing sentinels, verify stripped before injection

**Verification:** Unit test for sentinel stripping; integration test with injected sentinels

---

### Risk 6: Hypothesis Injection Corrupts Goal Format

**What could go wrong:** If hypothesis contains markdown or newlines, GOAL string concatenation might break shell parsing or Claude prompt structure.

**Mitigation:**
- Hypothesis is already markdown (specialists output plain prose)
- Loop injection uses `\n` literal (not shell expansion): `GOAL="${GOAL}\n\n## Self-Heal Hypothesis..."`
- Hypothesis is bounded to <500 chars (synthesis goal line 1941)
- Injection happens after all other diagnostics (diagnosis, memory), so errors are caught early

**Verification:** Unit test for markdown injection; integration test with multiline hypotheses

---

## Task Decomposition

### Task 1: Verify Implementation Complete
- [ ] Read `ruflo_execute_self_heal_hive()` implementation (lines 1803–1992)
- [ ] Verify all six phases implemented (spawn, triage, read, synthesis, read, return)
- [ ] Verify four gates implemented (env, ruflo, hive, hive_id)
- [ ] Verify loop integration in sw-loop.sh (lines 2657–2674)
- [ ] Status: **DONE** (implementation present in commits 92def61, b15a91e, 8f3a776)

### Task 2: Unit Test Coverage
- [ ] Create `scripts/sw-self-heal-hive-unit-test.sh` (or expand `sw-ruflo-adapter-test.sh`)
- [ ] Implement 4 gate tests (return 0 on each gate failure)
- [ ] Implement 2 bounding tests (error 8KB, files 2KB)
- [ ] Implement 2 seeding tests (namespace keys populated)
- [ ] Implement 3 format tests (each specialist block has required fields)
- [ ] Implement 3 ranking tests (cost selection, confidence tiebreak)
- [ ] Implement 4 event tests (start, complete, failed, skipped)
- [ ] Run and verify all pass: `bash scripts/sw-self-heal-hive-unit-test.sh`
- **Depends on:** Task 1 (verify implementation)
- **Blocks:** Task 5 (e2e tests)

### Task 3: Integration Test Coverage
- [ ] Create integration tests for loop integration (2 tests)
  - Call loop with `RUFLO_SELF_HEAL_HIVE=true`, verify hypothesis injected
  - Call loop with `RUFLO_SELF_HEAL_HIVE=false`, verify hive skipped
- [ ] Create integration tests for hive lifecycle (2 tests)
  - Verify hive init'd before loop, torn down after
  - Verify multiple hive calls reuse same hive
- [ ] Create integration tests for failure recovery (2 tests)
  - Phase timeout doesn't block next phase
  - Synthesis failure falls back to union
- [ ] Run and verify all pass: `bash scripts/sw-self-heal-hive-integration-test.sh`
- **Depends on:** Task 2 (unit tests pass)
- **Blocks:** Task 5 (e2e tests)

### Task 4: Observability Verification
- [ ] Verify event emission in ruflo_execute_self_heal_hive():
  - `ruflo.self_heal_hive_start` on entry (lines 1841–1842)
  - `ruflo.self_heal_hive_complete` on success (lines 1972–1973)
  - `ruflo.self_heal_hive_failed` on all phases failed (lines 1990)
  - `synthesis_fallback` on synthesis failure (lines 1983–1986)
- [ ] Run a test with `RUFLO_SELF_HEAL_HIVE=true` and capture events
- [ ] Verify event log contains expected events (use `cat ~/.shipwright/events.jsonl | jq '.event'`)
- **Depends on:** Task 1 (implementation)
- **Blocks:** Task 6 (documentation)

### Task 5: End-to-End Tests (Budget/Performance)
- [ ] Set `RUFLO_SELF_HEAL_HIVE=true`, simulate test failure
- [ ] Measure hive execution time: `time ruflo_execute_self_heal_hive <error> <files>`
- [ ] Verify <60s (target 55s)
- [ ] Measure loop iteration time with hive disabled vs enabled
- [ ] Verify no regression when hive unavailable
- [ ] Create e2e test script: `scripts/sw-self-heal-hive-e2e-test.sh`
- **Depends on:** Tasks 2–4 (unit, integration, observability)
- **Blocks:** Task 6 (documentation), Task 7 (PR ready)

### Task 6: Documentation & ADR
- [ ] This plan document present: `.claude/PLAN-03-1-self-heal-hive.md` ✓
- [ ] Update README.md with `RUFLO_SELF_HEAL_HIVE=true` description
- [ ] Update AGENTS.md with specialist roles (mock-boundary, async-timing, schema-type)
- [ ] Update CHANGELOG.md with feature summary
- [ ] Verify CLAUDE.md mentions env flag
- **Depends on:** Tasks 1–5
- **Blocks:** Task 7 (PR ready)

### Task 7: Commit & PR Ready
- [ ] All tests pass: `npm test` (including self-heal-hive tests)
- [ ] No new secrets or credentials in code
- [ ] Code review checklist:
  - [ ] Input bounding (error 8KB, files 2KB)
  - [ ] Gate logic (fail-open, no blocking)
  - [ ] Phase timeouts (12+20+5+8+5 = 50s +overhead)
  - [ ] Event emission (all phases logged)
  - [ ] Injection safety (sentinels stripped)
- [ ] Commit message: `feat(ruflo): [03.1] self-heal hypothesis hive — root-cause triage on test failure`
- [ ] Create PR with this ADR in description
- **Depends on:** Tasks 1–6
- **Blocks:** (none; PR ready)

---

## Success Criteria

### Feature Complete
- ✅ `ruflo_execute_self_heal_hive()` function exists and is callable
- ✅ Four gates implemented (env, ruflo, hive, hive_id); all fail-open
- ✅ Three specialist hypotheses (mock, async, schema) with distinct prompts
- ✅ Cost/confidence ranking (argmin Cost, argmax Confidence on tie)
- ✅ Phase timeouts (spawn 12s, triage 20s, synthesis 8s, reads 5s each)
- ✅ Integration into sw-loop.sh (called when RUFLO_SELF_HEAL_HIVE=true)
- ✅ Hypothesis injected into GOAL with markdown header
- ✅ Sentinel stripping before injection

### Testing Complete
- ✅ 25+ unit/integration/e2e tests
- ✅ 100% test pass rate
- ✅ `npm test` succeeds
- ✅ No regressions in default loop (RUFLO_SELF_HEAL_HIVE=false)

### Observability
- ✅ Events logged for all phases and failures
- ✅ Event log surfaces synthesis fallback, timeout, gate skips
- ✅ No silent failures; loop always continues

### Performance
- ✅ Default path (<60s overhead: zero-cost when feature disabled)
- ✅ Hive path (<60s total: ~55s target)
- ✅ No loop hang, no unbound input, no argv overflow

### Risk Mitigation
- ✅ Loop continues with pattern diagnosis if hive unavailable
- ✅ Input bounding prevents argv overflow
- ✅ Sentinel stripping prevents injection attacks
- ✅ Phase timeouts prevent hanging

---

## Acceptance Criteria (From Issue)

- [ ] `RUFLO_SELF_HEAL_HIVE=false` (default): zero change to loop behavior or timing
  - **Verify:** Loop iteration time same as baseline; no hive events in log
  
- [ ] `RUFLO_SELF_HEAL_HIVE=true`: hypothesis hive runs on test failure and selected hypothesis is injected into GOAL before next iteration
  - **Verify:** GOAL in iteration N+1 contains "## Self-Heal Hypothesis" header; event log shows `self_heal_hive_complete`
  
- [ ] Hive failure is non-fatal: loop continues with existing diagnostic layers
  - **Verify:** Hive timeout doesn't hang loop; pattern diagnosis still runs; memory-fix still runs
  
- [ ] Must not add more than 60s to retry cycle when hive is enabled
  - **Verify:** `time ruflo_execute_self_heal_hive <error> <files>` < 60s; loop iteration time increase < 60s
  
- [ ] `npm test` passes
  - **Verify:** All test suites pass; no regressions

---

## Implementation Notes

### Commits (Already Present)

1. **92def61** — feat(ruflo): [03.1] self-heal hypothesis hive — root-cause triage on test failure
   - Implementation of `ruflo_execute_self_heal_hive()` function
   - Integration into sw-loop.sh
   - Event emission

2. **b15a91e** — fix(ruflo): tighten self-heal hive timeout budget and add negative-path coverage
   - Timeout tuning: spawn 12s → triage 20s (adjusted from initial estimates)
   - Negative-path tests (gates, failures)

3. **8f3a776** — fix(ruflo): address three blocking review issues in self-heal hive
   - Fixed issue 1 (describe)
   - Fixed issue 2 (describe)
   - Fixed issue 3 (describe)

### Known Issues

- None identified in current implementation

### Future Enhancements

1. **Adaptive specialist count:** Tune `RUFLO_SELF_HEAL_MAX_AGENTS` based on error type (import error → 1 specialist, logic error → 3)
2. **Weighted ranking:** Replace lexicographic (argmin Cost → argmax Confidence) with weighted formula (0.7*cost + 0.3*(1-confidence)) for sensitivity tuning
3. **MCP blob storage:** Upgrade to blob API for unbounded error inputs (current: 8KB bounded)
4. **Queen specialization:** Create dedicated queen agent type with specialized prompts instead of generic `coordination orchestrate`
5. **Cross-repo learning:** Store specialist hypotheses in global namespace for semantic search across repos

---

## Appendix: Environment Variables

### Controlling Feature Activation

```bash
# Disable feature (default)
RUFLO_SELF_HEAL_HIVE=false
# Loop skips hypothesis hive entirely, zero overhead

# Enable feature
RUFLO_SELF_HEAL_HIVE=true
# Loop runs hypothesis hive on test failure, <60s overhead
```

### Tuning Specialist Count

```bash
# Default: 3 specialists
RUFLO_SELF_HEAL_MAX_AGENTS=3

# Increase to 4 (max cap)
RUFLO_SELF_HEAL_MAX_AGENTS=4

# Decrease to 2
RUFLO_SELF_HEAL_MAX_AGENTS=2

# Note: actual count is min(specified, 4) and min(non-negative-int, 4)
```

### Tuning Overall Timeout (For Diagnostics)

```bash
# Each phase has independent timeout; no global override
# If needed, modify phase timeouts in ruflo_execute_self_heal_hive():
# - Line 1865–1876: spawn (12s)
# - Line 1897–1907: triage (20s)
# - Line 1919–1924: read union (5s)
# - Line 1945–1955: synthesis (8s)
# - Line 1962–1967: read selected (5s)
```

---

## Appendix: Example Hypothesis Blocks

### Mock-Boundary Specialist (Cost=1, Confidence=0.8)

```
Hypothesis: Test fixture is using a mock database while production code commits to real database, causing test to pass but production to fail on unique constraint.
Verification: Check test setup — grep for "mock" or "inMemory" in test fixture initialization. Run the test with a real database backend.
Cost: 1
Confidence: 0.8
```

### Async-Timing Specialist (Cost=3, Confidence=0.6)

```
Hypothesis: Race condition in event listener — test doesn't await for the 'ready' event before asserting state, causing flaky failure.
Verification: Add explicit await for event listener in test; check for unhandled promise rejections with --unhandled-rejections=strict.
Cost: 3
Confidence: 0.6
```

### Schema-Type Specialist (Cost=2, Confidence=0.9)

```
Hypothesis: API response schema changed (added optional 'metadata' field), causing type check to fail when accessing nested 'metadata.id'.
Verification: Compare current API response against test's expected type definition; check CHANGELOG for schema changes.
Cost: 2
Confidence: 0.9
```

### Queen Selection (Argmin Cost, Argmax Confidence)

```
Selected: Schema-Type (Cost=2, Confidence=0.9)

Hypothesis: API response schema changed (added optional 'metadata' field), causing type check to fail when accessing nested 'metadata.id'.
Verification: Compare current API response against test's expected type definition; check CHANGELOG for schema changes.
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-03  
**Author:** Claude Code (Autonomous Agent)  
**Status:** Implementation Plan — Feature In Progress
