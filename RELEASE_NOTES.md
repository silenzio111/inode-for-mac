## 0.7.3 beta 1

修复原厂认证引擎启动时偶发的“控制接口未就绪”：应用现在持续等待双向命名管道建立和读取端就绪，最长 40 秒。若仍失败，连接日志会区分引擎提前退出、回执管道超时、命令管道超时或两条管道均未就绪，便于继续排查。自动重试及认证协议本身不变。

提供 Apple Silicon（`arm64`）与 Intel（`x86_64`）两个安装包，均包含 H3C Mac E0585 原厂认证组件。Apple Silicon 的普通认证需要 Rosetta 2。组件来源及独立权利归属见 [THIRD_PARTY.md](https://github.com/silenzio111/inode-for-mac/blob/main/THIRD_PARTY.md)；应用未经 Apple Developer ID 公证。

双架构构建与签名检查、认证辅助组件和延迟管道就绪测试均已通过。此版尚未在宿舍网口现场验证；正在运行的旧版不会自动替换。
