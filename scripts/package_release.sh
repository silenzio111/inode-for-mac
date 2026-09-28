#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="0.7.4"
mkdir -p dist/release
python3 - <<'VERIFY'
import json
from pathlib import Path
meta=json.loads(Path('.build/vendor-mac/source.json').read_text())
assert meta['source']=='sequoia'
assert meta['commit']=='dd9ac3f26815c262a67a3e434bfaa2e6f178d510'
assert meta['ipc_profile']==1 and 'E0585' in meta['version']
VERIFY
for arch in arm64 x86_64; do
    app="$PWD/dist/release/iNode for Mac-${arch}.app"
    INODE_ARCH="$arch" INODE_INCLUDE_VENDOR=1 INODE_APP_OUTPUT="$app" ./scripts/build.sh
    stage="$PWD/.build/release-${arch}"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$app" "$stage/iNode for Mac.app"
    cp LICENSE THIRD_PARTY.md "$stage/"
    cp licenses/sequoia-MIT.txt "$stage/UPSTREAM-MIT-LICENSE.txt"
    cat > "$stage/README.txt" <<'NOTES'
iNode for Mac 0.7.4

红色关闭按钮现在隐藏主窗口，认证服务继续在菜单栏运行；黄色最小化按钮才将窗口留在 Dock。
此应用包含普通 iNode 认证所需的 H3C Mac E0585 引擎和配套库，来源于
helson-lin/iNode_Client_Sequoia 固定提交 dd9ac3f26815c262a67a3e434bfaa2e6f178d510。
应用自身源码按 GPL-3.0-or-later 发布；第三方组件有独立权利归属，
请阅读 THIRD_PARTY.md。上游封装项目的 MIT 许可见 UPSTREAM-MIT-LICENSE.txt。
Apple Silicon 使用普通认证还需要 Rosetta 2。
解压后先将 iNode for Mac.app 移至“应用程序”目录再打开；普通认证每次启动后的首次连接会请求管理员授权。
保持应用运行时，手动重连与自动重试复用已授权组件，不再重复弹窗。
认证通过后每约 2 秒检查有线 IP；取得地址后再测试 Google 和百度。
默认只在菜单栏显示图标；点击图标可打开主界面或退出。红色关闭按钮隐藏主窗口，黄色最小化按钮将窗口留在 Dock。
可选开机自启；本机加密保存账号密码后可在启动时使用上次配置自动连接。
从旧版升级时需重新输入一次密码；新版不会自动读取旧钥匙串记录。
连接中断后默认自动重试 3 次，可在主界面设为 0–10 次。
发行包未经 Apple Developer ID 公证，首次打开可能需要在“隐私与安全性”中允许。
源码、许可和详细说明：https://github.com/silenzio111/inode-for-mac
NOTES
    archive="$PWD/dist/release/iNode-for-Mac-${version}-${arch}.zip"
    rm -f "$archive"
    (cd "$stage" && /usr/bin/zip -qry "$archive" "iNode for Mac.app" README.txt LICENSE THIRD_PARTY.md UPSTREAM-MIT-LICENSE.txt)
    echo "已生成：$archive"
done
(cd dist/release && shasum -a 256 iNode-for-Mac-${version}-arm64.zip iNode-for-Mac-${version}-x86_64.zip > SHA256SUMS.txt)
