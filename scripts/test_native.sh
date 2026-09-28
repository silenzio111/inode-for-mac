#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
xcrun swiftc Sources/AccountFormat.swift tests/account-format.swift -o .build/account-format-tests
.build/account-format-tests
xcrun clang -fsanitize=address,undefined -g Sources/AppleEAP.c tests/apple-eap.c -framework CoreFoundation -o .build/apple-eap-tests
.build/apple-eap-tests
xcrun clang -fsanitize=address,undefined -g Sources/NativeIPC.c Sources/VendorNotice.c Sources/EAPTrace.c tests/native-ipc.c -liconv -lpcap -o .build/native-ipc-tests
.build/native-ipc-tests
if [[ "${INODE_TEST_VENDOR:-0}" == 1 && -d research/inode-modern && -f .build/vendor-mac/AuthenMngService ]]; then
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,'research/inode-modern')
from inode_modern.protocol import connect_request,Message,TLV
baseline=connect_request('synthetic-user','synthetic-password','en8')
for source,offset in [('school',0),('sequoia',18)]:
 expected=Message(baseline.kind,tuple(TLV(f.kind+offset,f.value) if f.kind in (30,31,32) else f for f in baseline.tlvs)).encode()
 assert Path(f'.build/native-connect-{source}.bin').read_bytes()==expected
 Path(f'.build/native-connect-{source}.bin').unlink()
print('connect payload matches Linux CLI exactly after verified Mac option-ID mapping; no option-value overrides')
PY
python3 scripts/probe_vendor_pipe.py --offline-connect
rm .build/native-offline-school.bin .build/native-offline-sequoia.bin
else
    rm -f .build/native-offline-school.bin .build/native-offline-sequoia.bin
    echo "跳过原厂引擎对照；需明确设置 INODE_TEST_VENDOR=1"
fi
