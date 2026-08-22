#!/usr/bin/env python3
"""End-to-end check of muxd's zero-downtime self-upgrade.
Isolated: HOME, MUXD_SOCKET and MUXD_MIGRATE_SOCKET all point into a
private tempdir, so this never touches a developer's daemon or pidfile.
The SCM_RIGHTS handoff itself is pinned in process (muxd/tests/manager.rs);
what needs the real binaries is the part outside the daemon: a real
client on a real pty, reconnecting on its own once daemon B (started with
--upgrade) has adopted daemon A's ptys and A has exited - same pid for
the child, no notice on reconnect, replay carries pre-upgrade output, and
new input keeps reaching the same child through B.
"""
import os
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from muxd_harness import (
    Pty,
    fail,
    find_binaries,
    kill_process_group,
    list_ptys,
    log,
    sandbox_env,
    socket_answers,
    spawn_daemon,
    wait_until,
)
TAG = "upgrade"
NOTICE = b"[mux]"

def child_of(parent: int, name: str) -> int:
    """The pid of `parent`'s child running `name` (a fresh fork of muxd)."""
    found = []

    def seen() -> bool:
        out = subprocess.run(["ps", "-eo", "pid=,ppid=,comm="], capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and int(fields[1]) == parent and os.path.basename(fields[2].strip()) == name:
                found.append(int(fields[0]))
                return True
        return False
    wait_until(seen, f"a {name} child of pid {parent}", timeout=5)
    return found[0]

def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True

def run(muxd_bin, mux_attach_bin, home, socket_path):
    env = sandbox_env(home, socket_path, MUXD_MIGRATE_SOCKET=os.path.join(home, "m.sock"))
    log_a = os.path.join(home, "a.log")
    log_b = os.path.join(home, "b.log")
    daemon_a, file_a = spawn_daemon(muxd_bin, socket_path, env, log_a)
    daemon_b = file_b = None
    child_pid = None
    try:
        wait_until(lambda: socket_answers(socket_path), "daemon A to listen")
        log(TAG, f"daemon A listening (pid {daemon_a.pid})")
        client = Pty([mux_attach_bin, "local:t1", "--", "/bin/cat"], env)
        client.send(b"marker-one\n")
        client.expect(b"marker-one", 20, "the pty to echo marker-one")
        log(TAG, "client attached; pty echoed marker-one")
        child_pid = child_of(daemon_a.pid, "cat")
        log(TAG, f"child /bin/cat is pid {child_pid}")
        before_upgrade = len(client.buffer)
        daemon_b, file_b = spawn_daemon(muxd_bin, socket_path, env, log_b, extra_args=["--upgrade"])
        log(TAG, f"daemon B started with --upgrade (pid {daemon_b.pid})")
        code = daemon_a.wait(timeout=20)
        if code != 0:
            fail(f"daemon A exited {code}, expected 0")
        log(TAG, "daemon A handed off and exited 0")
        comm = subprocess.run(["ps", "-p", str(child_pid), "-o", "comm="], capture_output=True, text=True).stdout
        if not pid_alive(child_pid) or os.path.basename(comm.strip()) != "cat":
            fail(f"child {child_pid} did not survive the upgrade as /bin/cat")
        log(TAG, f"child pid unchanged: {child_pid} still alive")
        wait_until(lambda: socket_answers(socket_path), "daemon B to listen")
        ptys = list_ptys(mux_attach_bin, env)
        migrated = next((p for p in ptys if p["name"] == "t1"), None)
        if migrated is None or "/bin/cat" not in migrated["command"]:
            fail(f"daemon B does not serve the migrated pty: {ptys}")
        log(TAG, "daemon B serves the migrated pty")
        # marker-one is already in the buffer from before the upgrade, so
        # this has to check the *new* bytes: proof the reconnect actually
        # finished, not just that old output is still sitting there.
        def replayed() -> bool:
            client.drain(0.2)
            return b"marker-one" in client.buffer[before_upgrade:]
        wait_until(replayed, "the reconnect replay to repaint marker-one", timeout=20)
        if NOTICE in client.buffer[before_upgrade:]:
            fail(f"reconnect printed a notice it should not have:\n{client.tail()}")
        log(TAG, "client reconnected with no notice; replay repainted marker-one")
        after_replay = len(client.buffer)
        client.send(b"marker-two\n")
        client.expect(b"marker-two", 20, "new input to reach the child through daemon B")
        log(TAG, "new input reached the same child through daemon B")
        client.send(b"\x04")  # EOT: cat exits
        code = client.wait_for_exit(20)
        if code != 0:
            fail(f"mux-attach exited {code}, expected 0")
        wait_until(lambda: not pid_alive(child_pid), "the child to exit")
        client.close()
        log(TAG, "child exit propagated; mux-attach exited 0")
    finally:
        for proc in (daemon_a, daemon_b):
            if proc is not None:
                kill_process_group(proc)
        for handle in (file_a, file_b):
            if handle is not None:
                handle.close()
        if child_pid is not None and pid_alive(child_pid):
            os.kill(child_pid, 9)

def main():
    binaries = find_binaries()
    if binaries is None:
        return 2
    muxd_bin, mux_attach_bin = binaries
    home = tempfile.mkdtemp(prefix="muxup-", dir="/tmp")  # short: sun_path is 104 bytes on darwin
    socket_path = os.path.join(home, "d.sock")
    try:
        run(muxd_bin, mux_attach_bin, home, socket_path)
    except AssertionError as error:
        print(f"[{TAG}] FAIL: {error} (sandbox left at {home})", file=sys.stderr)
        return 1
    shutil.rmtree(home, ignore_errors=True)
    log(TAG, "PASS: pty, pid and screen survived the upgrade")
    return 0
if __name__ == "__main__":
    sys.exit(main())