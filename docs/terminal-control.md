# Terminal control

Protocol v9 adds independent inspection, observation and checked input. Existing
v7/v8 clients retain their wire layout and can keep using the interactive lanes.

```
muxd inspect local:<name>
muxd observe local:<name>
muxd input local:<name> < request.json
```

Each command uses the usual local socket and optional host relay. Set
`MUXD_NO_AUTOSTART=1` for supervised consumers that must not start their own daemon.

Inspect returns a JSON viewport snapshot without attaching or resizing. Observe
streams newline-delimited snapshots, initially and after changes, coalesced to
at most one per 100ms. It is a current-state stream, not a lossless output log.
It cannot slow the PTY reader; a stalled consumer is disconnected. stdout and
stderr share the terminal, and old input is not reconstructed from output.

Input reads a JSON object from stdin:

```json
{
  "generation": "copy from inspection",
  "revision": 12,
  "input_revision": 3,
  "foreground_pgid": 1234,
  "data": [104, 105, 13]
}
```

All identity and revision fields must come from a fresh snapshot. Data is 1–8192
bytes. Interactive and control writes share a lock; an intervening input, output
change, foreground group change, exit or recreated terminal rejects the request.
An input revision is consumed before writing, including partial failures. The
reply confirms bytes written to the PTY, not application acceptance. Never retry
an uncertain write. The foreground application can change after validation, and
the shared application composer is not a transactional API.

Generations are renewed at daemon handoff. Observers reconnect and re-inspect;
old commands must not be automatically replayed after an upgrade. Existing
interactive clients still reconnect through the usual attachment protocol.
