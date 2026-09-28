#!/usr/bin/env python3
"""Exercise the persistent broker with invalid, synthetic sessions only."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

helper = Path('.build/broker-test-helper').resolve()
with tempfile.TemporaryDirectory(prefix='inode-broker-test-') as root:
    base = Path(root)
    control = base / 'control'
    control.mkdir(mode=0o700)
    process = subprocess.Popen([str(helper), '--broker', str(control), str(os.getpid())],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5
        while not (control / 'ready').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert (control / 'ready').exists() and process.poll() is None
        for number in range(2):
            session = base / f'session-{number}'
            session.mkdir(mode=0o700)
            temporary = control / f'.request-{number}'
            temporary.write_text(str(session) + '\n')
            temporary.chmod(0o600)
            temporary.rename(control / 'request')
            deadline = time.monotonic() + 5
            while (control / 'request').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            assert not (control / 'request').exists()
            assert process.poll() is None, 'Broker should survive a failed child session'
        (control / 'quit').touch(mode=0o600)
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
print('Persistent privilege broker reused for two synthetic requests and shut down cleanly')
