# OPL NetFleet 当前架构

本文是 NetFleet 当前架构的入口，面向需要理解产品边界、运行链和修改影响的维护者。
具体合同分别由本目录中的主题文档负责；本文只保留跨主题不变量和导航，不复制细节。

设计动机和长期目标见[设计白皮书](../product/whitepaper.md)。尚未成为当前能力的方案见
[`proposals/`](../proposals/README.md)，它们不能改变本文和当前实现定义的行为。

## 当前产品边界

NetFleet 是跨平台的代理资源与业务出口管理产品，组织多个机场、地区与能力，提供共享的
订阅语义、策略编译、选优、状态证据和安全恢复。Mihomo 负责规则执行、节点连接、组内
健康检查与 URLTest；NetFleet 不维护第二个转发核心或选择器。

微内核组合功能插件；业务服务通过显式接口使用平台能力。OpenWrt 与 macOS 使用同一份
共享业务源码，各自组合宿主、存储、进程监督和网络接管。当前平台支持范围归
[能力表](../product/capabilities.md)，系统机制与专属交互归[平台实现](../platform/README.md)。
代码所在目录不授予业务所有权，界面或平台适配器不能另写编译、排序与策略合并规则。

UI 统一业务词汇、页面职责和交互语义，具体渲染按平台实现。状态由 owner 投影，界面只
提交受限操作，不解释节点、重做规则匹配或持有第二份可写策略。插件与系统集成功能按
真实平台能力呈现；独立插件安装、更新和完整面板不能从一个平台推定到另一个平台。

## 当前纵向链

各平台入口加载同一微内核，命令由微内核路由到功能插件
声明的服务方法。服务接口、依赖与代码生命周期见[微内核与功能插件](microkernel.md)。常用运行动作是 `status`、
`events`、`probe`、`validate`、`compile`、`enable`、`disable`、`select` 和 `refresh`；内部动作是
`maintain`、`recover`、`resume`，以及仅供 canonical installer 调用的恢复准备与恢复动作。`refresh`
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
同一选择入口。传输适配器、宿主及业务界面只投影 owner 状态并转发已声明的有限操作，不拥有候选资格、排序、
探测、回滚或配置事实。

## 跨主题硬下限

1. 安装、发现、校验和编译不隐式改变数据面；接入、迁移和启用由明确操作触发。
2. 启用前确认平台上游就绪，失败保持原 Profile；具体网络证据归平台实现。
3. 基础联网与安全退出可以解除对失败增强层的依赖。
4. 退出增强优先恢复独立 Recovery Profile；原生 runtime 仍失败才清理接管进入直通。
5. 每项状态、核心和网络资源只有一个 owner；只清理自身持有的对象。
6. UI、缓存和生成投影不能反向成为配置或运行事实源。
7. 设备不可逆操作边界见[AGENTS.md](../../AGENTS.md)，软件恢复不能扩张为物理恢复授权。
8. 源码、平台构建、安装与实际网络分别验证，不相互替代。

## 文档地图

| 当前主题 | 唯一 owner | 主要内容 |
| --- | --- | --- |
| 微内核与功能插件 | [microkernel.md](microkernel.md) | 服务与页面贡献、实例组合、作用域、代码热替换和资源交接 |
| 产品对象和 owner | [domain-model.md](domain-model.md) | Policy Source、Recovery Profile、provider、binding、capability 和依赖方向 |
| 测量和选择 | [selection.md](selection.md) | 测量事实、资格、comparator、切换门槛和同轮自动选择 |
| 编译、激活和恢复 | [runtime-and-recovery.md](runtime-and-recovery.md) | staged/active 事务、Fail-Open、supervisor 和恢复顺序 |
| 状态呈现 | [ui-state.md](ui-state.md) | 字段的用户解释、库存计数、空态和展示顺序 |
| 显示证据 | [evidence.md](evidence.md) | 持久聚合、可比性和失效边界 |
| RPC 与 UI | [interfaces.md](interfaces.md) | 公开动作、状态投影、插件页面宿主和浏览器边界 |
| HTTPS 兼容 | [https-compatibility.md](https-compatibility.md) | 可选协议转换、设备信任、接管租约和旁路 |
| 设备地址来源 | [device-identity.md](device-identity.md) | 网络侧身份接入、动态地址与失效边界 |
| 模块与扩展 | [extensions.md](extensions.md) | 服务与进程插件接入、进程协议、API 准入和组件投影 |
| 独立设备管理 | [management.md](management.md) | 网络接入、配置维护、备份恢复和运行面资源 |
| 软件包与配置输入 | [packaging.md](packaging.md) | versioned package、private Instance 和 deployment bundle |
| UI 视觉设计 | [../design/ui.md](../design/ui.md) | 主题、布局、组件、性能和可访问性 |
| 部署事务 | [../operations/deployment.md](../operations/deployment.md) | Fleet 输入、资格和目标端安装回滚 |
| 开发验证 | [../development/validation.md](../development/validation.md) | source、UI、VM 和发布验证入口 |
| 推广与复原 | [../operations/canary-promotion.md](../operations/canary-promotion.md) | canary 到 replica 的通用部署顺序和最短恢复路径 |

长期目标只由[设计白皮书](../product/whitepaper.md)说明。已经批准但尚未实现的技术方案由
[`proposals/`](../proposals/README.md)负责；形成长期约束的决策理由由
[`decisions/`](../decisions/README.md)负责。任务状态、百分比、负责人和逐次执行记录不进入
这些活文档。

## 修改入口

- 改服务接口、依赖解析、系统绑定或代码生命周期：先更新 [microkernel.md](microkernel.md)。
- 改进程插件协议或组件接入：先更新 [extensions.md](extensions.md)。
- 改产品对象、依赖方向或 owner：先更新 [domain-model.md](domain-model.md)。
- 改候选资格、测量口径、排序或切换语义：先更新 [selection.md](selection.md)。
- 改 compile、enable、disable、supervisor 或恢复语义：先更新
  [runtime-and-recovery.md](runtime-and-recovery.md)。
- 改公开字段、RPC 动作或 UI 行为：先更新 [interfaces.md](interfaces.md)；视觉规则另改
  [UI 设计合同](../design/ui.md)。
- 改交付与私有配置边界：先更新 [packaging.md](packaging.md)；包格式、系统接管和宿主机制改对应[平台文档](../platform/README.md)。
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

平台交付分别取得安装身份、staged/active 身份、有效 Profile、实际运行路径、网络接入、
业务访问、恢复和真实界面的回读。具体检查由平台能力决定，见[开发验证](../development/validation.md)。
真实设备推广先在可恢复 canary 上验证；另一个目标须独立授权和验收。
