## Checkpoint & Recovery Patterns

### State Representation
- Capture iteration count, code changes (git ref or diff), test results, and error summary atomically
- Use JSON for checkpoint format (readable, parseable, versionable)
- Include schema version and timestamp for future migration
- Validate checkpoint integrity on load (checksum or signature optional for high-reliability scenarios)

### Checkpoint Timing
- Save checkpoint **after** each iteration completes (code + test results)
- Save **before** exiting the loop, even on error
- Never checkpoint mid-iteration (partial state)
- One checkpoint per iteration; rotate on next iteration (only keep last N)

### Resume Injection
- Verify checkpoint age and applicability before resume (e.g., reject if repo state has diverged)
- Inject previous iteration context into next prompt exactly as acceptance criteria states
- Validate context matches current repo state (branch, uncommitted changes)
- If context is stale or mismatched, offer manual resume with human validation

### Cleanup Strategy
- Delete checkpoint only after loop succeeds and exits normally
- Keep checkpoint on error (for manual recovery)
- Implement rotation: keep last 3 checkpoints for safety
- Clean up on explicit `--clean` or `--reset` flag

### Failure Modes to Handle
- **Corrupted checkpoint**: detect on load, offer recovery (resume from before corruption, or reset)
- **Stale context**: if repo changed since checkpoint, warn and require explicit resume approval
- **Partial save**: write to temp file first, atomic rename for atomicity
- **Lost checkpoint**: graceful degradation (restart from iteration 1, or manual override)

### Testing Checklist
- Save checkpoint, verify file exists and is valid JSON
- Load checkpoint, verify all fields present and types correct
- Resume with injected context, verify next iteration sees context
- Simulate interrupted checkpoint (truncated JSON), verify safe rejection
- Cleanup after success, verify checkpoint deleted
- Cleanup on error, verify checkpoint preserved
