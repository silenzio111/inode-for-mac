# 参考资料与许可

本项目使用 GPL-3.0-or-later 发布（完整许可见 LICENSE）。H3C EAP Identity、Notification、客户端版本双向 XOR 编码与账号/密码响应的报文布局，参考 njit8021xclient 系列公开实现；认证组件为针对 macOS libpcap 编写的实现。

公开发行包不包含 H3C 原厂可执行文件、动态库、学校安装包或从第三方项目提取的原厂资源。`Install Engine.command` 由用户在本机运行，从上游项目取得固定提交并在本机准备组件。Apple Silicon 上的普通认证通过 Rosetta 2 运行原厂 x86_64 引擎；本项目自己的界面和辅助程序分别编译为 arm64 与 x86_64。

- 刘群及 njit8021xclient 贡献者：https://github.com/liuqun/njit8021xclient
- bitdust/njit8021xclient：https://github.com/bitdust/njit8021xclient
- zhyaof/njit-client_for_sysu：https://github.com/zhyaof/njit-client_for_sysu
- c3h_client 的 GPLv3 许可文本：https://github.com/KiritoA/c3h_client/blob/master/LICENSE

不包含 c3h 的漏洞利用或无效报文保活实现，不包含第三方客户端完整性字典。

学校公开资料：
- 客户端下载：https://info.swufe.edu.cn/info/1027/2411.htm
- 新版认证说明：https://info.swufe.edu.cn/info/1024/2491.htm
- 学生公寓说明：https://id.swufe.edu.cn/yx2023.pdf

学校 Linux 包中的 custom/iNodeCustom.xml 指示上传客户端版本/IP、单播响应。官方包用于本地研究，未打包进本应用。

0.2.0 原厂引擎后端：
- IPC TLV 载荷与西财选项顺序参考 qfzlm/inode-modern（MIT）：https://github.com/qfzlm/inode-modern 。许可完整文本附在 licenses/inode-modern-MIT.txt。
- Mac 命名管道帧由学校原厂组件的控制接口独立核对，并以无凭据状态查询验证。
- H3C Mac 原厂引擎与库是第三方 proprietary software。本机由学校官方客户端下载包提取，用于用户的本地适配；不受本仓库 GPL/MIT 许可覆盖，不应作为公开发布包重新分发。
0.3.0 Sequoia 引擎后端：
- 用户指定的项目：https://github.com/helson-lin/iNode_Client_Sequoia ，提交 dd9ac3f26815c262a67a3e434bfaa2e6f178d510。
- 使用其 PC 7.3 (E0585) 原厂引擎、完整配套库、custom 与提示资源，在应用私有目录运行；没有覆盖系统库目录或执行 preinstall/postinstall。
- 仓库的封装脚本标为 MIT，但其中 H3C 原厂二进制不因此变为 MIT；仅作为用户本机适配组件使用，不公开再分发。
- 版本与原始文件摘要记录在打包资源 vendor-mac/source.json。
- 0.3.1 根据两版 Mac 库内置参数字典分别编码本地 IPC 字段：E0524 的 QUICK_RESUME/REAUTH_TIMES/REAUTH_INTERVAL 为 30/31/32，E0585 为 48/49/50。未改动引擎认证算法。
- 0.3.2 的移动 @cm 账号格式来源于用户提供的西财电脑义务维修队教程 Mac 部分，及学校 Mac 安装指导；教程未再分发。未修改原厂 PAP 密码处理或联网报文算法。

0.4.0 macOS PEAP 后端：
- 用户提供的教程第 18、20 页指定毅园使用的高级认证为 PEAP，内层自动；教程文本及截图不随应用再分发。
- Apple 对有线 PEAP 的支持说明：https://support.apple.com/guide/deployment/depabc994b84/web 。
- EAPOLControl API/属性与状态数字参考 Apple 的公开源码：https://github.com/apple-oss-distributions/eap8021x 。AppleEAP.c 是自行编写的调用层，仅加载已随 macOS 安装的框架；没有复制、修改或分发 Apple 的实现。

0.4.1 Linux 基线核对：
- 普通模式恢复 qfzlm/inode-modern 的 TAKE_VERSION=1，保留 TAKE_IP=0，仅对 E0585 映射恢复/重试字段编号。连接载荷通过合成数据与原项目逐字节对照。
- 原厂版本字段仍由 Mac 引擎自身生成，不复制或伪造 Linux 版本。
