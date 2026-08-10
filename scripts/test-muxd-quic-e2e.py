#!/usr/bin/env python3
"""Two-daemon QUIC e2e: pane -> local muxd (broker) -> QUIC -> remote muxd.

Fully hermetic: two tempdir HOMEs, private sockets, loopback QUIC on an
uncommon port. Never touches the default per-uid socket.

Verifies:
  1. attach through the broker reaches a pty on the remote daemon
  2. TOFU pin is recorded on first contact
  3. the pty is owned by the remote daemon, not the local one
  4. killing the client and reattaching replays the screen over QUIC
  5. a wrong bearer token is rejected with a readable error

Env: MUXD_BIN / MUX_ATTACH_BIN override target/debug defaults.
"""

import atexit
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MUXD = os.environ.get("MUXD_BIN", "target/debug/muxd")
ATTACH = os.environ.get("MUX_ATTACH_BIN", "target/debug/mux-attach")
QUIC_ADDR = "127.0.0.1:14433"

remote_home = tempfile.mkdtemp(prefix="mux-quic-remote-")
local_home = tempfile.mkdtemp(prefix="mux-quic-local-")
remote_sock = os.path.join(remote_home, "muxd.sock")
local_sock = os.path.join(local_home, "muxd.sock")
procs = []


def cleanup():
    for p in procs:
        try:
            p.terminate()
        except OSError:
            pass


atexit.register(cleanup)


def read_all(fd, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


def main():
    shell = "/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh"

    # Remote daemon with the QUIC listener; cert/token generated on start.
    env_remote = dict(os.environ, HOME=remote_home, MUXD_SOCKET=remote_sock)
    procs.append(
        subprocess.Popen(
            [MUXD, "--socket", remote_sock, "--listen-quic", QUIC_ADDR],
            env=env_remote,
            stderr=open(os.path.join(remote_home, "muxd.log"), "w"),
        )
    )
    time.sleep(1.2)

    # Local daemon: hosts.json names the remote; token copied over like a
    # user would after reading the remote daemon's startup log.
    env_local = dict(
        os.environ,
        HOME=local_home,
        MUXD_SOCKET=local_sock,
        TERM="xterm-256color",
        SHELL=shell,
    )
    os.makedirs(os.path.join(local_home, ".config/mux"), exist_ok=True)
    with open(os.path.join(local_home, ".config/mux/hosts.json"), "w") as f:
        json.dump({"testbox": {"addr": QUIC_ADDR}}, f)
    tok_dir = os.path.join(local_home, ".local/state/mux/tokens")
    os.makedirs(tok_dir, exist_ok=True)
    shutil.copy(
        os.path.join(remote_home, ".local/state/muxd/token"),
        os.path.join(tok_dir, "testbox"),
    )
    procs.append(
        subprocess.Popen(
            [MUXD, "--socket", local_sock],
            env=env_local,
            stderr=open(os.path.join(local_home, "muxd.log"), "w"),
        )
    )
    time.sleep(0.8)

    def spawn_attach(target):
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(ATTACH, [ATTACH, target], env_local)
        return pid, fd

    # 1. attach through the broker.
    pid, fd = spawn_attach("testbox:remote-pane-1")
    time.sleep(1.5)
    os.write(fd, b"echo RMARKER-$((40+2))\r")
    out = read_all(fd, 2.0)
    assert b"RMARKER-42" in out, f"no marker via broker: {out[-400:]!r}"
    print("PASS: pane attached through local broker -> QUIC -> remote daemon")

    # 2. TOFU pin recorded - and byte-identical to the pin the remote
    # daemon logged, which is what a user copies into known_hosts. This
    # equality is the assertion that catches format drift between the
    # server's log and the client's parser.
    with open(os.path.join(local_home, ".local/state/mux/known_hosts")) as f:
        known_hosts = f.read()
    assert "testbox sha256:" in known_hosts, known_hosts
    stored = known_hosts.split("testbox ", 1)[1].split()[0]
    with open(os.path.join(remote_home, "muxd.log")) as f:
        log = f.read()
    assert stored in log, f"pin {stored!r} not found in the daemon's startup log"
    print("PASS: TOFU pin recorded and matches the daemon's logged pin")

    # 3. pty owned by the remote daemon.
    lst_remote = subprocess.run(
        [ATTACH, "--list"], env=env_remote, capture_output=True, text=True
    ).stdout
    lst_local = subprocess.run(
        [ATTACH, "--list"], env=env_local, capture_output=True, text=True
    ).stdout
    assert "remote-pane-1" in lst_remote, lst_remote
    assert "remote-pane-1" not in lst_local, lst_local
    print("PASS: pty owned by the remote daemon")

    # 4. kill client, reattach, replay over QUIC.
    os.kill(pid, signal.SIGKILL)
    os.close(fd)
    time.sleep(0.6)
    _pid2, fd2 = spawn_attach("testbox:remote-pane-1")
    out2 = read_all(fd2, 2.0)
    assert b"RMARKER-42" in out2, f"replay missing: {out2[-400:]!r}"
    print("PASS: kill client, reattach through broker, screen replayed")

    # 5. wrong token rejected.
    with open(os.path.join(tok_dir, "testbox"), "w") as f:
        f.write("deadbeef" * 8)
    _pid3, fd3 = spawn_attach("testbox:should-fail")
    out3 = read_all(fd3, 2.0)
    assert b"authentication failed" in out3 or b"daemon error" in out3, out3[-300:]
    print("PASS: wrong token rejected with a readable error")

    print("ALL QUIC E2E PASS")


if __name__ == "__main__":
    sys.exit(main())
