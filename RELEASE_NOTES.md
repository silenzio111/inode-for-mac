## 0.7.4 beta 1

点击窗口左上角红色关闭按钮现在会隐藏主窗口，只保留菜单栏图标，认证连接继续运行。通过菜单栏的“打开主界面”可恢复窗口；黄色最小化按钮仍按系统方式将窗口留在 Dock。若在应用设置中开启 Dock 图标，关闭主窗口时也会暂时隐藏该图标，重新打开窗口后恢复设置。

修复授权流程结束时可能重新弹出已主动关闭的主窗口。认证协议与后台服务没有变化。

提供 Apple Silicon（`arm64`）与 Intel（`x86_64`）两个安装包，均包含 H3C Mac E0585 原厂认证组件。Apple Silicon 的普通认证需要 Rosetta 2。组件来源及独立权利归属见 [THIRD_PARTY.md](https://github.com/silenzio111/inode-for-mac/blob/main/THIRD_PARTY.md)；应用未经 Apple Developer ID 公证。

已通过窗口关闭与最小化测试、完整本地测试及双架构构建。此版尚未在宿舍网口现场验证；正在运行的旧版不会自动替换。
