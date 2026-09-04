# OPL NetFleet 设计白皮书

## 文档定位

本文说明 NetFleet 解决什么问题、为什么采用当前边界，以及理想形态应如何演进。它不定义命令、Schema、阈值或当前设备状态；这些可执行合同唯一归[当前架构](../architecture/overview.md)，当前可用入口归[根目录 README](../../README.md)。两者与本文发生差异时，以当前架构和真实实现为准。

## 摘要

当前 Nikki 与 Mihomo 已经能在 OpenWrt 上完成透明代理、订阅管理、规则匹配、节点连接、组内健康检查和进程生命周期，因此 NetFleet 先以增强层接入，补齐它们没有形成统一产品合同的部分：把多个机场组织为同一套出口资源，在节点、机场和地区之间取得性能与稳定性的平衡，并在增强层、代理核心或上游资源失效时让网络退回更低但仍可解释的能力层级。

NetFleet 的长期目标是成为 OpenWrt 上可独立安装、配置和退出的网络增强产品，而不是永远依附某个代理 UI。策略与机场分离，网络资源与业务能力分离，测量与决策分离，运行选择与历史展示分离，正常增强与灾难恢复分离；Nikki 是当前集成路径，Mihomo 是当前运行后端，二者都不成为永久产品身份。未来只有在同一安全合同得到完整实现和验证后，NetFleet 才可以直接管理订阅、透明代理和运行生命周期，并通过后端适配合同选择 Mihomo、sing-box 或其他真实受支持实现。无论使用哪个后端，增强都不能成为 OpenWrt 基础联网的前置条件。

## 问题本质

单个机场提供的 Profile 往往同时包含节点、地区组、业务规则、DNS 和展示命名。这种交付方式容易使用，却把五类本应独立变化的事实绑在一起：

- 机场决定有哪些网络资源；
- Profile 作者决定如何分类流量；
- 地区和节点命名决定如何组织出口；
- 客户端决定如何检测健康和切换；
- 用户只能整体接受或整体替换这套设计。

当只有一个机场时，这种耦合尚可接受。接入多个机场后，问题会迅速暴露：同一地区被重复展示，机场之间无法统一比较，某个机场的规则和命名成为全局依赖，AI 等业务资格难以稳定表达，任何一个 Profile 的更新都可能改变整个网络行为。

NetFleet 要解决的不是“再写一套更复杂的 Profile”，而是恢复正确的对象边界：流量分类回答“这是什么流量”，capability 回答“它需要什么出口”，地区和 Provider 回答“有哪些资源”，选择器回答“此刻用哪个资源”，Fail-Open 回答“这一层失败后退到哪里”。

## 设计原则

### 先增强，再有序接管产品面

当前实现由 OpenWrt 提供基础网络，Nikki 拥有订阅、透明代理、DNS/nft/路由和 Mihomo 生命周期，Mihomo 拥有节点连接、URLTest 和数据面组内切换。NetFleet 只生成和激活可验证的增强拓扑，不在当前链路旁边建立第二套下载器、DNS、路由器或进程清理逻辑。

长期演进不是同时运行两个 owner，而是 successor-first 替换：NetFleet 先通过稳定后端合同获得与当前链路等价的订阅、编译、激活、运行回读和安全清理能力；真实 caller 切换并完成故障恢复验收后，才删除相应 Nikki 依赖。任何阶段都只能有一个订阅事实 owner、一个数据面生命周期 owner 和一个安全退出 owner。

### 一个事实只有一个 Owner

当前订阅节点只存在于 Nikki cache，实时健康和 delay 只来自 Mihomo；机场和地区关系来自设备 policy，流量分类来自策略基线，当前选择来自 Mihomo selector，历史只用于展示。长期直接运行模式下，这些事实改由唯一启用的后端适配器及 NetFleet 设备端配置 owner 提供，不能因支持多个后端而复制状态或并行写入。任何 UI 投影都不能反向成为新的事实源。

### 先资格，后性能

速度不能证明业务资格，业务可用也不能证明速度，流量额度更不能由连接失败猜测。候选必须先满足 capability、地区授权、真实叶子、健康和明确配额约束，之后才比较同目标、同轮次的 proxy-path delay。

### 稳定优先于微小收益

节点层应快速避开失活叶子；地区层应保持粘性，只有当前地区失效或替代地区带来明确收益时才切换。这样既避免长期困在明显较慢的地区，也避免轻微网络抖动造成跨地区漂移。

### Fail-Open 是能力降级，不是成功伪装

Fail-Open 的目标是逐级解除对失败组件的依赖，而不是保证所有境外业务在任何物理网络上都成功。系统可以从优选代理退到其他机场、DIRECT、原生 Nikki Profile，最终退到 Nikki 官方 cleanup 后的 passthrough；每一层都必须明确当前还保留什么能力、失去什么能力。

### 配置驱动，但不制造配置系统

机场、地区、capability、门槛和探针应由数据表达，engine 不按名称写分支。配置仍应保持少量、声明式和可审查；没有真实需求时，不增加规则编辑器、插件市场、脚本钩子、综合评分或动态 DSL。

## 五类核心增强

### 多机场资源整合

Nikki 可以保存多个订阅，Mihomo 可以消费多个 proxy provider；NetFleet 的增量是把这些资源编译成统一、可比较、可回退的出口能力。机场提供上游节点，Nikki cache 是设备上的节点事实源，NetFleet 只声明稳定 Provider 身份、地区映射和故障层级。

用户看到的应该是“海外加速”“AI 出口”和多机场地区，而不是某个机场内部结构的简单拼接。新增机场只增加资源数据，不改变选择算法和业务分类。

### 地区、机场和节点的分层选择

三个层级解决不同问题：

- 地区决定延迟级别、内容可用性和连接稳定性，适合带门槛的粘性选择；
- 机场代表相对独立的服务与额度故障域，适合在合格资源中按实时性能竞争，并按显式故障层退回；
- 节点是最细的连接资源，由 Mihomo URLTest 负责快速健康切换。

NetFleet 不使用综合分，也不让长期历史左右当前选择。历史稳定性可以帮助人理解网络，却不应成为不可解释的隐藏权重。当前轮次没有可靠测量时，系统应保持健康路径，而不是制造一个“最佳”。

### 分层 Fail-Open

数据面仍存在时，回退应尽量留在 Mihomo 内完成：当前叶子、同地区其他叶子、其他主用机场、显式备用机场、DIRECT。控制面事务失败时，NetFleet 先撤销自己的选择，再恢复完整原生 Nikki Profile；Nikki/Mihomo 无法恢复时，最终只调用 Nikki 官方 cleanup 进入 passthrough。

这种设计刻意区分三件事：代理链是否可用、数据面是否已经安全退出、关键业务是否可达。三者可能同时成立，也可能只成立其中一部分，系统必须如实报告。

### 面向能力的业务出口

策略不应直接选择机场或节点，而应选择稳定 capability。`standard` 表示常规境外能力，`ai-compatible` 表示满足 AI 地区约束的能力；未来只有出现真实且不同的资格或回退合同时，才应增加新的 capability。

capability 让分类与资源解耦：AI 流量可以跟随海外加速的合规地区，也可以在该地区不合规时独立选择；机场增删、节点改名和地区映射变化不会迫使业务规则跟着重写。

### 安全激活与可观测

增强层必须可以先生成、后验证、再启用，并且可以随时关闭。编译不改变当前网络；启用和选择必须具备前置身份、运行回读和失败恢复；卸载不能删除仍在使用的路径。

UI 只解释当前事实和提交有限动作，不在浏览器里解析订阅、排序或测速。用户应能看到当前 capability、地区、机场、叶子、选择原因和 Fail-Open 顺序，也能区分“NetFleet 已启用”“当前走 DIRECT”和“已经退回原生 Nikki”这些不同状态。

## 理想形态：NetFleet 产品面与可替换后端

用户最终安装的是一个完整的 NetFleet 插件，而不是“NetFleet 加另一个代理 UI”。NetFleet 产品面负责首次设置、订阅与机场组织、地区识别、业务出口、自动运行、安全恢复、状态和诊断；设备端唯一配置 owner 把结构化选择转换为可校验 policy。浏览器不直接保存订阅秘密、不生成运行配置，也不实现选择算法。

产品独立分成两个层次。版本化 NetFleet package、LuCI 页面和安装事务可以先作为独立发行物交付，同时明确依赖已经可用的 Nikki 与 Mihomo；这叫独立分发，不冒充运行时独立。只有订阅、代理核心和 OpenWrt 数据面生命周期都由 NetFleet 的单一 owner 合同接管后，才叫运行时独立。前者不应等待后者完成才发布，后者也不能因为已有 package 就被宣称完成。

长期运行实现由四个边界组成：

| 边界 | 唯一责任 |
| --- | --- |
| DeviceConfigOwner | 保存结构化产品配置和设备端秘密引用，生成可校验 policy；浏览器不持有订阅 URL/token |
| SubscriptionOwner | 发现、刷新、校验和缓存机场节点源，失败保留上一份已验证内容；同一订阅不能同时由 Nikki 和 NetFleet 写入 |
| RuntimeBackend | 把稳定 capability、机场和地区模型编译到一个代理核心，负责核心启动、重载、停止、controller 回读和延迟测量 |
| OpenWrtDataPlaneOwner | 在同一激活事务中接管或清理 DNS、nft、TProxy/路由，任何失败都能恢复网络直通 |

当前 `nikki-mihomo` 路径把后三项职责委托给 Nikki 与 Mihomo。第一个直接后端应是一条完整的 `native-mihomo` 纵向链，而不是先建立通用插件系统；只有它与第二个真实后端都通过同一套故障和恢复验收后，才从实际差异中提炼稳定 `RuntimeBackend` 接口。`native-sing-box` 或其他后端不能只实现配置生成，必须同时满足同一 mutation lock、原子启用、owner readback、数据面清理和 Fail-Open 合同。

“支持多个后端”只表示同一时刻可选择一个已验证实现，不表示并行运行多个代理核心、保留双写状态或为最小公分母牺牲安全语义。后端差异留在 adapter，机场、地区、capability、选择理由和用户配置模型保持稳定；某个后端无法提供必需的安全清理或可验证回读时，NetFleet 必须拒绝启用该后端。

后端迁移本身也是一次受保护事务：先在不改变数据面的条件下验证新后端配置和依赖，再建立 DIRECT 护栏，停止旧 owner，启动并探测新 owner；失败时恢复旧 owner，成功并完成 target-local readback 后才提交后端身份。迁移不能同时维持 Nikki 与原生后端双写，也不能把“自动回退到另一个代理核心”变成长期运行模式。

### Zashboard 作为 Mihomo 独立完整运行面

NetFleet 自有页面负责稳定摘要、持久配置和受保护生命周期命令，不应重写 Mihomo 已经成熟的实时连接、流量、内存、规则命中、代理组、Provider 和即时控制体验。对 `native-mihomo` 及仍使用 Mihomo 的过渡后端，Zashboard 是 NetFleet “实时运行”入口打开的独立完整页面；不嵌在 NetFleet 内容区，不增加常驻前端进程或 NetFleet 后台轮询。

完整 Zashboard 是 Mihomo 当前运行态的操作面，不是 NetFleet 的持久配置、订阅或恢复 owner。用户可以在其中进行上游已提供的即时 selector 切换和连接管理；这些操作不会自动写回 NetFleet policy，后续刷新、重新编译或启用仍以 NetFleet owner 为准。过渡期 NetFleet 复用 Nikki 的静态资源、controller 和官方打开方式，统一管理导航和可用性；`native-mihomo` 成立后再把资源发行、controller 配置和打开入口一起迁入 NetFleet。

“实时运行”只在当前后端能够提供对应运行面时启用。它不复制概览、机场、地区、配置和事件页的稳定摘要，也不为 sing-box 强行伪装 Mihomo API；未来其他后端可以提供自己的独立运行面。当前 Nikki 打开方式会把 controller secret 放入新标签页 URL，NetFleet 不读取、记录或缓存该 URL；原生后端建立后应优先收敛浏览器认证方式，但不能以削弱完整运行能力换取形式上的统一。

## 理想形态：机场无关的策略基线

### 迁移期的策略来源边界

复用一份已经验证的 Nikki Profile 作为 `PolicySource(kind=profile)`，曾用于建立安全纵向链并保留规则顺序、DNS 和未绑定组。Schema v2 已把它与 `RecoveryProfileRef` 分成两个身份、两个 digest 和两个 owner 用途；当前 source 已支持机场无关的 `kind=bundle`，`kind=profile` 只保留为真实设备迁移窗口。

但完整机场 Profile 不应成为长期的策略内容边界。即使身份已经拆开，`kind=profile` 仍会产生这些结构性问题：

- 更换策略来源可能同时改变规则、DNS、组名和用户操作面；
- NetFleet binding 依赖第三方组名和结构稳定；
- 常规与 AI 等能力受制于机场作者是否提供正确分类；

### 应拆开的两个角色

当前实现已经把两个角色拆开：

**Policy Baseline** 是机场无关的策略来源。它定义有序规则、稳定 capability、必要的本地覆盖，以及与目标网络相关但不属于机场的 Profile 基线。它不包含机场节点，不按机场组名绑定，也不负责订阅下载；其中的 DNS 意图仍由 Nikki 应用和清理，不能把 NetFleet 变成第二个 DNS owner。

**Recovery Profile** 是用户明确选择并独立验证的一份普通 Nikki Profile。它只在 NetFleet 关闭、事务失败或进程级恢复时接管完整 owner。它可以来自一个稳定机场，但不参与正常增强拓扑，也不冒充策略 SSOT。

因此，理想链路是：

```text
Policy Baseline + target-local overrides + Nikki provider caches
    -> NetFleet one-shot compiler
    -> enhanced Profile
    -> Nikki / Mihomo data plane

Recovery Profile
    -> independent native recovery
    -> Nikki official cleanup / passthrough
```

正常运行的策略不依赖任何特定机场；机场只提供网络资源。控制面退出时仍有一份无需 NetFleet 运行即可选择的原生 Profile。两者分离，比“把某个机场 Profile 复制一份作为兜底”更清楚，也不会制造第二份节点事实。

### “自己维护策略”不等于重写规则生态

NetFleet 应拥有策略组合和稳定能力映射，而不是人工维护全互联网域名清单。Mihomo 已原生支持独立的 `rule-providers`、有序 `RULE-SET`、GEOSITE/GEOIP 和本地规则；成熟 OpenWrt 客户端也普遍提供自定义规则、覆写和 rule-provider 管理。

因此 Policy Baseline 最适合由三部分组成，并可保存在一个版本化 bundle 中，而不是拆成三个服务：

1. 少量稳定的顶层规则顺序和 capability 目标；
2. 明确来源的公共 rule-provider 引用；
3. target-local 的精确覆盖，例如必须走某 capability 的私有业务域名。

规则集的下载和缓存继续交给 Mihomo；订阅继续交给 Nikki；NetFleet 只验证引用完整性并编译最终 Profile。这样可以摆脱机场策略，又不引入第二下载器、第二规则引擎或后台同步进程。

### 最小演进方式

当前实现已给 `PolicySource` 增加互斥的 `kind=bundle`，并与 `kind=profile` 共用同一个 compiler、capability、选择器、activation 和 Fail-Open owner，没有形成两套运行系统。`kind=profile` 是明确的迁移窗口，不是永久兼容层；全部真实目标切换并完成验收后，应删除它及其专属测试和文档。

Policy Bundle 只有在完成规则等价、DNS 行为、关键业务分类、DIRECT 行为和 Recovery Profile 独立性的真实验收后，才可成为默认。切换完成后，第三方机场 Profile 只保留为恢复资源或彻底退出，不再决定 NetFleet 正常运行的策略结构。

## 对五类增强的充分性评估

| 能力 | 当前方向 | 还需要的优化 | 明确不增加 |
| --- | --- | --- | --- |
| 多机场整合 | 充分 | 让正常策略彻底脱离机场 Profile；真实需要时再补充可验证的故障域 metadata | 节点副本、第二订阅下载器、按机场名称写逻辑 |
| 分层选择 | 充分 | 继续校准少量显式门槛和周期，保持同轮实时 delay | 综合评分、历史加权、固定 Top-N、入口 ping 排名 |
| Fail-Open | 设计充分 | 重点是真实目标环境的故障注入和 owner readback，不是增加更多恢复层 | 自写 DNS/nft cleanup、多个 supervisor、连接重放承诺 |
| Capability | 充分且可扩展 | 新能力必须有不同资格或回退合同 | 按网站无限拆组、动态插件系统、名称猜测 |
| 安全激活与可观测 | 当前增强链充分 | 保持设备端唯一持久配置 owner；以独立完整 Zashboard 承载 Mihomo 实时操作；长期把 dashboard 与 controller owner 迁入 NetFleet | raw policy 编辑器、后台 projection、无限历史、并行持久控制面 |

五类增强已经覆盖产品需要的核心网络能力，当前也已经具备机场无关 Policy Bundle 和设备端结构化配置 owner。NetFleet 可以据此先作为依赖 Nikki/Mihomo 的独立发行物交付；完整产品独立性仍取决于原生订阅、运行后端和 OpenWrt 数据面 owner 的纵向替换。后端替换必须沿真实链路推进，不能先建立没有 caller 的通用插件系统；Zashboard 只补充观察体验，不能替代任何 owner 迁移。

## 不做什么

NetFleet 不追求成为通用 SD-WAN、流量分析平台或自动化规则市场。即使长期吸收代理客户端的必要产品能力，也只服务于机场、地区、业务出口、自动选择和安全退出这条明确链路；不预测未来节点质量，不用历史制造稳定性评分，不为每类网站创建独立探测器，也不承诺直连可以访问物理网络本身无法到达的服务。它不为文件数量拆分已经唯一的激活事务，不为展示语言把生成组名做成插件，也不在没有真实后端和 caller 时预建通用扩展系统。

项目的成功标准不是“控制项最多”，而是使用少量稳定概念，持续得到三个结果：更好的出口质量、更小的故障影响面，以及任何时候都能解释并撤销增强。

## 调研依据

- [Mihomo Rule Providers](https://wiki.metacubex.one/en/config/rule-providers/)：规则来源可以独立为 `http|file|inline` provider；
- [Mihomo Proxy Providers](https://wiki.metacubex.one/en/config/proxy-providers/)：节点来源、健康检查和过滤是原生对象；
- [Mihomo Routing Rules](https://wiki.metacubex.one/en/config/rules/)：规则按顺序匹配，并可引用 `RULE-SET`；
- [Nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)：负责 OpenWrt 透明代理、Profile/mixin、路由和 nftables 生命周期；
- [MetaCubeX meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)：可复用的 Mihomo 规则数据来源；
- [OpenClash](https://github.com/vernesong/OpenClash)：成熟 OpenWrt 客户端对自定义规则、配置覆写和 rule-provider 管理的实践，同时也说明把所有编辑能力塞进运行产品会显著增加复杂度。

这些项目证明了平台原语和可行边界，不构成 NetFleet 的运行依赖。NetFleet 只采用能保持单一 owner、可回退和低复杂度的部分。
