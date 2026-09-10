# Terminal control

Protocol v9 adds three operations to Mux's existing socket/QUIC protocol, using
its existing framing and authentication. The CLI exposes JSON:

```
muxd inspect local:<name>
muxd observe local:<name>
muxd input local:<name> < request.json
```

Use a configured host alias instead of `local` for remote terminals. These
operations never create, attach to, or resize terminals. Supervised consumers
can set `MUXD_NO_AUTOSTART=1` to prevent starting a daemon.

Inspect returns the viewport text, size, cursor, process, directory, last detected
agent, exit flag, and state markers. Observe streams these snapshots as NDJSON:
initially, then coalesced to at most one per 100ms after output, resize, input
(including without echo), detected metadata changes, or exit. It is current state,
not a lossless log: states may be skipped or repeated. Agent detection is
asynchronous; quiet foreground/directory changes appear on the next snapshot.
A stalled snapshot write disconnects after two seconds without backpressuring
the PTY reader. An `exited: true` snapshot ends the stream; disconnect alone does
not mean exit. stdout/stderr are combined, and old input cannot be reconstructed.

Input reads this JSON object from stdin:

```json
{
  "generation": "copy from inspection",
  "revision": 12,
  "input_revision": 3,
  "foreground_pgid": 1234,
  "data": [104, 105, 13]
}
```

Copy all state fields from a fresh snapshot. A null foreground group means input
is not ready. `data` is 1–8192 raw bytes; the example types `hi` and Return.

- `generation` identifies the terminal incarnation and changes at daemon handoff.
- `revision` advances on processed output, viewport resize/restore, and reaping.
- `input_revision` advances before every serialized write, even if it later fails.

Interactive and checked writes share one lock. Under it, Mux rejects mismatched
state or an exited terminal before writing; rejection consumes no input revision.
The input deadline is two seconds, including lock wait. This is a stale-state
check, not an application transaction: output and foreground processes can change
after validation, unread kernel output is not checked, and an existing draft may
already occupy the application's composer.

Success confirms PTY bytes written, not application acceptance. Write failure,
timeout, or a lost reply can mean partial delivery: inspect and reconcile before
any further input; never automatically retry an uncertain write. Control errors
retain the generic `OpenError` kind; prose is not a machine-readable retry policy.
Input revisions prevent replay of the same request, not durable deduplication.

v7/v8 clients retain their existing wire layouts and interactive lanes. Attach-only
reopen requires v8; control requires v9. Older versions cannot request newer
operations. After a daemon handoff, observers reconnect and re-inspect; old input
must not be replayed. Interactive clients use their usual reconnect protocol.
