# Local clients for remote work

Run a device-using interface on the Mac and its execution engine on the remote
host. Mux forwards the engine's Unix socket over the same QUIC connection used
by terminal panes. The application owns its protocol, audio and credentials.
Mux needs no audio codec, virtual device, second network listener or agent API.

`muxd forward <host> <remote-socket> <local-socket>` runs in the foreground.
Both paths must be absolute. The remote destination must be a Unix socket owned
by the daemon's user. The local parent must already be a private directory owned
by the current user (mode 0700). Existing paths are never removed to make room.

One accepted client becomes one bidirectional stream on the broker's cached
host connection. The regular Mux handshake checks protocol version and bearer
authentication. After a successful `Connected` reply, bytes are opaque, including
HTTP/WebSocket upgrades. Half-closing one direction lets the other finish.
Disconnects are not replayed: the client owns reconnection and request recovery.

Stopping the forwarder with Ctrl-C or SIGTERM closes its clients and removes
only its own local socket. It does not stop the remote service or terminal jobs.
A force-killed forwarder can leave its socket behind; use a new path or remove
that known stale socket after confirming no process owns it. Protocol v11 is
required on both daemons; it continues to accept existing v7-v10 terminal clients.

## Codex voice example

Codex's remote TUI is experimental. Use compatible CLI/server versions. Keep
the app-server running in an open remote pane or manage it as a service; a Mux
pane explicitly closed with Cmd-W expires and kills its processes after 60 seconds.

On Spark, using the account/provider intended for that conversation:

```sh
codex app-server --listen "unix://$HOME/.codex/mux.sock"
```

In a **local Mac pane**, create a private forwarding directory and start the
forwarder. Use the actual remote user's path, not the Mac's `$HOME`:

```sh
mkdir -p -m 700 "$HOME/.local/state/mux/forwards"
muxd forward spark /home/rathi/.codex/mux.sock \
  "$HOME/.local/state/mux/forwards/spark-codex.sock"
```

In another local Mac pane:

```sh
codex --remote "unix://$HOME/.local/state/mux/forwards/spark-codex.sock"
```

Start a disposable conversation, then `/voice`. The TUI's voice helper uses the
Mac microphone and speakers; execution remains with Spark's app-server. Voice
media uses the application's connection to its provider; it is not relayed over
the Mux link. The Mac-to-Spark control connection shares Mux's existing port and
QUIC connection. Remote arbitrary terminal programs do not gain Mac audio devices.

`codex resume --remote <endpoint> <thread-id>` supports saved conversations, but
resuming from a separate server is not proof of attachment to a running engine.
Finish the current turn and verify ownership before moving an existing session.

The bundle declares `NSMicrophoneUsageDescription` so macOS can prompt when a
program launched inside Mux requests capture. Approve Mux in System Settings →
Privacy & Security → Microphone if needed. There is no general speaker permission.
No permission is requested automatically at app launch. Builds should retain the
stable signing identity so consent survives updates.

This transport does not separate voice and inference providers. The Devin adapter
currently only implements Responses; a `/v1/live` rejection requires a separate
provider/authentication integration. A successful socket test proves neither
ChatGPT voice entitlement nor audio playback. Acceptance needs an actual Mac
microphone/speaker conversation, interruption, and correct remote tool execution.
