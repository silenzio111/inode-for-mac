#!/usr/bin/env python3
"""Cold-start/status probe only. Never sends CONNECT or credentials."""
import subprocess, socket, time, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'research/inode-modern'))
from inode_modern.protocol import Message, STATUS_REQUEST
base=Path(__file__).resolve().parents[1]/'.build/vendor-mac'
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('127.0.0.1',50000));sock.settimeout(.5)
proc=subprocess.Popen([str(base/'AuthenMngService')],cwd=base,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
 for _ in range(12):
  if proc.poll() is not None: print('Engine exited:',proc.returncode);break
  sock.sendto(Message(STATUS_REQUEST).encode(),('127.0.0.1',50001))
  try:
   data,peer=sock.recvfrom(65535)
   if peer!=('127.0.0.1',50001): continue
   print('Engine reply:',Message.decode(data).safe_summary());break
  except TimeoutError: pass
 else: print('No UDP status response')
finally:
 proc.terminate()
 try: proc.wait(timeout=3)
 except subprocess.TimeoutExpired: proc.kill();proc.wait()
 sock.close()
