## Flaky Test Resilience

Implement statistical detection and resilient retry for unreliable tests without amplifying failure detection time or masking real bugs.

### Scoring Algorithm

**Flakiness Score**: fail_rate over last N runs (default: last 50)
- Count: pass, fail, skip across N runs
- fail_rate = fails / (passes + fails)  [skip excluded]
- Flaky threshold: 10% ≤ fail_rate ≤ 90%
  - Below 10%: stable (ignore)
  - 10-90%: flaky (retry)
  - Above 90%: broken (fail immediately, no retry)

Implementation checklist:
- [ ] Window management: prune old runs, keep last N only
- [ ] Tie-breaking: when fail_rate exactly 10% or 90%, include in flaky set
- [ ] Edge case: N < 3 runs → mark untested, don't retry yet
- [ ] Consistency: scoring must be deterministic (no randomness)

### Retry Logic

**Rules**:
1. When a flaky test fails, retry up to 3 times total (original + 2 retries)
2. Stop immediately on first pass (don't retry further)
3. If all 3 attempts fail, report failure (test is unreliable, not fixed)
4. Log attempt count and final result in trace

**Safeguards**:
- Never retry non-flaky tests (waste of time)
- Never retry broken tests (above 90% fail rate)
- Cap total retry time per test (e.g., 30s max)
- If retry logic itself crashes, fail the test (don't hide infrastructure bugs)

### Data Model

Store minimal state per test:
```
test_id, run_timestamp, result (pass|fail|skip), duration_ms, run_id
```

Queries:
- Last N runs for a test (indexed by test_id, descending timestamp)
- Flakiness score for all tests (batch calculation)
- Retry history (which attempts succeeded/failed)

### Common Pitfalls

- **False positive**: Marking stable test flaky because of one transient failure. Threshold 10% requires ~5 fails in 50 runs; confirm threshold is defensible.
- **Retry storm**: If retry handler is async, retries can pile up. Keep retries in-process, serial, with per-test cap.
- **Data consistency**: If two pipelines update flakiness score concurrently, use atomic increments or version the data.
- **Threshold gaming**: Tests that fail exactly 50% of the time are maximally flaky; the 10-90% range is intentional—don't widen it.
- **Skip inflation**: Skipped tests shouldn't count toward fail_rate (they're not reliable, but different failure mode). Exclude skips from denominator.

### Monitoring

- Dashboard: top 10 most flaky tests, trend over time (improving or worsening?)
- Alerting: if median flakiness increases week-over-week, investigate environment
- Audit log: every retry, with original failure + retry result, so you can spot patterns
