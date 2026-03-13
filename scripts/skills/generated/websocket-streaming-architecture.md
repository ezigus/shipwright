## WebSocket Streaming Architecture

Real-time systems require careful handling of connection state, event ordering, and graceful degradation. WebSocket-driven features touching critical infrastructure (like build loop) need specific reliability patterns.

### Connection Lifecycle

**Initialization**: Establish WebSocket before emitting first iteration event. If connection fails, queue events in memory (bounded buffer, e.g., last 100 events) and replay on reconnect.

**Graceful Reconnection**: On disconnect, attempt exponential backoff reconnection (100ms, 200ms, 400ms... up to 30s) without resetting build loop state. Dashboard should show "reconnecting" status, not "failed".

**Cleanup**: Close WebSocket when build loop completes. Ensure all buffered events are flushed before closing.

### Event Reliability

**Ordering Guarantee**: Events must arrive in emission order. Use monotonic sequence numbers (iteration_id:event_index) for each batch. Dashboard drops duplicates but rejects out-of-order events as errors.

**No Loss During Disconnect**: Buffer unacked events server-side (memory-bounded, e.g., last N iterations). On client reconnect, server resends buffered events from last acked sequence number.

**Backwards Compatibility**: Old dashboard clients connect but may not understand new event types. Server MUST NOT break old clients with new fields; new fields are optional/ignored by old clients. Version the event schema.

### Performance

**Throttling/Batching**: Do NOT emit on every test execution. Batch 5-10 test results into one event or emit every 500ms, whichever is first. Measure event emission overhead; target <1ms per iteration.

**Backpressure**: If dashboard is slow (e.g., network lag), do not block build loop waiting for ACK. Queue events and let dashboard catch up asynchronously.

### Testing

**Mock WebSocket**: Unit tests mock WebSocket with controllable connection state (connected, disconnect, timeout). Verify event queuing and replay.

**Integration**: Test real WebSocket server with dashboard client. Inject network latency and disconnect scenarios; verify no event loss.

**Chaos**: Kill WebSocket mid-iteration, restart dashboard client, simulate packet loss. Build loop must continue; events must not corrupt.

### Event Schema Versioning

```json
{
  "version": 1,
  "iteration_id": 5,
  "event_type": "test_execution",
  "sequence": 0,
  "timestamp": "2026-03-13T20:50:00Z",
  "payload": {...}
}
```

Increment `version` if breaking changes occur. Client should validate and log warnings on unknown versions.

### Monitoring

Emit internal metrics: event queue depth, reconnection count, message roundtrip latency, client disconnect rate. Alert if queue is backing up (events emitted faster than delivered) or reconnection rate spikes.
