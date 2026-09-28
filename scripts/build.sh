#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
arch="${INODE_ARCH:-$(uname -m)}"
if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
    echo "INODE_ARCH must be arm64 or x86_64" >&2
    exit 1
fi
app="${INODE_APP_OUTPUT:-$PWD/dist/iNode for Mac-${arch}.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
include_vendor="${INODE_INCLUDE_VENDOR:-1}"
if [[ "$include_vendor" == 1 && ! -f .build/vendor-mac/AuthenMngService ]]; then
    echo "缺少原厂 Mac 组件，请先运行 python3 scripts/prepare_vendor.py" >&2
    exit 1
fi
rm -rf "$app/Contents/Resources/vendor-mac"
if [[ "$include_vendor" == 1 ]]; then
python3 - "$app/Contents/Resources/vendor-mac" <<'PYCOPY'
from pathlib import Path
import shutil,sys
src=Path('.build/vendor-mac');dst=Path(sys.argv[1])
shutil.copytree(src,dst,symlinks=True,ignore=shutil.ignore_patterns('log','ipc-node'))
(dst/'log').mkdir();(dst/'ipc-node').mkdir()
(dst/'inodesys.conf').write_text('INSTALL_DIR=.\n')
PYCOPY
fi
xcrun clang -arch "$arch" -mmacosx-version-min=13.0 -O2 -Wall -Wextra Sources/NativeIPC.c Sources/VendorNotice.c Sources/EAPTrace.c Sources/AppleEAP.c Sources/VendorHelper.c -framework CoreFoundation -liconv -lpcap -o "$app/Contents/Resources/inode-helper"

xcrun swiftc -swift-version 5 -O -target "${arch}-apple-macos13.0" -parse-as-library Sources/AccountFormat.swift Sources/WindowCloseBehavior.swift Sources/App.swift -o "$app/Contents/MacOS/InodeMac"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/PROJECT-LICENSE.txt"
cp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"
cp licenses/sequoia-MIT.txt "$app/Contents/Resources/UPSTREAM-MIT-LICENSE.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>iNode for Mac</string>
<key>CFBundleDisplayName</key><string>iNode for Mac</string>
<key>CFBundleIdentifier</key><string>local.swufe.inode-mac</string>
<key>CFBundleExecutable</key><string>InodeMac</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>18</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Resources/inode-helper"
codesign --force --sign - "$app"
echo "已生成：$app"
