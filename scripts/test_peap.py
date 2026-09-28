#!/usr/bin/env python3
"""Exercise the packaged Apple backend without touching a real interface."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile

try:
    socket.if_nametoindex("en999999")
except OSError:
    pass
else:
    raise AssertionError("Offline fixture interface unexpectedly exists")

helper = (Path(os.environ.get("INODE_APP_OUTPUT", "dist/iNode for Mac-arm64.app")) / "Contents/Resources/inode-helper").resolve()
with tempfile.TemporaryDirectory(prefix="inode-peap-offline-") as path:
    session = Path(path)
    os.chmod(session, 0o700)
    values = ["en999999", "synthetic-user@cm", "synthetic-password", "0", str(os.getpid()), "移动", "UTF-8"]
    credentials = session / "credentials"
    credentials.write_text("\n".join(values) + "\n")
    credentials.chmod(0o600)
    events = session / "events"
    events.touch(mode=0o600)
    result = subprocess.run([str(helper), "--peap-session", path], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=10)
    log = events.read_text()
    assert result.returncode == 1
    assert "高级认证后端 0.4.1" in log
    assert "macOS 未接受 PEAP 启动请求" in log
    assert "stopped\t" in log
    assert "authenticated\t" not in log
    assert "synthetic-user" not in log and "synthetic-password" not in log
    assert not credentials.exists()
    assert not (session / "runtime").exists()
print("Packaged Apple PEAP backend: nonexistent interface rejected, no credentials logged, cleanup passed")
