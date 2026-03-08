## Timeout & Resilience Patterns for Pipeline Infrastructure

Timeout enforcement prevents hanging stages from wasting hours. This skill guides implementing configurable timeouts, recovery logic, and diagnostic capture.

### Timeout Configuration Strategy

**Set timeout bounds around actual workload:**
- Default per-stage: 30 minutes (covers normal variance)
- Build stage: 90 minutes (accounts for slow CI/compilation)
- GitHub API calls: 5 minutes (external service bound)
- Set maximums that are 2-3x typical, not arbitrary values

**Avoid timeout tuning pitfalls:**
- Too short: False positives cause unnecessary retries
- Too long: Still waste time before failing
- Fixed global timeout: Different stages have different acceptable durations

### Graceful Termination Under Timeout

**Kill the stage, not the process tree:**
1. Send SIGTERM (graceful shutdown signal)
2. Wait 5-10 seconds for cleanup
3. Send SIGKILL if process doesn't exit
4. Capture final state/logs before cleanup

**Preserve diagnostic context before termination:**
- Flush event logs to persistent storage
- Snapshot last N lines of stage output
- Record elapsed time and resource usage (CPU, memory)
- Note which sub-tasks completed before timeout

### Backoff & Retry Strategy

**Use exponential backoff with jitter to avoid retry storms:**
```
retry_delay = min(max_delay, base_delay * (2 ^ attempt)) + random(0, jitter)
```
Typical: base=1s, max=60s, jitter=random(0, 5s), max_retries=3

**Classify failures to determine retry eligibility:**
- Infrastructure (GitHub API timeout, network error): Retryable
- Code failure (test assertion, build error): Not retryable
- Resource exhaustion (OOM, disk full): Not retryable (retry will fail identically)

**Prevent cascading failures:**
- If all stages timeout simultaneously, likely upstream infrastructure issue — don't retry
- Track retry count; stop after N attempts to prevent retry loops
- Monitor retry rate; alert if >30% of runs hit timeouts (tuning needed)

### Event Logging for Timeout Analysis

**Log timeout events with full context:**
```json
{
  "event": "stage_timeout",
  "stage": "build",
  "elapsed_seconds": 5401,
  "timeout_seconds": 5400,
  "cause": "process_hung",
  "last_output_line": "Waiting for lock on /var/lib/apt...",
  "retry_attempt": 1,
  "retry_scheduled": true
}
```

This enables post-mortem diagnosis: Was it a real hang or just slow? What was the last detectable state?

### Testing Timeout Behavior

**Test actual timeouts, not mocks:**
- Use mock processes that sleep longer than timeout
- Verify graceful termination (logs captured, state preserved)
- Test backoff: Verify delays increase exponentially
- Test non-retryable failures: Verify no retry attempted

**Stress test backoff logic:**
- Run scenario where all stages timeout simultaneously
- Verify retry rates don't cause system load spikes
- Confirm diagnostic context is logged for every timeout

**Integration tests:**
- Timeout one stage mid-pipeline; verify next stage runs normally
- Timeout a retried stage; verify it doesn't retry forever
- Timeout during retry; verify diagnostic context accumulates
