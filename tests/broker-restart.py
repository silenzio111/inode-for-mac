#!/usr/bin/env python3
"""Verify that exec-based restart keeps the authorized broker attached to its parent."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

helper = Path('.build/broker-test-helper').resolve()

def wait_for(path, present=True):
    deadline = time.monotonic() + 5
    while path.exists() != present and time.monotonic() < deadline:
        time.sleep(0.05)
    assert path.exists() == present, f'timed out waiting for {path}'

if len(sys.argv) == 1:
    with tempfile.TemporaryDirectory(prefix='inode-broker-restart-test-') as root:
        result = subprocess.run([sys.executable, __file__, 'before', root],
                                capture_output=True, text=True, timeout=12)
        assert result.returncode == 0, result.stdout + result.stderr
        print(result.stdout.strip())
elif sys.argv[1] == 'before':
    root = Path(sys.argv[2])
    control = root / 'control'
    control.mkdir(mode=0o700)
    broker = subprocess.Popen([str(helper), '--broker', str(control), str(os.getpid())],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(control / 'ready')
    assert broker.poll() is None
    os.execv(sys.executable, [sys.executable, __file__, 'after', str(root),
                             str(os.getpid()), str(broker.pid)])
elif sys.argv[1] == 'after':
    root = Path(sys.argv[2])
    parent_pid, broker_pid = map(int, sys.argv[3:5])
    assert os.getpid() == parent_pid
    os.kill(broker_pid, 0)
    control = root / 'control'
    session = root / 'session'
    session.mkdir(mode=0o700)
    request = control / '.request-new'
    request.write_text(str(session) + '\n')
    request.chmod(0o600)
    request.rename(control / 'request')
    wait_for(control / 'request', present=False)
    (control / 'quit').touch(mode=0o600)
    waited, status = os.waitpid(broker_pid, 0)
    assert waited == broker_pid and os.waitstatus_to_exitcode(status) == 0
    print('Authorized broker survived process replacement and accepted a new request')
