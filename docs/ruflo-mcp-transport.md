# Ruflo MCP — Unix Socket Transport

> Reference contract for the long-lived Node bridge that fronts ruflo memory
> calls. Consumed by issues #502 (lifecycle wiring), #503 (caller migration),
> and #504 (additional tools). Audience: Shipwright contributors. Tone: terse
> reference, not a tutorial. Assumes bash 3.2, Node ESM, unix sockets.

## 1. Overview

Each pipeline stage today calls `ruflo` through the shell binary, paying a
200–500ms cold-start tax per invocation. Across 12 stages this becomes
multiple seconds of synchronous latency that already shows up as
`⚠ Ruflo command failed (attempt N/5)` in `context-bundle.md`.

The unix-socket bridge replaces the per-call cold start with a single warm
Node process that dispatches newline-delimited JSON requests. Warm-path
latency is ~2ms per call.

**Scope of this issue (#500): transport only.**
- Build the bridge server, the bash wrapper, the test harness, this doc.
- **Do not** modify `scripts/lib/ruflo-adapter.sh`. Lifecycle wiring (start
  on `ruflo_init`, stop on `ruflo_cleanup`) is **#502**.
- **Do not** rewrite existing callers. Migration is **#503**.

**Why a unix socket and not HTTP / FIFO / gRPC?** See `design.md` —
short version: HTTP transport in upstream ruflo is currently a no-op; FIFOs
can't isolate concurrent callers; gRPC is wrong-scale for three tools. The
unix socket gives bidirectional framed messaging, per-connection isolation,
filesystem-permission ACL, sub-millisecond local latency, and a trivial
bash client via `nc -U`.

## 2. Socket path & environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `RUFLO_BRIDGE_SOCK` | `$HOME/.shipwright/ruflo-bridge.sock` | Unix socket path the bridge listens on |
| `RUFLO_BRIDGE_TIMEOUT` | `5` | Per-call `nc -w` timeout in seconds (transport-level) |
| `RUFLO_BRIDGE_SCRIPT` | `<sibling>/ruflo-bridge.mjs` | Path to the bridge server script |
| `RUFLO_BRIDGE_NODE` | `node` | Node binary used to spawn the bridge |
| `RUFLO_BRIDGE_START_TIMEOUT_DECIS` | `30` | Tenths-of-a-second to wait for bridge readiness after spawn (failsafe upper bound) |
| `RUFLO_BRIDGE_DISPATCH_TIMEOUT_MS` | `10000` | Subprocess fallback timeout for `execFileSync` inside the bridge |
| `RUFLO_BIN` | `ruflo` | Binary used for the subprocess fallback path inside the bridge |

The PID file lives at `${RUFLO_BRIDGE_SOCK}.pid`. It is written **after**
`listen()` resolves (so consumers never see a PID with no live socket) and
removed on `SIGTERM`/`SIGINT`.

## 3. Wire format

Newline-delimited JSON over the unix domain socket. One request per
connection, one response per connection. Each `nc -U` call opens a fresh
connection — concurrent calls cannot interleave responses.

**Request:**

```json
{"tool":"<name>","args":{...}}\n
```

**Response (success):**

```json
{"success":true,"result":<value>}\n
```

**Response (failure):**

```json
{"success":false,"error":"<message>","code":"<code>"}\n
```

Clients **MUST** check `success` before consuming `result`. The bridge never
crashes on a single bad request — every per-connection error is wrapped and
returned as `{"success":false,...}`.

## 4. Bash API

Source `scripts/lib/ruflo-mcp-call.sh` to access:

| Function | Exit code | Stdout | Description |
|----------|-----------|--------|-------------|
| `ruflo_mcp_call <tool> [k=v ...]` | 0 on `success:true`, 1 on any failure | response JSON line | Make a single bridge request |
| `ruflo_bridge_available` | 0 if socket responds to ping, 1 otherwise | (nothing) | Fast health check (`nc -w 1` bound) |
| `_ruflo_bridge_start` | 0 if bridge ready within `RUFLO_BRIDGE_START_TIMEOUT_DECIS`, 1 otherwise | (nothing) | Spawn bridge, wait for readiness |
| `_ruflo_bridge_stop` | 0 always (idempotent) | (nothing) | SIGTERM the bridge, backstop-unlink socket and PID file |

**Fail-open invariant.** A missing/unresponsive bridge does not propagate as
exit 1 from `ruflo_bridge_available` — it returns 1 too, but the caller is
expected to branch to legacy `ruflo` subprocess fallback. Only `success:false`
responses or wire-level failures (`jq` missing, `nc` missing, malformed JSON)
cause `ruflo_mcp_call` to exit 1.

**Re-source guard.** Sourcing the wrapper twice is a no-op; pre-exported
`RUFLO_BRIDGE_SOCK`/`RUFLO_BRIDGE_TIMEOUT`/etc are preserved.

## 5. Supported tools (v1.1)

| Tool | Args schema | Result schema | Notes |
|------|-------------|---------------|-------|
| `memory_store` | `{key: string, value: string, namespace?: string}` | `{stored: true, ...}` | Forwarded to ruflo `memory_store` |
| `memory_search` | `{query: string, namespace?: string, limit?: number}` | `{results: any[], ...}` | Forwarded to ruflo `memory_search` |
| `ping` | `{}` | `{pong: true, uptime_ms: number, version: string, pid: number}` | Implemented in the bridge — works as health check even if ruflo is broken |

The bridge first attempts in-process `import('ruflo')[<tool>](args)`. If the
upstream package does not expose ESM bindings, dispatch falls back to
`execFileSync(RUFLO_BIN, ['mcp','exec','--tool', name, '--args', JSON])`.
Either way the Node module cache stays warm; only the `ruflo` shell binary
cold-starts (~30ms vs 200–500ms total when called fresh from bash).

## 6. Error codes

| `error.code` | Cause | Layer |
|--------------|-------|-------|
| `invalid_request` | Malformed JSON request line, missing `tool`, non-object `args` | Bridge |
| `unknown_tool` | Tool not implemented in-process and `RUFLO_BIN` not on PATH | Bridge |
| `dispatch_timeout` | Subprocess fallback exceeded `RUFLO_BRIDGE_DISPATCH_TIMEOUT_MS` | Bridge |
| `ruflo_runtime` | ruflo memory I/O or import failure (verbatim message) | Bridge |
| (transport) | `nc` timeout, socket missing, `jq`/`nc` not installed | Wrapper (exit 1, stderr message) |

## 7. Latency profile

- **Warm path** (in-process or pre-warmed subprocess): ~2 ms per call.
- **Cold start**: 150–300 ms one-time (Node startup + module load + socket
  bind). Amortized across all calls in a pipeline run.
- **Subprocess fallback warm path**: ~50 ms per call (just the `ruflo` shell
  binary spawn — Node module cache is already loaded).
- **Bridge unavailable**: `ruflo_bridge_available` returns 1 within ~1 s
  (bounded by `nc -w 1`); caller falls back to legacy `ruflo` subprocess
  path defined by `scripts/lib/ruflo-adapter.sh` (#502 wires this in).

## 8. End-to-end example

Copy-pasteable. Requires `node`, `nc`, `jq` on PATH. Mock `ruflo` here just
echoes args; in real use the bridge calls actual ruflo.

```bash
# 1. Source the wrapper
source scripts/lib/ruflo-mcp-call.sh

# 2. Start the bridge (idempotent — no-op if already running)
_ruflo_bridge_start || { echo "bridge failed to start"; exit 1; }

# 3. Verify it's responding
ruflo_bridge_available && echo "bridge OK"

# 4. Make calls
ruflo_mcp_call memory_store key=last-build value=ok namespace=sw-pipeline
ruflo_mcp_call memory_search query="failure pattern" namespace=sw-pipeline limit=5
ruflo_mcp_call ping

# 5. Stop the bridge (idempotent — safe in cleanup traps)
_ruflo_bridge_stop
```

Expected response shape for `memory_store`:

```json
{"success":true,"result":{"stored":true}}
```

## 9. Lifecycle & versioning

**Lifecycle (deferred to #502):**
- `_ruflo_bridge_start` is invoked once from `ruflo_init` after ruflo is
  detected available. It is idempotent — duplicate starts return 0 fast.
- `_ruflo_bridge_stop` is invoked once from `ruflo_cleanup`, ideally inside
  the pipeline's EXIT trap so ungraceful exits still tear down the socket.
- The bridge handles `SIGTERM`, `SIGINT`, and `SIGHUP` by closing the server,
  unlinking the socket, removing the PID file, and exiting 0.
- A stale socket file from a crashed prior run is unlinked **before**
  `listen()` (crash recovery invariant).

**Versioning.** `VERSION = "3.6.1"` in both `ruflo-bridge.mjs` and
`ruflo-mcp-call.sh`, kept in sync with `package.json` (per
`shipwright version check`).

**Wire-format compatibility policy:**
- Add a new tool name → backwards-compatible. Allowed in patch/minor.
- Add a new optional field to args/result → backwards-compatible. Allowed in
  patch/minor.
- Rename or remove a tool / field → breaking. Requires major bump and a
  dual-support window of one minor release.
- The `ping` response carries a `version` field; clients may negotiate via
  that without breaking the contract.

Deprecations are announced here and emit a stderr warning from the bridge
for one minor cycle before removal.

## Out of scope

- HTTP transport (`-t http`) — upstream no-op, ruled out in #449.
- Authentication / authorization — local-only unix socket; permission bits
  on the socket file are sufficient until ruflo grows multi-tenant.
- Rate limiting — bridge is single-tenant per pipeline; concurrency is
  bounded by the calling pipeline's `max_parallel`.
- Migration of existing callers — that's #503.
