# Skill: Rate Limit Handling

GitHub API rate limiting requires both reactive (detect and backoff) and proactive (monitor quota) strategies to prevent daemon/fleet crashes.

## GitHub API Rate Limit Structure

1. **Primary Rate Limit**: 5,000 requests/hour per authenticated user/app. Response headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`.
2. **Secondary Rate Limit**: Burst protection; no fixed rate, triggered by rapid sustained requests. Returns 403 with `Retry-After` header (in seconds).
3. **Error Detection**: Both return HTTP 403, but secondary limits omit `X-RateLimit-*` headers and include `Retry-After`.

## Error Detection Pattern

```js
function isRateLimitError(response) {
  if (response.status !== 403) return false;
  // Secondary rate limit: has Retry-After, missing X-RateLimit headers
  const hasRetryAfter = response.headers['retry-after'];
  const hasPrimaryHeaders = response.headers['x-ratelimit-remaining'] !== undefined;
  return hasRetryAfter || !hasPrimaryHeaders;
}

function extractQuota(response) {
  return {
    remaining: parseInt(response.headers['x-ratelimit-remaining'] || 0),
    limit: parseInt(response.headers['x-ratelimit-limit'] || 5000),
    resetAt: new Date(parseInt(response.headers['x-ratelimit-reset'] || 0) * 1000),
    retryAfter: parseInt(response.headers['retry-after'] || 0)
  };
}
```

## Exponential Backoff with Jitter

- **Base delay**: 1 second
- **Multiplier**: 2x per retry (1s, 2s, 4s, 8s, 16s, 32s)
- **Jitter**: Add random [0, base_delay) to each attempt to avoid thundering herd
- **Max retries**: 6 (total max wait ~63s before giving up)
- **For secondary limits**: Use `Retry-After` header if present; otherwise apply exponential backoff

```js
function computeBackoffDelay(attempt, secondaryLimitRetryAfter = null) {
  if (secondaryLimitRetryAfter) {
    return secondaryLimitRetryAfter * 1000 + Math.random() * 1000;
  }
  const baseDelay = Math.pow(2, attempt) * 1000; // ms
  const jitter = Math.random() * baseDelay;
  return baseDelay + jitter;
}
```

## Proactive Quota Monitoring

- **Track remaining quota** after each successful request (update from response headers)
- **Slow down when approaching limit**: When remaining < 20% of limit, add a fixed 500ms delay between requests (prevents burst that would trigger secondary limit)
- **Emit warning event**: When remaining drops below 20%, emit a single warning event (not every request) with current quota and estimated reset time

```js
function shouldSlowDown(quota) {
  const threshold = quota.limit * 0.20;
  return quota.remaining < threshold;
}
```

## Integration Pattern

- Wrap GitHub API client in a rate-limit-aware decorator that:
  1. Executes the request
  2. Detects rate limit error
  3. Extracts quota and retry strategy
  4. Sleeps with exponential backoff
  5. Retries up to 6 times
  6. Emits warning if quota dropped below threshold
  7. Throws error if all retries exhausted

- Store quota state globally or per-client instance (not per-request) to track `remaining` across calls

## CLI Flag Pattern

- `--respect-rate-limits` (boolean, default: true)
- When true: apply backoff, quota monitoring, and warnings
- When false: skip backoff but still extract and log quota headers (for diagnostics)
- Document that disabling is unsafe for production daemon/fleet operations

## Testing Strategy

- **Unit tests**: Rate limit error detection, backoff delay calculation, quota tracking
- **Integration tests**: Wrap mock GitHub API client to simulate rate limit responses at specific request counts
- **Load tests**: Verify backoff prevents cascading failures under sustained quota pressure
- **Threshold tests**: Validate 20% threshold triggers warning at expected quota level
