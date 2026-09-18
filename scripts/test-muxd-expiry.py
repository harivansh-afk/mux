#!/usr/bin/env python3
"""Real 60-second close, reopen and upgrade lifecycle on private sockets."""
import json
import os
import shutil
import subprocess
import tempfile
import time

from muxd_harness import (
    Daemon, Pty, find_binaries, kill_process_group, list_ptys, log,
    run, sandbox_env, socket_answers, spawn_daemon, wait_until,
)


def main():
    binaries = find_binaries()
    if binaries is None:
        return 2
    muxd, relay = binaries
    with tempfile.TemporaryDirectory(prefix="muxexpire-", dir="/tmp") as home:
        socket = os.path.join(home, "d.sock")
        env = sandbox_env(home, socket, MUXD_MIGRATE_SOCKET=os.path.join(home, "m.sock"), MUXD_NO_AUTOSTART="1")
        clients = []
        successor = handle = None
        with Daemon(muxd, home, socket, env=env) as daemon:
            try:
                pids = {}
                for name in ("closed", "reopened", "detached"):
                    client = Pty([relay, f"local:{name}", "--", shutil.which("cat")], env)
                    clients.append(client)
                    wait_until(lambda: any(row["name"] == name and row["attached"]
                                           for row in list_ptys(muxd, env)), "relay attachment")
                    client.send(f"ready-{name}\n".encode())
                    client.expect(f"ready-{name}".encode(), 10, "cat ready")
                    wait_until(lambda: f"ready-{name}" in "\n".join(
                        json.loads(run([muxd, "inspect", f"local:{name}"], env).stdout)["text"]
                    ), "marker in the daemon terminal")
                    pids[name] = json.loads(run([muxd, "inspect", f"local:{name}"], env).stdout)["pid"]
                started = time.monotonic()
                deadline = int(run([muxd, "close", "local:closed"], env).stdout)
                assert int(run([muxd, "close", "local:closed"], env).stdout) == deadline
                run([muxd, "close", "local:reopened"], env)
                for client in clients:
                    client.kill()
                    client.close()
                clients = [Pty([relay, "--require-existing", "local:reopened"], env)]
                clients[0].expect(b"ready-reopened", 10, "same terminal replay")
                log("expiry", "closed, reopened and ordinary detached terminals ready")

                successor, handle = spawn_daemon(
                    muxd, socket, env, os.path.join(home, "successor.log"), ["--upgrade"]
                )
                daemon.proc.wait(timeout=15)
                wait_until(lambda: socket_answers(socket), "successor socket")
                assert len(list_ptys(muxd, env)) == 3, list_ptys(muxd, env)
                for name, pid in pids.items():
                    assert json.loads(run([muxd, "inspect", f"local:{name}"], env).stdout)["pid"] == pid
                assert int(run([muxd, "close", "local:closed"], env).stdout) == deadline

                # Wait on the real production duration, not an injected test timeout.
                end = started + 65
                while any(row["name"] == "closed" for row in list_ptys(muxd, env)):
                    assert time.monotonic() < end, "closed terminal did not expire"
                    time.sleep(0.1)
                elapsed = time.monotonic() - started
                assert 59 <= elapsed <= 62, f"expiry was {elapsed:.3f}s"
                wait_until(
                    lambda: subprocess.run(
                        ["kill", "-0", str(pids["closed"])], capture_output=True
                    ).returncode != 0,
                    "expired child to be reaped",
                )
                remaining = {row["name"] for row in list_ptys(muxd, env)}
                assert remaining == {"reopened", "detached"}, remaining
                clients[0].send(b"still-alive\n")
                clients[0].expect(b"still-alive", 10, "reopened terminal remains usable")
                log("expiry", f"PASS: expired in {elapsed:.3f}s across upgrade; reopen and detach survived")
            except Exception:
                print(daemon.log())
                if os.path.exists(os.path.join(home, "successor.log")):
                    print(open(os.path.join(home, "successor.log")).read())
                raise
            finally:
                for client in clients:
                    client.kill()
                    client.close()
                try:
                    for row in list_ptys(muxd, env):
                        run([muxd, "kill", f"local:{row['name']}"], env)
                finally:
                    if successor is not None:
                        kill_process_group(successor)
                    if handle is not None:
                        handle.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
