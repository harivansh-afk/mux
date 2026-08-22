#!/usr/bin/env python3
"""End-to-end check of what only a real daemon and a real pty can prove.
Fully isolated: a temporary HOME and a private socket, so this can never
touch a developer's live daemon. See muxd_harness.py for the shared
pieces; muxd/tests/manager.rs already pins list/kill semantics in
process, so this keeps only what needs the real binaries:
  1. attach, run a command, SIGKILL the client, reattach: the pty
     survives and the replay still carries the marker
  2. `muxd ls --json` shows the pane while it is attached
  3. `--expect-existing` against a pty the daemon does not have prints
     the recreated-shell notice
"""
import os
import shutil
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from muxd_harness import Daemon, Pty, fail, find_binaries, list_ptys, log, sandbox_env
TAG = "e2e"
MARKER = b"MARKER-42"
COMMAND = b"echo MARKER-$((40+2))\n"
NOTICE = b"the daemon lost this pane's shell"

def attach_kill_reattach(muxd_bin, mux_attach_bin, home, socket_path):
    env = sandbox_env(home, socket_path)
    with Daemon(muxd_bin, home, socket_path, env=env):
        log(TAG, "attach and run a command")
        client = Pty([mux_attach_bin, "local:t1"], env)
        client.drain(2.0)
        client.send(COMMAND)
        client.expect(MARKER, 20, "the command output to echo back")
        log(TAG, f"saw {MARKER.decode()} live")
        ptys = list_ptys(muxd_bin, env)
        if len(ptys) != 1 or ptys[0]["name"] != "t1":
            fail(f"expected one pty named t1, got {ptys}")
        log(TAG, "SIGKILL the client; the pty must survive")
        client.kill()
        client.close()
        ptys = list_ptys(muxd_bin, env)
        if len(ptys) != 1 or ptys[0]["name"] != "t1":
            fail(f"pty t1 did not outlive its client, list is {ptys}")
        log(TAG, "reattach and check the replay")
        client = Pty([mux_attach_bin, "local:t1"], env)
        client.expect(MARKER, 20, "the replayed screen to contain the marker")
        log(TAG, f"replay carried {MARKER.decode()} across the kill")
        client.send(b"exit\n")
        code = client.wait_for_exit(20)
        if code != 0:
            fail(f"client exited {code} after a clean shell exit; last output:\n{client.tail()}")
        client.close()
        log(TAG, "clean exit propagated")

def expect_existing_notice(muxd_bin, mux_attach_bin, home, socket_path):
    env = sandbox_env(home, socket_path)
    log(TAG, "restart the daemon with no memory of t1, attach with --expect-existing")
    with Daemon(muxd_bin, home, socket_path, env=env):
        client = Pty([mux_attach_bin, "--expect-existing", "local:t1"], env)
        client.expect(NOTICE, 20, "the recreated-shell notice")
        log(TAG, "notice printed for a pty the daemon had to recreate")
        client.kill()
        client.close()

def main():
    binaries = find_binaries()
    if binaries is None:
        return 2
    muxd_bin, mux_attach_bin = binaries
    tmp = tempfile.mkdtemp(prefix="muxd-e2e-")
    home = os.path.join(tmp, "home")
    os.makedirs(home)
    socket_path = os.path.join(tmp, "d.sock")  # short: sun_path is 104 bytes on darwin
    try:
        attach_kill_reattach(muxd_bin, mux_attach_bin, home, socket_path)
        expect_existing_notice(muxd_bin, mux_attach_bin, home, socket_path)
    except AssertionError as error:
        print(f"[{TAG}] FAIL: {error} (sandbox left at {tmp})", file=sys.stderr)
        return 1
    shutil.rmtree(tmp, ignore_errors=True)
    log(TAG, "PASS")
    return 0
if __name__ == "__main__":
    sys.exit(main())