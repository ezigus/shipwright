# Pipeline Tasks — GitHub API rate limit protection with exponential backoff

## Implementation Checklist
- [ ] Task 1: Add `rate_limit` config to `config/defaults.json`
- [ ] Task 2: Create `scripts/lib/github-rate-limit.sh` with `gh_safe()`, `_gh_is_retryable()`, `_gh_parse_retry_after()`
- [ ] Task 3: Update `scripts/lib/pipeline-github.sh` to use `gh_safe`
- [ ] Task 4: Update `scripts/sw-github-checks.sh` to use `gh_safe`
- [ ] Task 5: Update `scripts/sw-github-deploy.sh` to use `gh_safe`
- [ ] Task 6: Update `scripts/sw-github-graphql.sh` to use `gh_safe`
- [ ] Task 7: Update `scripts/sw-tracker-github.sh` to use `gh_safe`
- [ ] Task 8: Refactor `scripts/sw-daemon.sh` `gh_retry()` to delegate to `gh_safe`
- [ ] Task 9: Deprecate `gh_with_retry()` in `scripts/lib/helpers.sh` to delegate to `gh_safe`
- [ ] Task 10: Add TypeScript `fetchWithRetry()` to `dashboard/server.ts`
- [ ] Task 11: Write `scripts/sw-lib-github-rate-limit-test.sh` test suite
- [ ] Task 12: Run full test suite and fix any regressions
- [ ] All `gh` / `gh api` calls in shell scripts route through `gh_safe()` for retry protection
- [ ] Rate limit errors (403/429) trigger exponential backoff with configurable parameters
- [ ] Server errors (502/503) are retried; client errors (400/401/404) fail fast
- [ ] Circuit breaker integration prevents call storms during sustained rate limiting
- [ ] All rate limit events are emitted to events.jsonl with structured metadata
- [ ] Dashboard TypeScript API calls have retry protection
- [ ] Backward compatibility: `gh_with_retry()` and `gh_retry()` still work (delegate to `gh_safe`)
- [ ] New test suite validates retry behavior, backoff math, and error classification

## Context
- Pipeline: autonomous
- Branch: ci/issue-157
- Issue: none
- Generated: 2026-03-13T21:19:44Z
