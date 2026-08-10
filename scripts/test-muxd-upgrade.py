#!/usr/bin/env python3
"""End-to-end check of muxd's zero-downtime self-upgrade (M2.5).

What it proves, on a private socket under a temporary HOME so the user's
running daemon is never touched:

  1. daemon A runs a pty (/bin/cat) that a real mux-attach client is
     driving through a pty of its own;
  2. daemon B, started with --upgrade, takes A's ptys over SCM_RIGHTS: A
     exits 0, B serves;
  3. the child process id is UNCHANGED - the shell was never restarted,
     only re-parented;
  4. the client reconnects by itself and the replay repaints the marker
     written before the upgrade;
  5. new input still reaches the same child through B;
  6. the child's exit still propagates (the adopted-child reaper), and
     mux-attach exits with its code.

Isolation: HOME is a tempdir (the pidfile lives at
$HOME/.local/state/muxd/muxd.pid), MUXD_SOCKET and --socket point at the
tempdir, and MUXD_MIGRATE_SOCKET overrides the per-uid /tmp migration
socket. Nothing here writes a path the user's daemon uses.

Usage: python3 scripts/test-muxd-upgrade.py [--bin-dir target/debug]
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

TIMEOUT = 20.0
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def log(message: str) -> None:
    print(f"  {message}", flush=True)


class Failure(Exception):
    pass


class PtyReader(threading.Thread):
    """Drains a pty master into a buffer so waits never deadlock on it."""

    def __init__(self, fd: int) -> None:
        super().__init__(daemon=True)
        self.fd = fd
        self.buffer = bytearray()
        self.lock = threading.Lock()

    def run(self) -> None:
        while True:
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.buffer.extend(data)

    def find(self, needle: bytes, start: int = 0) -> int:
        with self.lock:
            return self.buffer.find(needle, start)

    def size(self) -> int:
        with self.lock:
            return len(self.buffer)

    def wait_for(self, needle: bytes, start: int = 0, timeout: float = TIMEOUT) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            at = self.find(needle, start)
            if at >= 0:
                return at
            time.sleep(0.02)
        with self.lock:
            tail = bytes(self.buffer[-400:])
        raise Failure(f"timed out waiting for {needle!r}; last output: {tail!r}")


def wait_until(predicate, what: str, timeout: float = TIMEOUT) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise Failure(f"timed out waiting for {what}")


def socket_answers(path: str) -> bool:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        try:
            sock.connect(path)
        except OSError:
            return False
    return True


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def child_of(parent: int, name: str) -> int:
    """The pid of `parent`'s child running `name` (a fresh fork of muxd)."""
    out = subprocess.run(
        ["ps", "-eo", "pid=,ppid=,comm="],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in out.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3:
            continue
        pid, ppid, comm = fields
        if int(ppid) == parent and os.path.basename(comm.strip()) == name:
            return int(pid)
    raise Failure(f"no {name} child of pid {parent}")


def process_command(pid: int) -> str:
    out = subprocess.run(
        ["ps", "-p", str(pid), "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
    )
    return out.stdout.strip()


def parent_of(pid: int) -> int:
    out = subprocess.run(
        ["ps", "-p", str(pid), "-o", "ppid="],
        capture_output=True,
        text=True,
        check=False,
    )
    return int(out.stdout.strip() or -1)


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", default=os.path.join(REPO, "target", "debug"))
    args = parser.parse_args()

    muxd = os.path.join(args.bin_dir, "muxd")
    mux_attach = os.path.join(args.bin_dir, "mux-attach")
    for binary in (muxd, mux_attach):
        if not os.path.exists(binary):
            print(f"missing {binary}; run `cargo build --workspace` first", file=sys.stderr)
            return 2

    # Short /tmp path: sun_path is 104 bytes on darwin.
    home = tempfile.mkdtemp(prefix="muxup-", dir="/tmp")
    control = os.path.join(home, "d.sock")
    env = dict(os.environ)
    env.update(
        HOME=home,
        MUXD_SOCKET=control,
        MUXD_MIGRATE_SOCKET=os.path.join(home, "m.sock"),
        RUST_LOG="info",
    )

    daemon_a = daemon_b = client = None
    child_pid = None
    log_a = open(os.path.join(home, "a.log"), "wb")
    log_b = open(os.path.join(home, "b.log"), "wb")
    try:
        daemon_a = subprocess.Popen(
            [muxd, "--socket", control],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log_a,
            stderr=log_a,
            start_new_session=True,
        )
        wait_until(lambda: socket_answers(control), "daemon A to listen")
        log(f"daemon A listening (pid {daemon_a.pid})")

        # A real client on a real pty, exactly as a pane runs it.
        master, slave = pty.openpty()
        set_winsize(master, 24, 80)
        client = subprocess.Popen(
            [mux_attach, "local:t1", "--", "/bin/cat"],
            env=env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            start_new_session=True,
        )
        os.close(slave)
        reader = PtyReader(master)
        reader.start()

        os.write(master, b"marker-one\n")
        reader.wait_for(b"marker-one")
        log("client attached; pty echoed marker-one")

        child_pid = child_of(daemon_a.pid, "cat")
        log(f"child /bin/cat is pid {child_pid} (parent {parent_of(child_pid)})")

        before_upgrade = reader.size()
        daemon_b = subprocess.Popen(
            [muxd, "--socket", control, "--upgrade"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log_b,
            stderr=log_b,
            start_new_session=True,
        )
        log(f"daemon B started with --upgrade (pid {daemon_b.pid})")

        code = daemon_a.wait(timeout=TIMEOUT)
        if code != 0:
            raise Failure(f"daemon A exited {code}, expected 0")
        log("daemon A handed off and exited 0")
        daemon_a = None

        if not pid_alive(child_pid):
            raise Failure(f"child {child_pid} died during the upgrade")
        if os.path.basename(process_command(child_pid)) != "cat":
            raise Failure(f"pid {child_pid} is no longer /bin/cat")
        log(f"child pid UNCHANGED: {child_pid} still alive, re-parented to {parent_of(child_pid)}")

        wait_until(lambda: socket_answers(control), "daemon B to listen")
        listing = subprocess.run(
            [mux_attach, "--list"],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        if "t1" not in listing or "/bin/cat" not in listing:
            raise Failure(f"daemon B does not serve the migrated pty: {listing!r}")
        log(f"daemon B serves the migrated pty: {listing.strip()}")

        # The client reconnected on its own; the replay repaints the
        # screen the predecessor had, marker and all.
        reader.wait_for(b"marker-one", start=before_upgrade)
        log("client reconnected and the replay repainted marker-one")

        after_replay = reader.size()
        os.write(master, b"marker-two\n")
        reader.wait_for(b"marker-two", start=after_replay)
        log("new input reached the same child through daemon B")

        # EOT: cat exits, and the adopted-child reaper must still turn
        # that into an Exit event for the client.
        os.write(master, b"\x04")
        code = client.wait(timeout=TIMEOUT)
        if code != 0:
            raise Failure(f"mux-attach exited {code}, expected 0")
        client = None
        wait_until(lambda: not pid_alive(child_pid), "the child to exit")
        log("child exit propagated; mux-attach exited 0")

        print("PASS: muxd self-upgrade preserved the pty, the pid and the screen")
        return 0
    except (Failure, subprocess.TimeoutExpired) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        for name, path in (("A", log_a.name), ("B", log_b.name)):
            log_a.flush()
            log_b.flush()
            with open(path, "rb") as handle:
                print(f"--- daemon {name} log ---\n{handle.read().decode(errors='replace')}",
                      file=sys.stderr)
        return 1
    finally:
        for process in (client, daemon_a, daemon_b):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        if child_pid is not None and pid_alive(child_pid):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except OSError:
                pass
        log_a.close()
        log_b.close()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
