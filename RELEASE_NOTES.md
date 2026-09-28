## iNode for Mac 0.5.1 测试版

- 点击红色关闭按钮或使用“关闭窗口”命令时，窗口会最小化到 Dock，应用和校园网认证会话继续运行；点击 Dock 图标可恢复窗口。使用应用菜单中的“退出 iNode for Mac”或 ⌘Q 才会退出并断开认证。
- 保留 0.5.0 的应用图标与简洁侧栏，分别提供 Apple Silicon（`arm64`）和 Intel（`x86_64`）原生应用。Google 或百度任一网站测试通过时，顶部显示“网络连接正常”。
- 两个包均包含来自 `helson-lin/iNode_Client_Sequoia` 固定提交 `dd9ac3f26815c262a67a3e434bfaa2e6f178d510` 的 H3C Mac E0585 引擎及配套库。H3C 组件的权利归属独立于本项目的 GPL 源码许可，详见发行包中的 `THIRD_PARTY.md`。M 系列芯片使用普通认证还需要 Rosetta 2。
- 应用使用临时签名，未经 Apple Developer ID 公证；首次打开可能需要到“隐私与安全性”中允许。

此前的本地普通认证版本已由使用者在一处西财宿舍网口成功连接。本次版本通过源码测试、双架构签名检查和两种架构的离线 PEAP 测试；发行 ZIP 与 Intel 机器上的实际校园网连接尚未现场验证。安装、许可和限制见 [README.md](README.md)。
