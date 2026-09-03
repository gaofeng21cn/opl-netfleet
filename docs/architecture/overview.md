# OPL NetFleet 当前架构

本文是 NetFleet 当前架构的入口，面向需要理解产品边界、运行链和修改影响的维护者。
具体合同分别由本目录中的主题文档负责；本文只保留跨主题不变量和导航，不复制细节。

设计动机和长期目标见[设计白皮书](../product/whitepaper.md)。尚未成为当前能力的方案见
[`proposals/`](../proposals/README.md)，它们不能改变本文和当前实现定义的行为。

## 当前产品边界

NetFleet 当前是 OpenWrt + Nikki + Mihomo 的可选增强层。Nikki 继续拥有订阅、Mihomo
生命周期、DNS、nft 和路由；Mihomo 继续拥有节点连接、组内健康检查和 URLTest。
NetFleet 只增加显式出口绑定、跨机场和地区的资源组织、可验证的选择，以及安全的
生成、启用、恢复事务。

当前仓库包含 UCode runtime、OpenWrt package source、薄 rpcd 适配器、原生 LuCI 页面，
以及一个由 `procd` 直接监督的前台 supervisor。当前没有第二订阅下载器、远程 Host、
第二选择器、后台投影、原生 sing-box 后端或内置 Zashboard。

当前运行后端身份是 `nikki-mihomo`，不是永久产品身份。NetFleet 只有在 successor 已完整
接管订阅、后端生命周期、OpenWrt 数据面和安全清理，并通过同一恢复合同后，才可以不再
依赖 Nikki。长期方向不能提前表现为当前 UI 选项或运行时 fallback。

## 当前纵向链

当前实现入口为 `openwrt/files/usr/libexec/opl-netfleet/main.uc`。公开动作是 `status`、
`events`、`probe`、`validate`、`compile`、`enable`、`disable` 和 `select`；内部动作是
`maintain`、`recover`，以及仅供 canonical installer 调用的恢复准备与恢复动作。

```text
target-local policy + PolicySource + Nikki subscription cache
    -> one-shot compiler
    -> staged Profile + manifest
    -> activation owner
    -> Nikki official Profile switch/restart
    -> Mihomo current owner state

RecoveryProfileRef
    -> rollback / disable / recover
    -> Nikki official Profile switch/restart
    -> Nikki official cleanup / network passthrough
```

`validate` 可以只读校验显式 policy 路径；其他动作只读取 canonical target-local policy。
`compile` 只生成 staged，不改变数据面。首次启用、显式自动选优和 supervisor 到期轮次复用
同一选择入口。rpcd 和 LuCI 只投影 owner 状态并转发有限命令，不拥有候选资格、排序、
探测、回滚或配置事实。

## 跨主题硬下限

1. 安装、`validate` 和 `compile` 默认无数据面副作用；只有显式启用才可切换 Nikki Profile。
2. 启用前必须确认 WAN 已 up 且存在 IPv4 默认路由；不满足时保持原 Profile。
3. NetFleet 未安装、未启用、崩溃或被卸载时，OpenWrt 基础联网必须仍可独立恢复。
4. disable、事务回滚和进程级恢复优先恢复独立的 Recovery Profile；原生 runtime 仍失败时，
   才允许 Nikki 官方 stop/cleanup 恢复网络直通。
5. NetFleet 不自行清理 DNS、nft 或路由，也不建立第二套订阅、选择历史或恢复循环。
6. 每项状态和 mutation 只有一个 owner；投影不得反向成为事实源。
7. 设备软件操作不授权重启、关机、系统升级、固件写入或依赖现场才能撤销的动作。
8. source 测试、package 构建和设备运行分别是不同证据层，不能互相替代。

## 文档地图

| 当前主题 | 唯一 owner | 主要内容 |
| --- | --- | --- |
| 产品对象和 owner | [domain-model.md](domain-model.md) | Policy Source、Recovery Profile、provider、binding、capability 和依赖方向 |
| 测量和选择 | [selection.md](selection.md) | 测量事实、资格、comparator、切换门槛和同轮自动选择 |
| 编译、激活和恢复 | [runtime-and-recovery.md](runtime-and-recovery.md) | staged/active 事务、Fail-Open、supervisor 和恢复顺序 |
| RPC 与 UI | [interfaces.md](interfaces.md) | 公开动作、状态投影、React/LuCI 双宿主和浏览器边界 |
| 软件包与配置输入 | [packaging.md](packaging.md) | versioned package、private Instance 和 deployment bundle |
| UI 视觉设计 | [../design/ui.md](../design/ui.md) | 主题、布局、组件、性能和可访问性 |
| 推广与复原 | [../operations/canary-promotion.md](../operations/canary-promotion.md) | canary 到 replica 的通用部署顺序和最短恢复路径 |

长期目标只由[设计白皮书](../product/whitepaper.md)说明。已经批准但尚未实现的技术方案由
[`proposals/`](../proposals/README.md)负责；形成长期约束的决策理由由
[`decisions/`](../decisions/README.md)负责。任务状态、百分比、负责人和逐次执行记录不进入
这些活文档。

## 修改入口

- 改产品对象、依赖方向或 owner：先更新 [domain-model.md](domain-model.md)。
- 改候选资格、测量口径、排序或切换语义：先更新 [selection.md](selection.md)。
- 改 compile、enable、disable、supervisor 或恢复语义：先更新
  [runtime-and-recovery.md](runtime-and-recovery.md)。
- 改公开字段、RPC 动作或 UI 行为：先更新 [interfaces.md](interfaces.md)；视觉规则另改
  [UI 设计合同](../design/ui.md)。
- 改 package、private Instance 或 deployment bundle 边界：先更新 [packaging.md](packaging.md)。
- 仅提出未来能力：写 proposal，不得先修改当前架构或让 UI 冒充已经实现。

所有主题修改都必须同时回读真实 caller、实现 owner 和受影响测试。退役接口前先证明
successor 已接管真实 caller；caller-zero 后在同一批次删除实现、配置、测试和文档，
不保留无真实需求的 alias、兼容字段或 fallback。

## 禁止重新引入

- 完整 NetFleet 流量分类目录，或按机场、地区、节点和基础组名称猜测行为；
- 第二订阅下载器、节点副本、LKG、generation、排名库或第二事实投影；
- 多个后台循环、worker 身份链或与 activation owner 竞争的 mutation owner；
- 综合评分、固定 Top-N、入口 ICMP 代替出口 RTT，或把历史平均值用于当前选择；
- 自动激活、后台 compile、健康期无触发的全地区扫描；
- NetFleet 自写 DNS、nft、路由 cleanup；
- 没有真实 caller 的 facade、公开 schema、兼容版本或 UI。

## 准入证据

每个新增机制必须回答：当前需求是什么，现有 owner 为什么不能完成，不增加会失败哪项验收，
最小真实路径如何证明。缺少其中任何一项时，该机制不进入 source。

设备完成必须分别取得 installed artifact、staged/active 身份、Nikki effective Profile、Mihomo
current chain、DNS/nft/IPv4、业务访问、恢复和 LuCI DOM 的 target-local readback。推广先在一台
可恢复 canary 上证明，再把同一 canonical artifact 复制到单独授权的 replica；任何一台设备的
成功都不能替代另一台设备的验收。
