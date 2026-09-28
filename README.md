# iNode for Mac

西南财经大学宿舍有线网络认证客户端，使用 SwiftUI 编写。提供普通 iNode 认证和 macOS 有线 PEAP 认证，支持 Apple Silicon 与 Intel Mac，最低系统版本为 macOS 13。

普通认证调用 H3C Mac PC 7.3 (E0585) 引擎。此前本地 0.4.1 版本已在毅园移动宿舍网口由使用者确认连接成功；0.5.0 更新图标、界面文案和发行方式，尚未在其他宿舍网口或 Intel Mac 上现场验证。PEAP 是备选方式，目前也没有成功连接的现场验证。

## 下载与安装

从 [Releases](https://github.com/silenzio111/inode-for-mac/releases) 下载对应芯片的 ZIP：`arm64` 用于 M 系列芯片，`x86_64` 用于 Intel。解压后可将 `iNode for Mac.app` 移至“应用程序”。两个包分别包含对应架构的应用和辅助程序，普通认证所需的原厂引擎本身是 x86_64，因此 M 系列芯片使用普通认证还需要 [Rosetta 2](https://support.apple.com/102527)。

**公开发行包不附带 H3C 原厂二进制。**需要普通认证时，请先通过其他网络联网，在解压目录运行 `Install Engine.command`。该脚本从 [`helson-lin/iNode_Client_Sequoia`](https://github.com/helson-lin/iNode_Client_Sequoia) 取得固定提交 `dd9ac3f26815c262a67a3e434bfaa2e6f178d510`，只在当前 Mac 的 `~/Library/Application Support/iNode for Mac/vendor-mac` 准备组件。安装脚本需要 Xcode Command Line Tools；macOS 若提示缺少开发者工具，请先安装。普通认证首次启动会请求管理员授权。公开包未经 Apple Developer ID 公证，首次打开可能需到“系统设置 → 隐私与安全性”允许。

已经使用旧版连接时，无须为更新图标断开网络；方便重新连接时再退出旧版并打开新版。

## 使用

选择已接入的有线网卡，输入学号与校园网密码。移动账号选择“移动（@cm）”，应用会在没有后缀时补全 `@cm`；若账号已有后缀，按原样提交。普通认证是本项目已经现场连通的方式。只有系统或原厂引擎报告校园网认证通过时，界面才标为“已通过”。

联网测试只请求 `https://www.google.com/generate_204` 和 `https://www.baidu.com/`。任一测试通过时，顶部显示“网络连接正常”，下方保留两个站点各自的结果。测试走系统当前网络路径，Wi-Fi 或隧道可能参与，因此网站可访问不等于证明流量经过所选网线。密码保存为可选项，使用 macOS 钥匙串；应用日志不记录明文账号、密码或原始认证报文。

## 从源码构建

在 macOS 与 Xcode Command Line Tools 环境中：

```sh
./scripts/create_icon.sh
INODE_INCLUDE_VENDOR=0 INODE_ARCH=arm64 ./scripts/build.sh
INODE_INCLUDE_VENDOR=0 INODE_ARCH=x86_64 ./scripts/build.sh
./scripts/package_release.sh
```

`INODE_INCLUDE_VENDOR=0` 生成与公开发行包相同的无原厂二进制应用。普通认证在本机运行 `./scripts/install_engine.sh` 后使用。若已合法取得并在 `.build/vendor-mac` 准备了本地原厂组件，默认 `./scripts/build.sh` 可以制作仅供本机使用的自带组件构建；请勿公开分发该包。

```sh
./scripts/test.sh
./scripts/test_native.sh
INODE_APP_OUTPUT='dist/release/iNode for Mac-arm64.app' python3 scripts/test_peap.py
```

`test_native.sh` 默认只运行独立源码测试。若本机已有 `research/inode-modern` 和 `.build/vendor-mac`，且当前没有运行中的 iNode 认证会话，可设置 `INODE_TEST_VENDOR=1` 额外进行协议基线与离线管道检查。测试使用虚构凭据和不存在的网卡，不会对真实网口发起认证。

## 许可与来源

本项目源码按 [GPL-3.0-or-later](LICENSE) 发布。普通认证报文布局参考的项目与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。H3C 原厂引擎及库有独立权利归属，不属于本仓库许可证，也不包含在公开仓库和发行包内。
