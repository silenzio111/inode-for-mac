## iNode for Mac 0.5.0 测试版

- 新增应用图标，移除侧栏底部的引擎、芯片和实现说明。
- 分别提供 Apple Silicon（`arm64`）和 Intel（`x86_64`）原生应用。保留现有认证流程；Google 或百度任一网站测试通过时，顶部显示“网络连接正常”。
- 两个包均包含来自 `helson-lin/iNode_Client_Sequoia` 固定提交 `dd9ac3f26815c262a67a3e434bfaa2e6f178d510` 的 H3C Mac E0585 引擎及配套库。H3C 组件的权利归属独立于本项目的 GPL 源码许可，详见发行包中的 `THIRD_PARTY.md`。M 系列芯片使用普通认证还需要 Rosetta 2。
- 应用使用临时签名，未经 Apple Developer ID 公证；首次打开可能需要到“隐私与安全性”中允许。

此前的本地普通认证版本已由使用者在一处西财宿舍网口成功连接。本次版本通过源码测试、双架构签名检查和两种架构的离线 PEAP 测试；发行 ZIP 与 Intel 机器上的实际校园网连接尚未现场验证。安装、许可和限制见 [README.md](README.md)。
