# 平台实现层

本目录是 NetFleet 跨平台实现层的当前 owner。文档分三层，每层只有一个 owner：

| 层 | 回答的问题 | owner |
| --- | --- | --- |
| 功能规划 | 提供哪些能力、为什么、哪些平台应当具备 | `docs/product/whitepaper.md`、`docs/product/capabilities.md` |
| 详细设计 | 这些能力由哪些产品对象、状态、界面内容和交互成立 | `docs/architecture/`、`docs/design/ui.md` |
| 跨平台实现 | 某个平台用哪些真实机制落地，如何构建、安装和验收 | `docs/platform/`、`docs/development/`、对应平台源码目录 |

上层不复制下层叙事，下层不改写上层合同。

## 归属

平台文档拥有本平台独有的机制事实：服务与进程监督、特权与流量接管原语、状态与凭据的存储位置、
打包与更新通道、构建与验证入口，以及界面宿主和系统集成点。

`docs/architecture/` 与 `docs/design/ui.md` 只描述不依赖平台即成立的对象、状态、决策和交互内容。
一条事实如果只能在某个平台成立，它属于本层；一句设计只有在点名平台后才讲得通，说明它落错了层。
平台的界面内容、文案、状态语义和操作层级与共享设计同源，仍归 `docs/design/ui.md`；
该平台用什么宿主渲染、加载和缓存这些内容归本层。

## 命名与登记

- 一个平台一个文件：`docs/platform/<platform>.md`，作为该平台机制事实的当前 owner。
- 平台实现进入仓库时建立对应文件，并在 `docs/README.md` 和 `docs/product/capabilities.md` 登记；
  未进入仓库的平台不预留文档、占位列或空实现。
- 平台归属由阅读语义判断，不新增关键词或目录检查代替判断。

## 当前平台

| 平台 | 机制事实当前 owner | 源码 |
| --- | --- | --- |
| OpenWrt | `docs/architecture/`（`packaging.md`、`microkernel.md`、`runtime-and-recovery.md`、`interfaces.md`、`device-identity.md`）、`docs/operations/`、`docs/development/` | `openwrt/`、`plugins/` |

本目录尚无平台文档：OpenWrt 的机制事实仍由表中文件拥有，此处不重复它们的内容。事实按主题迁入
平台文档时，同一批次把共享文档中的对应段落缩减为指针，不留第二份当前叙事。
