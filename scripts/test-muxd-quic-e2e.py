#!/usr/bin/env python3
"""Two-daemon QUIC e2e: pane -> local muxd (broker) -> QUIC -> remote muxd.
Hermetic: two tempdir HOMEs, private sockets, loopback QUIC on an
uncommon port, never the default per-uid socket. The listener's
authentication and TOFU pinning are pinned in process (muxd/tests/quic.rs,
broker.rs's own tests); what needs a real process pair is the end-to-end
broker dial through a second daemon: a pane reaches a pty on a genuinely
separate remote daemon by digest alone, the pty is the remote daemon's
and not the local one's, a killed client reattaches through the broker
and gets its screen replayed over QUIC, `muxd probe` reports the host
healthy in one line, a stale pin is refused (`pin-mismatch`), and a wrong
bearer token is refused (`token-rejected`) - both classified by probe.
"""
import json
import os
import shutil
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from muxd_harness import Daemon, Pty, fail, find_binaries, list_ptys, log, run, sandbox_env
TAG = "quic"
QUIC_ADDR = "127.0.0.1:14433"
MARKER = b"RMARKER-42"

def probe(muxd_bin, env, alias):
    """One JSON line, the health check Mux.app runs per host."""
    done = run([muxd_bin, "probe", alias], env, check=False)
    if len(done.stdout.splitlines()) != 1:
        fail(f"probe printed {done.stdout!r}, expected one line")
    return done.returncode, json.loads(done.stdout)

def main():
    binaries = find_binaries()
    if binaries is None:
        return 2
    muxd_bin, mux_attach_bin = binaries
    remote_home = tempfile.mkdtemp(prefix="mux-quic-remote-")
    local_home = tempfile.mkdtemp(prefix="mux-quic-local-")
    remote_sock = os.path.join(remote_home, "muxd.sock")
    local_sock = os.path.join(local_home, "muxd.sock")
    try:
        env_local = sandbox_env(local_home, local_sock)
        env_remote = sandbox_env(remote_home, remote_sock)
        # Enrollment, client side: this client's identity, and its digest
        # for the host's authorized-tokens file. The token never leaves here.
        digest = run([muxd_bin, "client-digest"], env_local).stdout.strip()
        if not (digest.startswith("sha256:") and len(digest) == 71):
            fail(f"bad client digest: {digest}")
        authorized = os.path.join(remote_home, "authorized-tokens")
        with open(authorized, "w") as f:
            f.write(f"# the client\n{digest}\n")
        # hosts.json names the remote by alias; no tokens/<alias> file yet
        # - the broker presents the identity the host just enrolled.
        os.makedirs(os.path.join(local_home, ".config/mux"), exist_ok=True)
        with open(os.path.join(local_home, ".config/mux/hosts.json"), "w") as f:
            json.dump({"testbox": {"addr": QUIC_ADDR}}, f)
        with Daemon(
            muxd_bin, remote_home, remote_sock, env=env_remote,
            extra_args=["--listen-quic", QUIC_ADDR, "--authorized-tokens", authorized],
        ), Daemon(muxd_bin, local_home, local_sock, env=env_local):
            # A pin that predates the remote's real key: the very first
            # dial's TOFU check must reject it, no prior contact needed.
            known_hosts = os.path.join(local_home, ".local/state/mux/known_hosts")
            os.makedirs(os.path.dirname(known_hosts), exist_ok=True)
            with open(known_hosts, "w") as f:
                f.write("testbox sha256:stale00000000000000000000000000000000000\n")
            client = Pty([mux_attach_bin, "testbox:pin-check"], env_local)
            client.expect(b"host key changed for testbox", 20, "the pin-mismatch rejection")
            client.kill()
            client.close()
            if probe(muxd_bin, env_local, "testbox")[1].get("class") != "pin-mismatch":
                fail("probe did not classify the stale pin as pin-mismatch")
            log(TAG, "stale pin rejected, and probe classifies it pin-mismatch")
            os.remove(known_hosts)
            log(TAG, "attach through the broker")
            client = Pty([mux_attach_bin, "testbox:remote-pane-1"], env_local)
            client.drain(2.0)
            client.send(b"echo RMARKER-$((40+2))\n")
            client.expect(MARKER, 20, "the marker via the broker")
            log(TAG, "enrolled by digest alone, pane reached the remote daemon on first contact")
            names_remote = [p["name"] for p in list_ptys(muxd_bin, env_remote)]
            names_local = [p["name"] for p in list_ptys(muxd_bin, env_local)]
            if "remote-pane-1" not in names_remote or "remote-pane-1" in names_local:
                fail(f"pty not owned by the remote daemon alone: remote={names_remote} local={names_local}")
            log(TAG, "pty owned by the remote daemon, absent from the local one")
            client.kill()
            client.close()
            client = Pty([mux_attach_bin, "--require-existing", "testbox:remote-pane-1"], env_local)
            client.expect(MARKER, 20, "the strict reopen replay through the broker")
            client.kill()
            client.close()
            log(TAG, "killed client reattached through the broker; screen replayed over QUIC")
            client = Pty([mux_attach_bin, "--require-existing", "testbox:missing"], env_local)
            client.expect(b"no replacement shell was started", 20, "remote strict reopen rejection")
            if any(p["name"] == "missing" for p in list_ptys(muxd_bin, env_remote)):
                fail("strict reopen created a remote replacement shell")
            if list_ptys(muxd_bin, env_local):
                fail("strict remote reopen fell back to a local shell")
            client.kill()
            client.close()
            code, ok = probe(muxd_bin, env_local, "testbox")
            # Loopback answers in well under a second.
            if code != 0 or ok.get("alias") != "testbox" or ok.get("ok") is not True:
                fail(f"probe did not report the host ok: {ok}")
            if ok.get("ptys", 0) < 1 or not 0 <= ok.get("rtt_ms", -1) < 1000:
                fail(f"probe shape off: {ok}")
            code, missing = probe(muxd_bin, env_local, "ghost")
            if code != 1 or missing.get("class") != "no-host":
                fail(f"probe did not classify an unknown alias as no-host: {missing}")
            log(TAG, f"probe reports ok in {ok['rtt_ms']}ms, and no-host for an unknown alias")
            log(TAG, "a wrong bearer token is rejected")
            tok_dir = os.path.join(local_home, ".local/state/mux/tokens")
            os.makedirs(tok_dir, exist_ok=True)
            with open(os.path.join(tok_dir, "testbox"), "w") as f:
                f.write("deadbeef" * 8)
            client = Pty([mux_attach_bin, "testbox:should-fail"], env_local)
            client.expect(b"authentication failed", 20, "the rejection to reach the pane")
            client.kill()
            client.close()
            if probe(muxd_bin, env_local, "testbox")[1].get("class") != "token-rejected":
                fail("probe did not classify the wrong token as token-rejected")
            log(TAG, "wrong token rejected, and probe classifies it token-rejected")
    except AssertionError as error:
        print(f"[{TAG}] FAIL: {error} (sandboxes left at {remote_home}, {local_home})", file=sys.stderr)
        return 1
    shutil.rmtree(remote_home, ignore_errors=True)
    shutil.rmtree(local_home, ignore_errors=True)
    log(TAG, "PASS")
    return 0
if __name__ == "__main__":
    sys.exit(main())
