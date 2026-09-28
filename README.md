# iNode for Mac

西南财经大学宿舍有线网络认证客户端，使用 SwiftUI 编写。提供普通 iNode 认证和 macOS 有线 PEAP 认证，支持 Apple Silicon 与 Intel Mac，最低系统版本为 macOS 13。

普通认证调用 H3C Mac PC 7.3 (E0585) 引擎。此前本地 0.4.1 版本已在毅园移动宿舍网口由使用者确认连接成功；0.5.0 更新图标、界面文案和发行方式，尚未在其他宿舍网口或 Intel Mac 上现场验证。PEAP 是备选方式，目前也没有成功连接的现场验证。

0.5.1 起，点击窗口左上角红色关闭按钮（或使用“关闭窗口”命令）只会把窗口最小化到 Dock，不会结束应用或断开认证。点击 Dock 中的应用图标可恢复窗口。要真正退出，请使用菜单栏“iNode for Mac → 退出 iNode for Mac”（或 ⌘Q）；退出会结束当前有线认证会话。

## 下载与安装

从 [Releases](https://github.com/silenzio111/inode-for-mac/releases) 下载对应芯片的 ZIP：`arm64` 用于 M 系列芯片，`x86_64` 用于 Intel。解压后可将 `iNode for Mac.app` 移至“应用程序”。两个包分别包含对应架构的应用和辅助程序，并附带普通认证所需的 H3C Mac PC 7.3 (E0585) 原厂引擎及配套库；该引擎本身是 x86_64，因此 M 系列芯片使用普通认证还需要 [Rosetta 2](https://support.apple.com/102527)。

H3C 组件来自 [`helson-lin/iNode_Client_Sequoia`](https://github.com/helson-lin/iNode_Client_Sequoia) 的固定提交 `dd9ac3f26815c262a67a3e434bfaa2e6f178d510`。本项目的 GPL 许可仅覆盖自编源码，**不将 H3C 原厂组件声明为开源**；上游封装项目的 MIT 声明也不能替代原厂组件的权利归属。详情见 [THIRD_PARTY.md](THIRD_PARTY.md)。普通认证首次启动会请求管理员授权。公开包未经 Apple Developer ID 公证，首次打开可能需到“系统设置 → 隐私与安全性”允许。

已经使用旧版连接时，无须为更新图标断开网络；方便重新连接时再退出旧版并打开新版。

## 使用

选择已接入的有线网卡，输入学号与校园网密码。移动账号选择“移动（@cm）”，应用会在没有后缀时补全 `@cm`；若账号已有后缀，按原样提交。普通认证是本项目已经现场连通的方式。只有系统或原厂引擎报告校园网认证通过时，界面才标为“已通过”。

联网测试只请求 `https://www.google.com/generate_204` 和 `https://www.baidu.com/`。任一测试通过时，顶部显示“网络连接正常”，下方保留两个站点各自的结果。测试走系统当前网络路径，Wi-Fi 或隧道可能参与，因此网站可访问不等于证明流量经过所选网线。密码保存为可选项，使用 macOS 钥匙串；应用日志不记录明文账号、密码或原始认证报文。

## 从源码构建

在 macOS 与 Xcode Command Line Tools 环境中：

```sh
./scripts/create_icon.sh
INODE_ENGINE_DESTINATION="$PWD/.build/vendor-mac" ./scripts/install_engine.sh
./scripts/package_release.sh
```

`install_engine.sh` 从固定提交取得组件并在本地准备，不执行上游安装脚本。`package_release.sh` 将组件分别打入 ARM 与 Intel 应用包。如只需自行编译本项目源码、不打入第三方二进制，可使用 `INODE_INCLUDE_VENDOR=0 INODE_ARCH=arm64 ./scripts/build.sh`（Intel 改为 `x86_64`）；此时普通认证需要另行在本机安装组件。

```sh
./scripts/test.sh
./scripts/test_native.sh
INODE_APP_OUTPUT='dist/release/iNode for Mac-arm64.app' python3 scripts/test_peap.py
```

`test_native.sh` 默认只运行独立源码测试。若本机已有 `research/inode-modern` 和 `.build/vendor-mac`，且当前没有运行中的 iNode 认证会话，可设置 `INODE_TEST_VENDOR=1` 额外进行协议基线与离线管道检查。测试使用虚构凭据和不存在的网卡，不会对真实网口发起认证。

## 许可与来源

本项目源码按 [GPL-3.0-or-later](LICENSE) 发布。普通认证报文布局参考的项目与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。H3C 原厂引擎及库有独立权利归属，不属于本仓库许可证；它们不纳入源码仓库，但包含于发行包。
