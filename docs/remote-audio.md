# Native audio for remote terminals

The terminal application stays on Linux. A software ALSA device connects it to
Mac microphone/speaker hardware through the existing Mux connection. No local
Codex frontend, PipeWire, PulseAudio or additional network listener is involved.

## Setup

On the Linux host, enable the NixOS module option and rebuild:

```nix
services.muxd.audio.enable = true;
```

This adds the daemon's private audio IPC socket and the ALSA plugin/default
configuration. It also provides `/usr/share/alsa/alsa.conf` for programs bundling
stock ALSA, including Codex's voice helper. Enabling it routes ALSA `default`
to Mux; it is intended for a headless remote host. Applications outside a Mux
terminal have no route and receive a device-open error. Physical hardware can
still be addressed explicitly through its own ALSA configuration.

Update Mux.app and the remote daemon together (protocol v13), including the
ALSA plugin configuration. In any attached remote pane, start `/voice` in Codex.
Mux automatically acquires that pane's audio route and waits for the Mac devices
to be ready before acknowledging the Linux device open. Allow Mux's microphone
permission if macOS asks on first use. Nothing needs enabling for each new pane.

**File → Automatic Remote Audio** is enabled by default and remembers an off
setting across app restarts. It allows applications in remote panes attached
through this Mac's connection to request the Mac devices. The menu's tooltip
shows the focused host's audio status, including hardware/permission failures.
Turning it off revokes providers and existing routes. No hardware is opened at
app launch or just because a pane gets focus.

One pane owns Mac audio at a time, including across remote hosts. Capture and
playback opens in that pane share acquisition. A second pane cannot steal an
active call; end that call first. Changing focus never moves audio. The
microphone starts only when the remote application starts capture and stops
when capture stops. Open but stopped device handles retain ownership; closing
all handles releases the route after a short bounded idle period. Opening a
new pane then needs no additional sharing command.

The driver supports applications using mono, signed 16-bit, 48 kHz ALSA
input/output, without knowing about Codex commands or models. `muxd audio-auto
<host>` is the supervised provider helper used by Mux.app. Explicit
`muxd audio <host>:<pane>` remains available for compatibility and diagnostics.

Use headphones for dependable echo isolation. The bridge does not add its own
acoustic echo canceller; applications may do their own echo processing. Echo and
latency on open speakers depend on the application and device setup and are not
claimed equivalent to a fully local audio path.

## Ownership and transport

- CoreAudio AudioQueue owns Mac device access/conversion. The driver pins the
  default input/output devices at startup. Device failure stops sharing; select
  working devices and retry the application's voice session. Callbacks never do
  network IO or wait for a lock. Media queues have fixed bounds.
- A Linux ALSA ioplug opens a private `SOCK_SEQPACKET` socket beside muxd's control
  socket. Peer credentials and same-user process ancestry bind the plugin to
  its real terminal. Kernel pidfds pin the observed processes and public PID/UID
  metadata is rechecked, including for non-dumpable helpers hidden by procfs.
  This requires Linux 6.13 or newer; no ptrace permission is needed.
  Helpers that start a new Unix session remain associated with their parent
  terminal; unrelated or reparented processes cannot claim its route. No
  environment marker or focused-pane guess is trusted.
- One reliable audio control stream uses the host's cached QUIC connection and
  existing authentication. PCM uses QUIC datagrams on that same connection/port.
  A random lease token, per-direction start epoch and sample sequence reject
  packets from another lease, previous device run, or a late/duplicate packet.
- PCM is fixed mono S16LE at 48 kHz, at most 480 samples per datagram. Missing
  data becomes silence; old media is dropped instead of replayed. Bounded
  interpolation corrects small clock differences. This is not a lossless audio
  recorder or a latency guarantee over an unreliable WAN.
- Input and output timing is virtual on Linux. The Mac has a bounded playback
  buffer; a bounded drain preserves the end of playback. Packet loss and hardware
  clock differences remain audible limits. Capture/playback are separate device
  instances; concurrent recording clients in a pane share its mic, and only one
  playback client in that pane may run at a time.

Disabling automatic audio, losing the connection, detaching/replacing the
terminal's attachment, or quitting Mux closes the audio lease and hardware
queues. Remote shells/jobs continue. The provider reconnects automatically,
including after a daemon upgrade, so a later `/voice` attempt needs no menu
action. An interrupted voice session may still require restarting `/voice`;
active audio handles and provider sessions are not migrated. PTYs retain their
existing handoff behavior.

Automatic acquisition is bounded to eight seconds, with a ten-second ALSA
handshake timeout. A cold connection, unresolved macOS permission prompt, or
unavailable device can still fail; resolve the displayed issue and retry.
Those are timeout policies, not measured latency guarantees. The old explicit
v12 audio mode remains understood, while automatic providers require v13 on
both daemons.

## Validation

`cargo test --workspace` covers packet bounds, tokens, epochs and sequences.
`uv run python scripts/test-muxd-audio.py` runs two real daemons, a real remote
PTY and native device IPC: two-way PCM, the same QUIC connection as the terminal,
stop notifications, caller/pane isolation, and terminal survival after audio
closes. It needs no physical device or model account.

For the original explicit bridge, the actual unmodified Codex 0.156.1 voice
helper was separately tested with the
built plugin inside a remote test PTY, a local ICE-lite WebRTC peer, and the Mac
CoreAudio driver across the tailnet. It opened both devices, delivered Mac mic
samples, and produced a one-second decoded tone for Mac playback. No provider
inference was used. This proves the hardware/transport/device path, not account
entitlement, conversational model behavior, acoustic quality or a performance
benchmark. Provider authentication is unchanged; a Responses-only model proxy
still needs its own voice-routing support.
