#!/usr/bin/env python3
"""Probe local IPC. Optional connect uses synthetic credentials and an absent NIC."""
import argparse
import errno
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'research/inode-modern'))
from inode_modern.protocol import Message, STATUS_REQUEST

parser = argparse.ArgumentParser()
parser.add_argument('--offline-connect', action='store_true')
args = parser.parse_args()
base = root / '.build/vendor-mac'
metadata = json.loads((base / 'source.json').read_text())
source = metadata['source']
connect = None
if args.offline_connect:
    connect = (root / f'.build/native-offline-{source}.bin').read_bytes()
    request = Message.decode(connect)
    fields = {f.kind: f.value for f in request.tlvs}
    assert request.kind == 1
    assert fields[1] == b'synthetic-user' and fields[2] == b'synthetic-password'
    assert fields[7] == b'en999999'
    try:
        socket.if_nametoindex('en999999')
    except OSError:
        pass
    else:
        raise RuntimeError('Offline test interface exists; refusing to connect')

with tempfile.TemporaryDirectory(prefix='inode-ipc-probe-') as folder:
    runtime = Path(folder) / 'runtime'
    shutil.copytree(base, runtime, symlinks=True,
                    ignore=shutil.ignore_patterns('log', 'ipc-node'))
    runtime.chmod(0o700)
    (runtime / 'log').mkdir(mode=0o700)
    (runtime / 'ipc-node').mkdir(mode=0o700)
    (runtime / 'inodesys.conf').write_text(f'INSTALL_DIR={runtime}\n')
    proc = subprocess.Popen([str(runtime / 'AuthenMngService')], cwd=runtime,
                            env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                                 'DYLD_LIBRARY_PATH': str(runtime / 'lib')},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rx = tx = -1
    sequence = 0
    pending = bytearray()

    def send(payload):
        global sequence
        header = struct.pack('<B3xI32sII', 1, sequence,
                             b'./ipc-node/iNodeClient', 3, len(payload))
        sequence += 1
        assert os.write(tx, header + payload) == len(header) + len(payload)

    def wait_for(kind, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError('Engine exited during IPC probe')
            if select.select([rx], [], [], min(.2, max(0, deadline-time.monotonic())))[0]:
                pending.extend(os.read(rx, 8192))
            while len(pending) >= 48:
                typ, seq, path, module, size = struct.unpack('<B3xI32sII', pending[:48])
                assert typ in (0, 1) and size <= 32768
                if len(pending) < 48 + size:
                    break
                payload = bytes(pending[48:48+size])
                del pending[:48+size]
                if module == 3 and len(payload) >= 12 and payload[8] == kind:
                    return Message.decode(payload)
        raise RuntimeError(f'No IPC reply of type {kind}')

    try:
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                tx = os.open(runtime / 'ipc-node/iNodeCmn', os.O_WRONLY | os.O_NONBLOCK)
                break
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.ENXIO):
                    raise
            if proc.poll() is not None:
                raise RuntimeError('Engine exited before pipe became ready')
            time.sleep(.1)
        if tx < 0:
            raise RuntimeError('Engine pipe readiness timed out')
        rx = os.open(runtime / 'ipc-node/iNodeClient', os.O_RDWR | os.O_NONBLOCK)
        # Exercise the helper's actual order: connect immediately, then status.
        if connect is not None:
            send(connect)
            ack = wait_for(2)
            assert not ack.tlvs
            print(f'{source}: connection request accepted for absent interface (ACK 2); no campus authentication')
        send(Message(STATUS_REQUEST).encode())
        response = wait_for(8)
        print('Status reply:', response.safe_summary())
    finally:
        if tx >= 0:
            try:
                send(Message(3).encode())
            except OSError:
                pass
            os.close(tx)
        if rx >= 0:
            os.close(rx)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
