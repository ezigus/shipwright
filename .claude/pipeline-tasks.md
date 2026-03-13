# Pipeline Tasks — GitHub API rate limit protection with exponential backoff

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/github-rate-limit.sh` with backoff engine, circuit breaker, and quota monitor
- [ ] Task 2: Create `gh_rate_limit_exec()` unified wrapper function
- [ ] Task 3: Update `scripts/lib/daemon-state.sh` — remove circuit breaker, add thin wrappers
- [ ] Task 4: Update `scripts/lib/helpers.sh` — delegate `gh_with_retry()` to new module
- [ ] Task 5: Update `scripts/sw-daemon.sh` — remove `gh_retry()`, add `--respect-rate-limits` flag
- [ ] Task 6: Update `scripts/lib/daemon-poll.sh` — replace inline backoff with `gh_rate_limit_exec()`
- [ ] Task 7: Update `scripts/sw-fleet.sh` — add `--respect-rate-limits` flag passthrough
- [ ] Task 8: Update `config/event-schema.json` — add quota warning and backoff event types
- [ ] Task 9: Create `scripts/sw-rate-limit-test.sh` — comprehensive shell tests
- [ ] Task 10: Run full test suite (`npm test`) and fix any regressions
- [ ] `scripts/lib/github-rate-limit.sh` exists with all specified functions
- [ ] Rate limit errors (403, 429) trigger exponential backoff with jitter
- [ ] Backoff uses jitter (verified by test showing variance across runs)
- [ ] `gh_check_quota()` detects when remaining < 20% of limit
- [ ] Warning event emitted when quota drops below 20%
- [ ] `--respect-rate-limits` flag works on daemon and fleet commands
- [ ] All existing `gh_with_retry`/`gh_retry` callers use the new module
- [ ] `scripts/sw-rate-limit-test.sh` passes with all assertions green
- [ ] `npm test` passes with no regressions
- [ ] No Bash 3.2 incompatibilities (no `declare -A`, no `${var,,}`)

## Context
- Pipeline: standard
- Branch: feat/github-api-rate-limit-protection-with-ex-157
- Issue: #157
- Generated: 2026-03-13T20:55:46Z
