## Resilience Design: Failure Classification & Retry Strategies

When designing retry logic for orchestrated pipelines, avoid common pitfalls that create cascading failures and resource exhaustion.

### Failure Classification Taxonomy

Categorize errors by recovery likelihood, speed, and appropriate strategy:

1. **Transient (retry immediately with backoff)**
   - Exit code 1 + "timeout", "connection reset", "ECONNREFUSED", "temporarily unavailable" in stderr
   - Retry strategy: 3 attempts, exponential backoff (100ms × 2^n), jitter ±10%
   - Risk: If over-matched, causes retry storms

2. **Flaky Test (retry with delay, require 2/3 pass)**
   - Test output contains "timeout", "race condition", "flake"; same test passes when re-run independently
   - Retry strategy: 2 attempts, 5s delay between retries; only accept if 2 of 3 pass
   - Risk: Masks real bugs; require careful threshold tuning

3. **Code Bug (error analysis pass before retry)**
   - Deterministic failure (stack trace, assertion failure, exit code != 0)
   - Retry strategy: Run linting/type check, fix issues, retry once; escalate if still failing
   - Risk: Retry loop if code issue persists; requires operator awareness

4. **Environment Issue (pre-flight, then retry)**
   - "out of memory", "disk full", "not found", "dependency missing" in stderr
   - Retry strategy: Run pre-flight check (update deps, allocate resources), retry once
   - Risk: Repeated retries if pre-flight insufficient; needs escalation

5. **Context Exhaustion (skip retry, escalate)**
   - "context_length_exceeded", "token_limit", "max_retries" in error
   - Retry strategy: DO NOT RETRY; log with severity=critical, require manual intervention
   - Risk: Retrying wastes tokens without solving underlying issue

### Prevent Retry Storms & Cascading Failures

- **Backoff with jitter**: Use exponential backoff (base × 2^attempt) + random jitter to desynchronize retries
- **Hard limits**: Max 3 transient, 2 flaky, 1 code bug, 1 environment per job
- **Circuit breaker**: If 5+ consecutive failures of same type, escalate instead of retrying
- **Deduplication**: Log classification + outcome; don't re-retry identical failure
- **Daemon/pipeline coordination**: Use job ID + attempt counter to prevent both from retrying same failure

### Event Schema (events.jsonl)

```json
{
  "type": "pipeline.failure.classified",
  "timestamp": "2026-03-08T10:45:30Z",
  "job_id": "job-abc123",
  "stage": "test",
  "failure_type": "transient|flaky|code_bug|environment|context_exhaustion",
  "classification_confidence": 0.92,
  "error_signal": "connection timeout",
  "retry_strategy": "immediate_backoff",
  "attempt": 1,
  "max_attempts": 3,
  "outcome": "success|still_failing|escalated|skipped"
}
```

### Testing & Validation

- Classification accuracy on 15+ real failure logs from production events.jsonl
- No infinite retry loops under any failure type or load condition
- Retry storms prevented when failure type matches 5+ consecutive times
- Context exhaustion correctly identified and skipped (not retried)
- Daemon and pipeline coordination verified (no double-retry on same job)
- Event schema correctly logs classification + outcome for audit
- Documentation includes failure taxonomy and retry limits for operators
