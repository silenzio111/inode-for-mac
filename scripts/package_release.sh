#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="0.5.0"
mkdir -p dist/release
for arch in arm64 x86_64; do
    app="$PWD/dist/release/iNode for Mac-${arch}.app"
    INODE_ARCH="$arch" INODE_INCLUDE_VENDOR=0 INODE_APP_OUTPUT="$app" ./scripts/build.sh
    stage="$PWD/.build/release-${arch}"
    rm -rf "$stage"
    mkdir -p "$stage/scripts"
    cp -R "$app" "$stage/iNode for Mac.app"
    cp scripts/install_engine.sh "$stage/scripts/install_engine.sh"
    cp scripts/prepare_vendor.py "$stage/scripts/prepare_vendor.py"
    cat > "$stage/Install Engine.command" <<'INSTALL'
#!/bin/zsh
cd "${0:A:h}"
./scripts/install_engine.sh
INSTALL
    chmod +x "$stage/Install Engine.command" "$stage/scripts/install_engine.sh"
    cat > "$stage/README.txt" <<'NOTES'
iNode for Mac 0.5.0

此应用提供 macOS 有线 PEAP 认证和普通 iNode 认证界面。
普通认证需要 H3C 原厂组件，公开发行包没有附带该第三方二进制。
如需普通认证，请先联网，双击 Install Engine.command；脚本会从上游项目
取得固定版本，在这台 Mac 上准备组件，不会把组件放进公开发行包。
安装脚本需要 Xcode Command Line Tools。Apple Silicon 使用普通认证还需要 Rosetta 2。
安装后打开 iNode for Mac.app。组件只安装到当前用户的 Application Support 目录。
发行包未经 Apple Developer ID 公证，首次打开可能需要在“隐私与安全性”中允许。
源码、许可和详细说明：https://github.com/silenzio111/inode-for-mac
NOTES
    archive="$PWD/dist/release/iNode-for-Mac-${version}-${arch}.zip"
    (cd "$stage" && /usr/bin/zip -qry "$archive" "iNode for Mac.app" "Install Engine.command" scripts README.txt)
    echo "已生成：$archive"
done
