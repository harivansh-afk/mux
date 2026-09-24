#!/usr/bin/env python3
"""Native audio through two real daemons and the existing terminal connection.
No physical devices, account, or provider. All state is private and temporary.
"""
import json
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from muxd_harness import Daemon, Pty, find_binaries, run, sandbox_env

VERSION = 12

def varint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out) + bytes([value])

def string(value):
    encoded = value.encode()
    return varint(len(encoded)) + encoded

def read_exact(stream, length):
    result = bytearray()
    while len(result) < length:
        part = stream.recv(length - len(result))
        if not part:
            raise EOFError('audio channel closed')
        result.extend(part)
    return bytes(result)

def lane(stream):
    length, = struct.unpack('<I', read_exact(stream, 4))
    assert 1 <= length <= 1048576
    payload = read_exact(stream, length)
    return payload[0], payload[1:]

def message(stream, payload):
    stream.sendall(struct.pack('<I', len(payload)) + payload)

def driver(control, pane):
    stream = socket.socket(socket.AF_UNIX)
    stream.settimeout(5)
    stream.connect(control)
    # OpenRequest: v12, no grid/term/token, target=testbox, Audio{name}.
    message(stream, varint(VERSION) + b'\0\0\0\0\1' + string('testbox') + varint(11) + string(pane))
    kind, reply = lane(stream)
    assert kind == 0 and reply[:2] == b'\0\x09', reply
    stream.settimeout(2)
    return stream

DEVICE = r'''
import socket,sys,time,select
path=sys.argv[1]
def connect(direction):
 s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET);s.settimeout(3);s.connect(path)
 s.send(bytes([1,direction]));assert s.recv(1)==b'\0';s.send(b'\1');return s
capture,playback=connect(1),connect(0)
data=capture.recv(960);assert data and any(data)
playback.send(b'\2'+data)
capture.send(b'\0');playback.send(b'\0');capture.close();playback.close()
print('AUDIO-ROUNDTRIP-OK',flush=True)
'''

def main():
    binaries = find_binaries()
    if binaries is None: return 2
    muxd, attach = binaries
    with tempfile.TemporaryDirectory(prefix='mux-audio-', dir='/tmp') as directory:
        root = Path(directory); local = root/'local'; remote = root/'remote'
        local.mkdir(mode=0o700); remote.mkdir(mode=0o700)
        env_local = sandbox_env(str(local), str(local/'mux.sock'))
        env_remote = sandbox_env(str(remote), str(remote/'mux.sock'))
        digest = run([muxd,'client-digest'],env_local).stdout.strip()
        (remote/'authorized').write_text(digest+'\n')
        config = local/'.config/mux'; config.mkdir(parents=True)
        (config/'hosts.json').write_text(json.dumps({'testbox':{'addr':'127.0.0.1:19481'}}))
        device = root/'device.py';device.write_text(DEVICE)
        with Daemon(muxd,str(remote),str(remote/'mux.sock'),env=env_remote,
                    extra_args=['--listen-quic','127.0.0.1:19481','--authorized-tokens',str(remote/'authorized'),'--audio']), \
             Daemon(muxd,str(local),str(local/'mux.sock'),env=env_local):
            pane = Pty([attach,'testbox:audio-pane'],env_local)
            other = Pty([attach,'testbox:other-pane'],env_local)
            try:
                pane.drain(.2);other.drain(.2)
                stream = driver(str(local/'mux.sock'),'audio-pane')
                count_before=(remote/'muxd.log').read_text().count('quic client connected')
                assert count_before >= 1
                # An unrelated process cannot impersonate the pane using this socket.
                outsider=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET)
                outsider.connect(str(remote/'mux.sock.audio'));outsider.send(b'\1\1')
                assert outsider.recv(1)==b'\1';outsider.close()
                pane.send(f'{sys.executable} {device} {remote}/mux.sock.audio\n'.encode())
                capture=False; epoch=0; received=False; ended=False; deadline=time.monotonic()+8
                pcm=struct.pack('<h',4000)*480
                while time.monotonic()<deadline:
                    if select.select([stream],[],[],.01)[0]:
                        kind,payload=lane(stream)
                        if kind==2:
                            assert len(payload)>=4
                            capture=payload[0]!=0
                            epoch=payload[2]
                            ended=received and payload[:2]==b'\0\0'
                        elif kind==1:
                            assert payload[8:]==pcm;received=True
                        else: raise AssertionError(kind)
                    if capture: message(stream,struct.pack('<Q',epoch)+pcm)
                    if ended: break
                assert received and ended, 'audio or stop notification missing'
                pane.expect(b'AUDIO-ROUNDTRIP-OK',5,'audio device roundtrip')
                assert (remote/'muxd.log').read_text().count('quic client connected') == count_before
                # The lease belongs to one pane, not to keyboard focus or the host.
                other.send(f'{sys.executable} {device} {remote}/mux.sock.audio\n'.encode())
                other.expect(b'AssertionError',5,'other pane denied audio')
                stream.close()
                pane.send(b'echo TERMINAL-STILL-ALIVE\n')
                pane.expect(b'TERMINAL-STILL-ALIVE',5,'terminal after audio disconnect')
                print('PASS: native capture/playback, same QUIC connection, stop, PID binding and pane isolation')
            finally:
                pane.kill();pane.close();other.kill();other.close()
    return 0

if __name__=='__main__': sys.exit(main())
