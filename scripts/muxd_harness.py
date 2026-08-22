"""Shared harness for muxd's real-pty, real-binary e2e scripts: a
throwaway HOME, a private socket, real `muxd`/`mux-attach` processes.
Protocol-level behaviour is already pinned in-process
(muxd/tests/manager.rs, muxd/tests/quic.rs); keep new cases out of the
scripts beside this file unless they need a real process tree.
Stdlib only, so this runs under `uv run` or plain `python3`.
"""
from __future__ import annotations
import fcntl
import json
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
import termios
import time
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROWS, COLS = 24, 80

def find_binaries() -> tuple[str, str] | None:
    """MUXD_BIN/MUX_ATTACH_BIN win, else CARGO_TARGET_DIR/debug (default
    target/debug beside the repo). None, with a message on stderr, if
    either isn't an executable file yet."""
    target_dir = os.environ.get("CARGO_TARGET_DIR") or os.path.join(REPO_ROOT, "target")
    muxd = os.environ.get("MUXD_BIN") or os.path.join(target_dir, "debug", "muxd")
    mux_attach = os.environ.get("MUX_ATTACH_BIN") or os.path.join(target_dir, "debug", "mux-attach")
    for name, path in (("MUXD_BIN", muxd), ("MUX_ATTACH_BIN", mux_attach)):
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            print(f"{name} is not executable: {path}\nbuild first: cargo build -p muxd -p mux-attach", file=sys.stderr)
            return None
    return muxd, mux_attach

def log(tag: str, message: str) -> None:
    print(f"[{tag}] {message}", flush=True)

def fail(message: str):
    raise AssertionError(message)

def sandbox_env(home: str, socket_path: str, **overrides: str) -> dict:
    """What every daemon and client runs under: a throwaway HOME and a
    private socket, so this can never reach a developer's live daemon."""
    env = dict(os.environ)
    env.update(
        HOME=home,
        MUXD_SOCKET=socket_path,
        TERM="xterm-256color",
        SHELL=shutil.which("bash") or shutil.which("sh") or "/bin/sh",
        PS1="e2e$ ",  # a prompt of our own keeps replay assertions readable
    )
    for stale in ("MUXD_BIN", "MUX_ATTACH_BIN"):
        env.pop(stale, None)
    env.update(overrides)
    return env

def run(cmd: list[str], env: dict, timeout: float = 30, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, check=check)

def socket_answers(path: str, timeout: float = 0.5) -> bool:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(timeout)
        try:
            probe.connect(path)
        except OSError:
            return False
    return True

def wait_until(predicate, what: str, timeout: float = 10.0, interval: float = 0.05) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    fail(f"timed out waiting for {what}")

def kill_process_group(proc: subprocess.Popen, timeout: float = 10) -> int:
    """SIGKILL the session `proc` was started with (start_new_session=True) and reap it."""
    if proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            proc.kill()
        proc.wait(timeout=timeout)
    return proc.returncode

def spawn_daemon(muxd_bin: str, socket_path: str, env: dict, log_path: str, extra_args: list[str] | None = None):
    """Start muxd without waiting for it to be ready; own session, so
    teardown never reaches this script's process group."""
    log_file = open(log_path, "wb")
    proc = subprocess.Popen(
        [muxd_bin, "--socket", socket_path, *(extra_args or [])],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=log_file,
        start_new_session=True,
    )
    return proc, log_file

class Daemon:
    """Context manager for a muxd on a private socket: spawn, wait for
    the socket to answer, kill and reap on exit. For the finer-grained
    two-daemon handoff in test-muxd-upgrade.py, use spawn_daemon and
    socket_answers directly instead."""

    def __init__(self, muxd_bin: str, home: str, socket_path: str, env: dict | None = None, extra_args: list[str] | None = None):
        self.muxd_bin = muxd_bin
        self.socket_path = socket_path
        self.env = env if env is not None else sandbox_env(home, socket_path)
        self.extra_args = extra_args
        self.log_path = os.path.join(home, "muxd.log")
        self.proc: subprocess.Popen | None = None
        self._log_file = None

    def __enter__(self) -> "Daemon":
        self.proc, self._log_file = spawn_daemon(self.muxd_bin, self.socket_path, self.env, self.log_path, self.extra_args)

        def ready() -> bool:
            if self.proc.poll() is not None:
                fail(f"muxd exited early ({self.proc.returncode}):\n{self.log()}")
            return socket_answers(self.socket_path)
        wait_until(ready, f"muxd to bind {self.socket_path}")
        return self

    def log(self) -> str:
        try:
            return open(self.log_path, "r", errors="replace").read()
        except OSError:
            return "<no log>"

    def __exit__(self, *exc) -> bool:
        if self.proc is not None:
            kill_process_group(self.proc)
        if self._log_file:
            self._log_file.close()
        return False

class Pty:
    """A real pty driving a real subprocess: `cmd` runs on the slave end,
    the master end is what a terminal emulator would see."""

    def __init__(self, cmd: list[str], env: dict, rows: int = ROWS, cols: int = COLS):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.buffer = bytearray()
        self.proc = subprocess.Popen(cmd, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        # Only the child needs the slave now; holding it open here would
        # hide the child's hangup from the master.
        os.close(slave)

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def _read(self, timeout: float) -> bytes:
        if timeout <= 0 or not self._readable(timeout):
            return b""
        try:
            return os.read(self.master, 65536)
        except OSError:
            return b""  # the slave side is gone

    def _pump(self, timeout: float, needle: bytes | None = None) -> bool:
        """Read until `needle` shows up (drain-only when None), or the
        deadline or the pty closes. True means `needle` was found."""
        deadline = time.monotonic() + timeout
        while needle is None or needle not in self.buffer:
            chunk = self._read(deadline - time.monotonic())
            if not chunk:
                return needle is None
            self.buffer += chunk
        return True

    def drain(self, timeout: float) -> None:
        self._pump(timeout)

    def expect(self, needle: bytes, timeout: float, what: str) -> None:
        if not self._pump(timeout, needle):
            fail(f"timed out waiting for {what}; got:\n{self.tail()}")

    def wait_for_exit(self, timeout: float) -> int | None:
        """Wait out the process while still draining its pty: not
        draining would deadlock if it flushes more than a pty buffer's
        worth of output on its way out."""
        deadline = time.monotonic() + timeout
        while self.proc.poll() is None:
            if time.monotonic() > deadline:
                return None
            self.drain(0.1)
        return self.proc.returncode

    def tail(self, limit: int = 2000) -> str:
        text = self.buffer[-limit:].decode("utf-8", "replace")
        return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)

    def kill(self, timeout: float = 10) -> int:
        return kill_process_group(self.proc, timeout)

    def close(self) -> None:
        try:
            os.close(self.master)
        except OSError:
            pass

    def _readable(self, timeout: float) -> bool:
        ready, _, _ = select.select([self.master], [], [], max(timeout, 0))
        return bool(ready)

def list_ptys(mux_attach_bin: str, env: dict) -> list[dict]:
    """The pane list, as the daemon this `env` points at sees it, through
    `mux-attach --list --json`. Task 07 adds `muxd ls --json`; when it
    lands, this is the only line these scripts need to change."""
    result = run([mux_attach_bin, "--list", "--json"], env)
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]