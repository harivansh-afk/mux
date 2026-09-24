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

Update Mux.app and the remote daemon together (protocol v12). In the Mac app,
focus the remote pane and select **File → Share Mac Audio with This Pane**.
Allow Mux's microphone permission if macOS asks. Then start `/voice` in Codex
inside that same remote pane. The driver also supports other applications that
can use mono, signed 16-bit, 48 kHz ALSA input/output.

The first release has one enabled pane per Mac app and one audio owner per host
connection. Changing focus does not move the microphone. The menu changes to
**Stop Sharing Mac Audio**; use it before selecting another pane. Microphone
capture starts only when the remote application starts its capture device, and
stops when it closes/stops capture. The hardware driver is one child `muxd audio`
process; the Mac and remote network daemons are the existing muxd processes.

Use headphones for dependable echo isolation. The bridge does not add its own
acoustic echo canceller; applications may do their own echo processing. Echo and
latency on open speakers depend on the application and device setup and are not
claimed equivalent to a fully local audio path.

## Ownership and transport

- CoreAudio AudioQueue owns Mac device access/conversion. The driver pins the
  default input/output devices at startup. Device failure stops sharing; select
  working devices and enable it again. Callbacks never do network IO or wait for
  a lock. Media queues have fixed bounds.
- A Linux ALSA ioplug opens a private `SOCK_SEQPACKET` socket beside muxd's control
  socket. Peer credentials and same-user process ancestry bind the plugin to
  its real terminal. Every observed parent/start-time identity is rechecked.
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

Stopping sharing, losing the connection, detaching/replacing the terminal's
attachment, or quitting Mux closes the audio lease and hardware queues. Remote
shells/jobs continue. Applications receive device loss and may need voice mode
restarted after sharing is enabled again. Audio leases are not migrated across
daemon upgrades; PTYs retain their existing handoff behavior.

## Validation

`cargo test --workspace` covers packet bounds, tokens, epochs and sequences.
`uv run python scripts/test-muxd-audio.py` runs two real daemons, a real remote
PTY and native device IPC: two-way PCM, the same QUIC connection as the terminal,
stop notifications, caller/pane isolation, and terminal survival after audio
closes. It needs no physical device or model account.

The actual unmodified Codex 0.156.1 voice helper was separately tested with the
built plugin inside a remote test PTY, a local ICE-lite WebRTC peer, and the Mac
CoreAudio driver across the tailnet. It opened both devices, delivered Mac mic
samples, and produced a one-second decoded tone for Mac playback. No provider
inference was used. This proves the hardware/transport/device path, not account
entitlement, conversational model behavior, acoustic quality or a performance
benchmark. Provider authentication is unchanged; a Responses-only model proxy
still needs its own voice-routing support.
