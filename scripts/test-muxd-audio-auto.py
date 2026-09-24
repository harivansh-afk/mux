#!/usr/bin/env python3
"""Automatic audio acquisition on real PTYs/QUIC, with a synthetic Mac provider.
No physical audio or provider inference. All daemons and state are disposable.
"""
import importlib.util
import json
import select
import socket
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path

from muxd_harness import Daemon, Pty, find_binaries, run, sandbox_env

spec = importlib.util.spec_from_file_location('audio_test', Path(__file__).with_name('test-muxd-audio.py'))
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


def number(data, offset=0):
    result = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        result |= (byte & 127) << shift
        if byte < 128:
            return result, offset
        shift += 7
        assert shift <= 63


def connect(control, mode):
    stream = socket.socket(socket.AF_UNIX)
    stream.settimeout(12)
    stream.connect(control)
    audio.message(stream, audio.varint(13) + b'\0\0\0\0\1' + audio.string('testbox') + mode)
    kind, reply = audio.lane(stream)
    assert kind == 0
    return stream, reply


class Provider:
    def __init__(self, control):
        self.control = control
        self.stream, reply = connect(control, audio.varint(12))
        assert reply == b'\0\x0a', reply
        self.requests = []
        self.errors = []
        self.active = None
        self.media = None
        self.ready = threading.Event()
        self.ready.set()
        self.requested = threading.Event()
        self.ended = threading.Event()
        self.stopped = False
        self.reject = False
        self.worker = threading.Thread(target=self.serve, daemon=True)
        self.worker.start()

    def serve(self):
        try:
            while not self.stopped:
                kind, request = audio.lane(self.stream)
                assert kind == 2
                ident, cursor = number(request)
                length, cursor = number(request, cursor)
                name = request[cursor:cursor + length].decode()
                self.requests.append((name, request))
                self.requested.set()
                if self.reject or self.active is not None:
                    audio.message(self.stream, audio.varint(ident) + b'\1' + audio.string('Mac audio is busy'))
                    continue
                media, reply = connect(self.control, audio.varint(13) + request)
                assert reply[:2] == b'\0\x09', reply
                self.media = media
                self.active = name
                self.ended.clear()
                assert self.ready.wait(5)
                audio.message(self.stream, audio.varint(ident) + b'\0')
                threading.Thread(target=self.pump, args=(media,), daemon=True).start()
        except (EOFError, OSError):
            if not self.stopped:
                self.errors.append('provider control disconnected unexpectedly')
        except Exception as error:
            self.errors.append(repr(error))

    def pump(self, media):
        try:
            capture = False
            epoch = 0
            pcm = struct.pack('<h', 4000) * 480
            while True:
                if select.select([media], [], [], .01)[0]:
                    kind, payload = audio.lane(media)
                    if kind == 2:
                        capture = payload[0] != 0
                        epoch, _ = number(payload, 2)
                    elif kind == 1:
                        assert payload[8:] == pcm
                    else:
                        raise AssertionError(kind)
                if capture:
                    audio.message(media, struct.pack('<Q', epoch) + pcm)
        except (EOFError, OSError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            media.close()
            self.active = None
            self.ended.set()

    def close(self):
        self.stopped = True
        self.ready.set()
        self.stream.shutdown(socket.SHUT_RDWR)
        self.stream.close()
        self.worker.join(2)
        if self.media:
            try:
                self.media.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


DEVICE = r'''
import ctypes,os,socket,sys,threading,time,subprocess
path,mode=sys.argv[1:3]
if len(sys.argv)==3:
 sys.exit(subprocess.call([sys.executable,__file__,path,mode,'child'],start_new_session=True))
assert ctypes.CDLL(None).prctl(4,0,0,0,0)==0
opened=[]
def connect(direction):
 s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET);s.settimeout(10);s.connect(path)
 s.send(bytes([1,direction]));status=s.recv(1)
 if mode=='denied':
  assert status==b'\1',status; print('AUTO-DENIED',flush=True);return
 assert status==b'\0',status
 opened.append((direction,s));print('DEVICE-OPENED',flush=True)
if mode=='denied':
 connect(1);sys.exit(0)
workers=[threading.Thread(target=connect,args=(direction,)) for direction in (1,0)]
for worker in workers:worker.start()
for worker in workers:worker.join()
assert len(opened)==2
capture=dict(opened)[1];playback=dict(opened)[0]
if mode=='hold':
 print('AUTO-HOLDING',flush=True)
 assert capture.recv(1)==b''
 print('AUTO-REVOKED',flush=True)
else:
 capture.send(b'\1');playback.send(b'\1')
 data=capture.recv(960);assert data and any(data)
 playback.send(b'\2'+data)
 time.sleep(.05)
 capture.send(b'\0');playback.send(b'\0')
 print('AUTO-ROUNDTRIP-OK',flush=True)
for _,stream in opened:stream.close()
'''


def execute(pane, device, endpoint, mode):
    pane.buffer.clear()
    pane.send(f'{sys.executable} {device} {endpoint} {mode}\n'.encode())


def main():
    binaries = find_binaries()
    if binaries is None:
        return 2
    muxd, attach = binaries
    with tempfile.TemporaryDirectory(prefix='mux-auto-', dir='/tmp') as directory:
        root = Path(directory)
        local, remote = root/'local', root/'remote'
        second = root/'second'
        second.mkdir(mode=0o700)
        local.mkdir(mode=0o700)
        remote.mkdir(mode=0o700)
        env_local = sandbox_env(str(local), str(local/'mux.sock'), HISTFILE='/dev/null')
        env_remote = sandbox_env(str(remote), str(remote/'mux.sock'), HISTFILE='/dev/null')
        env_second = sandbox_env(str(second), str(second/'mux.sock'), HISTFILE='/dev/null')
        digests = [run([muxd,'client-digest'],env).stdout.strip() for env in (env_local,env_second)]
        (remote/'authorized').write_text('\n'.join(digests)+'\n')
        config = local/'.config/mux'
        config.mkdir(parents=True)
        (config/'hosts.json').write_text(json.dumps({'testbox':{'addr':'127.0.0.1:19483'}}))
        other_config = second/'.config/mux'
        other_config.mkdir(parents=True)
        (other_config/'hosts.json').write_text((config/'hosts.json').read_text())
        device = root/'device.py'
        device.write_text(DEVICE)
        endpoint = remote/'mux.sock.audio'
        with Daemon(muxd,str(remote),str(remote/'mux.sock'),env=env_remote,
                    extra_args=['--listen-quic','127.0.0.1:19483','--authorized-tokens',str(remote/'authorized'),'--audio']), \
             Daemon(muxd,str(local),str(local/'mux.sock'),env=env_local), \
             Daemon(muxd,str(second),str(second/'mux.sock'),env=env_second):
            pane = Pty([attach,'testbox:first-pane'],env_local)
            other = Pty([attach,'testbox:second-pane'],env_local)
            outsider = Pty([attach,'testbox:other-client'],env_second)
            provider = None
            try:
                pane.drain(.2)
                other.drain(.2)
                execute(pane, device, endpoint, 'denied')
                pane.expect(b'AUTO-DENIED',5,'unregistered host has no audio')
                provider = Provider(str(local/'mux.sock'))
                assert not provider.requests
                outsider.drain(.2)
                execute(outsider, device, endpoint, 'denied')
                outsider.expect(b'AUTO-DENIED',5,'another connection cannot use this Mac provider')
                assert not provider.requests
                # Hardware readiness gates BOTH concurrent opens, not just the first.
                provider.ready.clear()
                execute(pane, device, endpoint, 'roundtrip')
                assert provider.requested.wait(5)
                time.sleep(.15)
                pane.drain(.1)
                assert b'DEVICE-OPENED' not in pane.buffer
                provider.ready.set()
                pane.expect(b'AUTO-ROUNDTRIP-OK',8,'automatic hardened duplex audio')
                assert provider.ended.wait(3)
                assert len(provider.requests) == 1, provider.requests
                # No explicit sharing: a different pane can request the next lease.
                execute(other, device, endpoint, 'hold')
                other.expect(b'AUTO-HOLDING',5,'second pane automatically acquired audio')
                execute(pane, device, endpoint, 'denied')
                pane.expect(b'AUTO-DENIED',5,'active audio is not stolen')
                # A request from an old acquisition cannot reopen its media route.
                stale, reply = connect(str(local/'mux.sock'), audio.varint(13)+provider.requests[0][1])
                assert reply[0] == 1, reply
                stale.close()
                # Disabling the provider revokes even already opened devices.
                provider.close()
                other.expect(b'AUTO-REVOKED',5,'provider removal closes devices')
                assert not provider.errors, provider.errors
                provider = Provider(str(local/'mux.sock'))
                execute(pane, device, endpoint, 'roundtrip')
                pane.expect(b'AUTO-ROUNDTRIP-OK',8,'provider registration recovers automatically')
                assert provider.ended.wait(3)
                # Closing and replacing a pane does not require changing the provider.
                pane.kill()
                pane.close()
                pane = Pty([attach,'testbox:new-pane'],env_local)
                pane.drain(.2)
                execute(pane, device, endpoint, 'roundtrip')
                pane.expect(b'AUTO-ROUNDTRIP-OK',8,'new pane automatically acquired audio')
                assert provider.ended.wait(3)
                assert not provider.errors, provider.errors
                execute(pane, device, endpoint, 'hold')
                pane.expect(b'AUTO-HOLDING',5,'hold audio before attachment replacement')
                replacement = Pty([attach,'testbox:new-pane'],env_local)
                replacement.expect(b'AUTO-REVOKED',5,'replacement attachment revokes audio')
                assert provider.ended.wait(3)
                pane.kill()
                pane.close()
                pane = replacement
                provider.reject = True
                execute(pane, device, endpoint, 'denied')
                pane.expect(b'AUTO-DENIED',5,'hardware failure rejects device open')
                provider.reject = False
                execute(pane, device, endpoint, 'roundtrip')
                pane.expect(b'AUTO-ROUNDTRIP-OK',8,'hardware failure does not poison provider')
                assert provider.ended.wait(3)
                assert not provider.errors, provider.errors
                provider.close()
                provider = None
                pane.send(b'echo TERMINAL-STILL-ALIVE\n')
                pane.expect(b'TERMINAL-STILL-ALIVE',3,'terminal survives audio shutdown')
                print('PASS: automatic acquisition, readiness, hardened duplex, pane handoff, busy rejection, stale request rejection, revocation and re-registration')
            finally:
                if provider:
                    provider.close()
                pane.kill()
                pane.close()
                other.kill()
                other.close()
                outsider.kill()
                outsider.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
