#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
xcrun clang -g -fsanitize=address,undefined -Wno-deprecated-declarations Sources/Protocol.c tests/protocol.c -liconv -o .build/protocol-tests
.build/protocol-tests
python3 - <<'PY'
import hashlib
from pathlib import Path
assert Path('.build/md5-result').read_bytes() == hashlib.md5(bytes([42])+b'secret'+bytes(range(16))).digest()
Path('.build/md5-result').unlink()
print('independent MD5 verification passed')
PY
