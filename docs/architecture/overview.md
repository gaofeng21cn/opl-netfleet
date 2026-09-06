# OPL NetFleet 当前架构

本文是 NetFleet 当前架构的入口，面向需要理解产品边界、运行链和修改影响的维护者。
具体合同分别由本目录中的主题文档负责；本文只保留跨主题不变量和导航，不复制细节。

设计动机和长期目标见[设计白皮书](../product/whitepaper.md)。尚未成为当前能力的方案见
[`proposals/`](../proposals/README.md)，它们不能改变本文和当前实现定义的行为。

## 当前产品边界

NetFleet 是 OpenWrt 上的多机场网络增强插件，当前源码有 `nikki-mihomo` 与
`native-mihomo` 两条明确选择的后端路径。两者共用 Policy、编译、选优、证据、刷新与
恢复事务；Mihomo 始终拥有节点连接、组内健康检查和 URLTest。

Nikki 模式继续使用 Nikki 的订阅和数据面 owner。原生模式由 NetFleet 管理订阅私有输入、
缓存和服务，正式 gateway 复用固定版本 Nikki 的配置投影与 nft 模板，管理自身命名空间的
DNS、IPv4/IPv6 透明代理和策略路由。原生模式不继续读写 Nikki 的配置或启动其服务。
两种模式不会并行运行代理核心，也不建立双写或运行时自动回落到另一后端。

当前仓库包含 UCode runtime、OpenWrt package source、薄 rpcd 适配器、原生 LuCI 页面，
以及一个由 `procd` 直接监督的前台 supervisor。设备配置可在所选后端订阅、共享地区目录
和 Policy Source 组边界内维护完整 NetFleet policy。原生订阅凭据通过独立 subscriptions
owner 保存，不进入 policy；浏览器不管理 DNS/nft 或解析节点。Zashboard 仍是独立完整
页面，由当前后端提供资源和 controller。没有并行刷新循环、第二选择器或 sing-box 后端。

后端身份由设备私有 selector 明确选择，缺省使用 Nikki 路径，未知身份拒绝。
空白设备通过显式原生接入建立初始环境；已有 Nikki 设备只通过绑定 revision 的迁移事务
交接 owner。源码能力、发布包和具体设备验收是独立事实；后端实现存在不代表任意发布资产
或设备已经通过等功能验证。入口和权限见[公开接口](interfaces.md)。

## 当前纵向链

当前实现入口为 `openwrt/files/usr/libexec/opl-netfleet/main.uc`。常用运行动作是 `status`、
`events`、`probe`、`validate`、`compile`、`enable`、`disable`、`select` 和 `refresh`；内部动作是
`maintain`、`recover`，以及仅供 canonical installer 调用的恢复准备与恢复动作。`refresh`
复用同一个 one-shot owner 和设备锁，不另建订阅 writer。接入、迁移、订阅与 Dashboard
管理动作由[接口合同](interfaces.md)统一列出。

```text
target-local policy + PolicySource + selected backend subscription cache
    -> one-shot compiler
    -> staged Profile + manifest
    -> activation owner
    -> selected backend Profile switch/restart
    -> Mihomo current owner state

RecoveryProfileRef
    -> rollback / disable / recover
    -> selected backend Profile switch/restart
    -> selected backend cleanup / network passthrough
```

`validate` 可以只读校验显式 policy 路径；其他动作只读取 canonical target-local policy。
`compile` 只生成 staged，不改变数据面。首次启用、显式自动选优和 supervisor 到期轮次复用
同一选择入口。rpcd 和 LuCI 只投影 owner 状态并转发有限命令，不拥有候选资格、排序、
探测、回滚或配置事实。

## 跨主题硬下限

1. 安装、`validate` 和 `compile` 默认无数据面副作用；接入、迁移和启用必须显式确认。
2. 启用前必须确认 WAN 已 up 且存在 IPv4 默认路由；不满足时保持原 Profile。
3. NetFleet 未安装、未启用、崩溃或被卸载时，OpenWrt 基础联网必须仍可独立恢复。
4. disable、事务回滚和进程级恢复优先恢复独立的 Recovery Profile；原生 runtime 仍失败时，
   才允许所选后端 stop/cleanup 恢复网络直通。
5. Nikki 模式使用官方数据面生命周期；原生 gateway 只清理自己持有且身份可回读的
   DNS、nft 和路由状态，不对其他后端缓存或网络状态建立第二 writer。
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
| 独立设备管理 | [management.md](management.md) | 网络接入、配置维护、备份恢复和运行面资源 |
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
- 为同一运行来源建立第二下载器、节点副本、排名库或第二事实投影；
- 多个后台循环、worker 身份链或与 activation owner 竞争的 mutation owner；
- 综合评分、固定 Top-N、入口 ICMP 代替出口 RTT，或把历史平均值用于当前选择；
- 自动激活、后台 compile、健康期无触发的全地区扫描；
- 绕过正式 gateway 或所选后端 owner 的 DNS、nft、路由清理；
- 没有真实 caller 的 facade、公开 schema、兼容版本或 UI。

## 准入证据

每个新增机制必须回答：当前需求是什么，现有 owner 为什么不能完成，不增加会失败哪项验收，
最小真实路径如何证明。缺少其中任何一项时，该机制不进入 source。

设备完成必须分别取得 installed artifact、staged/active 身份、所选后端 effective Profile、Mihomo
current chain、DNS/nft/IPv4/IPv6、业务访问、恢复和 LuCI DOM 的 target-local readback。推广先在一台
可恢复 canary 上证明，再把同一 canonical artifact 复制到单独授权的 replica；任何一台设备的
成功都不能替代另一台设备的验收。
