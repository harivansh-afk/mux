#!/usr/bin/env python3
"""End-to-end check that muxd survives its client: attach, detach hard, reattach.

Builds nothing. Point it at binaries with MUXD_BIN / MUX_ATTACH_BIN, or let
it default to target/debug/{muxd,mux-attach} beside this checkout.

The run is fully isolated - a temporary HOME and a private --socket inside a
temporary directory - so it can never touch a developer's live daemon.

Sequence:
  1. start muxd on the private socket
  2. drive `mux-attach local:t1` under a pty, run `echo MARKER-$((40+2))`,
     assert MARKER-42 comes back through the relay
  3. SIGKILL the client (the pty must outlive it)
  4. reattach, assert the replayed screen still contains MARKER-42
  5. type `exit`, assert the client terminates and `--list` reports nothing
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MUXD_BIN = os.environ.get("MUXD_BIN") or os.path.join(REPO_ROOT, "target/debug/muxd")
MUX_ATTACH_BIN = os.environ.get("MUX_ATTACH_BIN") or os.path.join(
    REPO_ROOT, "target/debug/mux-attach"
)

PTY_NAME = "t1"
MARKER = b"MARKER-42"
# Typed literally so the marker only appears once the shell has evaluated it:
# the terminal echo of the keystrokes cannot be mistaken for the result.
COMMAND = b"echo MARKER-$((40+2))\n"

ROWS, COLS = 24, 80


def log(message):
    print(f"[e2e] {message}", flush=True)


def fail(message):
    raise AssertionError(message)


class Pty:
    """A pty pair whose master end we drive as the "user" of a client."""

    def __init__(self):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.buffer = bytearray()

    def close(self):
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass

    def send(self, data):
        os.write(self.master, data)

    def drain(self, timeout):
        """Read whatever is available for up to `timeout` seconds."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            if not self._readable(remaining):
                return
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return  # EIO: the slave side is gone
            if not chunk:
                return
            self.buffer += chunk

    def expect(self, needle, timeout, what):
        """Accumulate output until `needle` shows up, or fail."""
        deadline = time.monotonic() + timeout
        while needle not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"timed out waiting for {what}; got:\n{self.tail()}")
            if not self._readable(remaining):
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                fail(f"pty closed while waiting for {what}; got:\n{self.tail()}")
            if not chunk:
                fail(f"pty EOF while waiting for {what}; got:\n{self.tail()}")
            self.buffer += chunk

    def tail(self, limit=2000):
        text = self.buffer[-limit:].decode("utf-8", "replace")
        return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)

    def _readable(self, timeout):
        ready, _, _ = select.select([self.master], [], [], timeout)
        return bool(ready)


class Harness:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="muxd-e2e-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        # Short path on purpose: sun_path is 104 bytes on darwin.
        self.socket = os.path.join(self.tmp, "d.sock")
        self.shell = shutil.which("bash") or shutil.which("sh") or "/bin/sh"
        self.muxd = None
        self.log_file = None

    def env(self):
        env = dict(os.environ)
        env.update(
            HOME=self.home,
            SHELL=self.shell,
            MUXD_SOCKET=self.socket,
            TERM="xterm-256color",
            # A prompt of our own keeps the replay assertions readable and
            # stops a developer's rc files from bleeding in.
            PS1="e2e$ ",
        )
        for stale in ("MUXD_BIN", "MUX_ATTACH_BIN"):
            env.pop(stale, None)
        return env

    def start_daemon(self):
        # Belt and braces: refuse to run if the socket is not our own temp one.
        if not self.socket.startswith(self.tmp):
            fail(f"refusing to use a socket outside the sandbox: {self.socket}")
        self.log_file = open(os.path.join(self.tmp, "muxd.log"), "wb")
        self.muxd = subprocess.Popen(
            [MUXD_BIN, "--socket", self.socket],
            env=self.env(),
            stdin=subprocess.DEVNULL,
            stdout=self.log_file,
            stderr=self.log_file,
            # Own session: teardown can kill the whole tree without ever
            # reaching this script's process group.
            start_new_session=True,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.muxd.poll() is not None:
                fail(f"muxd exited early ({self.muxd.returncode}):\n{self.daemon_log()}")
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.connect(self.socket)
                log(f"muxd listening on {self.socket}")
                return
            except OSError:
                time.sleep(0.05)
        fail(f"muxd never bound {self.socket}:\n{self.daemon_log()}")

    def attach(self):
        tty = Pty()
        client = subprocess.Popen(
            [MUX_ATTACH_BIN, f"local:{PTY_NAME}"],
            env=self.env(),
            stdin=tty.slave,
            stdout=tty.slave,
            stderr=tty.slave,
            start_new_session=True,
        )
        return client, tty

    def list_ptys(self):
        result = subprocess.run(
            [MUX_ATTACH_BIN, "--list"],
            env=self.env(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
        return [line for line in result.stdout.splitlines() if line.strip()]

    def daemon_log(self):
        try:
            with open(os.path.join(self.tmp, "muxd.log"), "r", errors="replace") as handle:
                return handle.read()
        except OSError:
            return "<no log>"

    def cleanup(self):
        if self.muxd and self.muxd.poll() is None:
            try:
                os.killpg(os.getpgid(self.muxd.pid), signal.SIGKILL)
            except OSError:
                self.muxd.kill()
            self.muxd.wait(timeout=10)
        if self.log_file:
            self.log_file.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


def wait_for_exit(client, tty, timeout):
    """Wait out the client while still draining its pty.

    Not draining would be a deadlock waiting to happen: the client flushes
    the last of the shell's output before it exits, and a full pty buffer
    would block that write forever.
    """
    deadline = time.monotonic() + timeout
    while client.poll() is None:
        if time.monotonic() > deadline:
            return None
        tty.drain(0.1)
    return client.returncode


def kill_client(client):
    """SIGKILL the client's whole session: no chance of a clean detach."""
    try:
        os.killpg(os.getpgid(client.pid), signal.SIGKILL)
    except OSError:
        client.kill()
    client.wait(timeout=10)


def run(harness):
    harness.start_daemon()

    log("attach and run a command")
    client, tty = harness.attach()
    try:
        # Let the shell come up and paint a prompt before typing, so the
        # keystrokes land after mux-attach has switched the pty to raw mode.
        tty.drain(2.0)
        tty.send(COMMAND)
        tty.expect(MARKER, 20, "the command output to echo back")
        log(f"saw {MARKER.decode()} live")

        listed = harness.list_ptys()
        if len(listed) != 1 or not listed[0].startswith(PTY_NAME):
            fail(f"expected one pty named {PTY_NAME}, got {listed}")

        log("SIGKILL the client; the pty must survive")
        kill_client(client)
    finally:
        tty.close()

    listed = harness.list_ptys()
    if len(listed) != 1 or not listed[0].startswith(PTY_NAME):
        fail(f"pty {PTY_NAME} did not outlive its client, list is {listed}")

    log("reattach and check the replay")
    client, tty = harness.attach()
    try:
        tty.expect(MARKER, 20, "the replayed screen to contain the marker")
        log(f"replay carried {MARKER.decode()} across the kill")

        log("type exit; the client must terminate")
        tty.send(b"exit\n")
        code = wait_for_exit(client, tty, 20)
        if code is None:
            fail(f"client did not exit after `exit`; last output:\n{tty.tail()}")
        if code != 0:
            fail(f"client exited {code} after a clean shell exit")
    finally:
        if client.poll() is None:
            kill_client(client)
        tty.close()

    # The daemon drops a pty when its child is reaped; give it a beat.
    deadline = time.monotonic() + 10
    while True:
        listed = harness.list_ptys()
        if not listed:
            break
        if time.monotonic() > deadline:
            fail(f"pty list should be empty after exit, got {listed}")
        time.sleep(0.1)
    log("pty list is empty")


def main():
    for name, path in (("MUXD_BIN", MUXD_BIN), ("MUX_ATTACH_BIN", MUX_ATTACH_BIN)):
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            print(
                f"{name} is not an executable file: {path}\n"
                "build first: cargo build -p muxd -p mux-attach",
                file=sys.stderr,
            )
            return 2

    harness = Harness()
    try:
        run(harness)
    except AssertionError as error:
        print(f"[e2e] FAIL: {error}", file=sys.stderr)
        print(f"[e2e] muxd log:\n{harness.daemon_log()}", file=sys.stderr)
        return 1
    finally:
        harness.cleanup()
    log("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
