# Tasks — feat(ruflo): [03.1] self-heal hypothesis hive — root-cause triage on test failure

## Status: PLAN COMPLETE → Ready for Build
Pipeline: autonomous | Branch: feat/feat-ruflo-03-1-self-heal-hypothesis-hiv-422

## IMPLEMENTATION COMPLETE ✅
- [x] 1.1: Define `ruflo_execute_self_heal_hive()` function (lines 1811-2004 in ruflo-adapter.sh)
- [x] 1.2: Four environmental gates (env flag, ruflo avail, hive avail, hive_id)
- [x] 1.3: Input bounding (8000/2000 bytes with head -c)
- [x] 1.4: Namespace seeding (error context + changed files + history)
- [x] 1.5: Spawn phase (12s timeout, 3 specialists, non-fatal)
- [x] 1.6: Triage orchestrate (20s, unified goal for 3 specialists)
- [x] 1.7: Read phase (5s, list namespace, union hypotheses)
- [x] 1.8: Synthesis phase (8s, queen selects argmin cost)
- [x] 1.9: Fallback path (emit union if synthesis fails)
- [x] 1.10: Output formatting (sanitize sentinels, emit events)
- [x] 2.1: Call in sw-loop.sh line ~2703 (after diagnose_failure, before memory)
- [x] 2.2: Conditional gate (RUFLO_SELF_HEAL_HIVE=true check)
- [x] 2.3: Inject hypothesis into GOAL with clear section header
- [x] 2.4: Sanitize loop-control sentinels (<<<, >>>)
- [x] 3.1: Static analyzer comments on `_ruflo_seed_specialist_history`
- [x] 3.2: Input bounding verification (head -c is multibyte-safe)
- [x] 3.3: Refactor statusline helpers (remove execSync entirely)

## TESTING REMAINING ⏳
- [x] 4.1: Unit tests (env gate, ruflo unavailable, input bounds, sentinels, error paths) — 19 sections in sw-ruflo-adapter-test.sh
- [x] 4.2: Integration tests (mock ruflo full flow, GOAL injection format with header)
- [x] 4.3: Performance tests (disabled-gate < 5s for 100 calls; enabled budget covered by triage/synth timeouts)
- [ ] 4.4: npm test suite validation (full suite has ~120 scripts; ruflo-adapter 255/255 ✅)

## Plan Details
- **Plan Document**: `.claude/implementation-plan.md` (details AC-1 through AC-6)
- **Commits**: b3c34fd (feature), 1fdd8a0 (loop integration), 136433d (security fixes)
- **Next Stage**: Build → Complete unit/integration/performance tests → Test suite validation
