# 产品对象与 Owner

本文是 NetFleet 当前产品边界、核心对象、唯一 owner 和依赖方向的权威合同。测量与选择、
运行事务和公开接口分别由同目录其他文档负责。

除“原生订阅准备”一节外，本文的订阅和生命周期边界均指当前 `nikki-mihomo` 运行链。

## 原生订阅准备

`main.uc` 的显式 root CLI 是原生来源准备的唯一入口，`application/native_sources.uc`
承载同一进程内的保存、下载与缓存事务；不经 LuCI/RPC，不由 supervisor 自动调度。
它只写 `/etc/opl-netfleet/native/`，不读取、复制或修改 Nikki 的 URL、UCI、cache、Profile，
不消费现有 policy，也不启动、重载或切换数据面。准备成功不代表已完成原生接管。

私有 `sources.json` 保存 `schema_version: 1` 与 `sources` 数组，每项明确提供稳定 `id`、
`display_name`、HTTPS `url`、`enabled` 和可选 `user_agent`；只接受 Mihomo YAML/JSON
订阅中的非空 `proxies`，不接受远端规则、DNS、监听器或 provider 下载声明作为本地配置。
该文件与 Fleet deployment bundle 的 `subscriptions.json` 不是同一合同。凭据只能由
root 私有文件输入，目录 `0700`、文件 `0600`，不进入参数、返回值、日志或 Git。

来源保存和刷新与现有部署、选优共用同一个设备 mutation lock。下载仅允许 HTTPS，
重定向不得降级；使用系统 CA、显式直连、有界时间与大小，不继承代理环境。
下载结果经只读 YAML 转换和真实 `mihomo -t` 校验后，才原子替换单来源缓存。
每个 `cache/<id>.json` 同时保存节点、内容摘要、来源身份、最近尝试、最近成功和变化时间；
它可以直接作为 Mihomo file provider 输入，不维护第二份可变节点文件。
未变化内容保留内容摘要和变化时间，只更新成功读取时间；失败保留上一份有效节点，
记录脱敏错误并继续其他来源。来源 URL 或 user-agent 改变后，旧缓存不得被标为当前来源
就绪或继承其成功时间；删除来源同时删除该来源缓存。显示名与启用开关不改变内容身份。

该准备 owner 不替代当前 Nikki refresh，两个入口不能同时写一份来源缓存。后续正式原生
activation 必须接管这些输入并负责运行时应用，不能让准备命令绕过 active 更新事务。

## 产品定位

OpenWrt + Nikki + Mihomo 必须在没有 NetFleet 时独立提供可用网络。NetFleet 只是可选增强层：独立安装模式从设备上已经验证可用的 Nikki 当前 Profile 和稳定命名 subscription 自动生成初始 policy；声明式 Fleet 模式仍可使用机场无关的 `PolicySource(kind=bundle)`。独立的 `RecoveryProfileRef` 提供退出和故障恢复目标。NetFleet 只对用户确认接管的流量组增加多 provider、多地区出口能力。

NetFleet 不能成为基础联网、订阅更新、DNS、nft、默认路由或 Mihomo 生命周期的前置条件。未安装、未启用、自身崩溃或被卸载时，用户必须仍能在 Nikki 中选择原始 Profile。

这是当前 `nikki-mihomo` 运行合同，不是永久产品身份。长期产品方向见[设计白皮书](../product/whitepaper.md)：NetFleet 可以在 successor 已完整接管订阅、运行后端、OpenWrt 数据面生命周期和安全清理后不再依赖 Nikki，并允许同一时刻选择一个满足统一合同的 Mihomo、sing-box 或其他后端。当前 Nikki 运行链已有 SubscriptionOwner（只读发现、脱敏投影、显式 refresh 编排）；独立来源与缓存只用于上述原生订阅准备。正式 `RuntimeBackend` 切换、原生 Mihomo 生命周期、sing-box adapter 和自有 Zashboard 资源管理仍未实现，UI 不得把这些目标显示为当前可用选项，运行代码也不得为未来后端预建双写或 fallback。

## 能力分层与使用逻辑

原生 OpenWrt + Nikki + Mihomo 已经负责流量分类、规则顺序、订阅下载与缓存、节点连接、组内健康检查、URLTest、DNS/nft、透明代理、默认路由和进程生命周期。NetFleet 第一阶段只对已启用订阅做只读发现、脱敏投影和官方 refresh 编排；其余仍只增加原生没有统一合同的部分：显式出口绑定、跨 provider/地区资源组织，以及可验证的生成/启用/退回事务。能由 Nikki 或 Mihomo 原生完成的功能不在 NetFleet 重做。

| 增强能力 | 用户怎样使用 | 准入阶段 |
| --- | --- | --- |
| 显式出口绑定 | 每个启用 capability 用一个 `entry` 接管规则出口；需要保留名称的业务分类组用 `policy` 绑定获得同一套“自动选优 / 共享地区出口 / DIRECT”选择面 | MVP-1 必须 |
| provider/地区资源引用 | 引用多个真实 Nikki subscription section 和 region；每个 provider 只作为 Mihomo `type:file` source，NetFleet 不重新下载或复制节点 | MVP-1 支持多个手动 provider；MVP-2 支持自动池 |
| 手动地区或 DIRECT | 对一个已绑定能力选择允许的多机场地区聚合组或 DIRECT，随后 readback 当前链；provider 不作为单独用户模式 | MVP-1 必须 |
| staged/active 安全激活 | `compile` 只生成 staged；用户确认 `enable` 后才切换 Nikki Profile，失败自动退回 | MVP-1 必须 |
| 原生退回和安全卸载 | 在 Nikki 手工切回 Recovery Profile，或执行 `disable`；active 时卸载必须先恢复成功 | MVP-1 必须 |
| 地区选优与故障转移 | 首次 enable、用户单次选优和后台到期轮次使用同一 comparator；当前地区仍合格时，除非替代地区至少快 `150 ms`，否则保持。运行期由 Mihomo fallback 按 provider 的 `primary -> reserve -> DIRECT` 层级恢复 | MVP-2 |
| 进程级 Fail-Open | NetFleet active 且 Mihomo/controller 连续失联超过 grace 时，唯一 supervisor 调用 activation owner，按 `DIRECT 护栏 -> Recovery Profile -> Nikki 官方 stop/cleanup passthrough` 收口 | MVP-2 必须 |
| 能力资格约束 | capability 只接受 policy 明确授权的地区；AI 能力可排除香港，并通过 `prefer_region_from` 优先跟随常规能力的合规地区，否则选择同轮最快合规地区 | automatic 跟随能力 |
| 只读运行回读和薄 UI | 只展示 owner 状态并提交有限动作，不解析订阅、不排序、不探测 | 真实 caller 出现后 |

capability 是 policy 中的可组合增强单元，不是动态代码插件、进程或第二控制面。`main.enabled` 是全局启用许可；每个 capability 再独立声明 `enabled`、`manual|automatic`、允许或排除地区和选择门槛；可选 `display_order` 只控制 Profile/status 的显示顺序，同值时按稳定 ID 排序，不能影响选路。每个启用能力必须恰有一个 `entry` binding；它是规则与组引用改写到 capability 可见 selector 的唯一接入点。零个或多个 `policy` binding 保留原业务分类组名称，但把其成员标准化为该 capability 的同一套用户选择面，不复制算法、节点或状态。机场运行层级只由 provider 的 `primary|reserve` role 决定：当前优选失效后先在全部主用机场中选择，主用层全部失效才进入备用机场，最后进入 `DIRECT`。生成 Profile 不复制策略来源组作为第二条 native 路径；恢复整个 Recovery Profile 只属于 enable/select/disable 的事务恢复。该差异完全由数据配置决定，engine 不按 AI、地区、机场或组名分支。全局关闭时允许全部 capability 关闭并保留配置；全局允许启用时至少要有一个 capability 开启。多个 capability 共享 provider/region 资源和同一 activation/Fail-Open owner；disabled capability 可以保留配置和 binding，compiler 直接忽略它并保持对应策略来源组原样。Fail-Open、activation 和 Nikki adapter 是公共且不可关闭的安全底座。

`policy_source`、`recovery_profile`、`platform.json` 与 provider role 是四个独立 owner 边界：`policy_source` 只决定正常编译所读取的规则、DNS 和策略组；`recovery_profile` 只决定 NetFleet 关闭、事务失败或用户手工切回时由 Nikki 完整恢复的原生 Profile；私有 `platform.json` 只声明 Nikki/OpenWrt 的透明代理、DNS 模式、controller、sniffer、日志和 flow-offload 平台参数；provider role 只决定 NetFleet Profile active 时的主用/备用机场层级。`kind=bundle` 从 `/etc/opl-netfleet/policy-sources/<stable-id>.json` 读取机场无关的 JSON 基线，`kind=profile` 仍可只读引用完整 Nikki Profile 作为迁移输入；两者共用同一个 compiler、manifest、activation 和 status 路径。恢复 Profile 可以与某个 provider 使用同一个机场，但二者不能互相冒充，也不能复制该机场的节点、DNS 或订阅字节。每个 target 只能选择一份已经独立验证过规则、DNS、保护业务和可用额度的恢复 Profile；机场计费属性不能替代独立验收，也不允许影响 active Profile 的可见策略组或自动排序。

automatic capability 必须形成无环依赖图，并且只有一个不声明 `prefer_region_from` 的根能力。跟随能力先过滤自身的 allowed/excluded 地区和候选资格；根能力选中的地区仍合格时直接复用该地区，否则在自身 primary、reserve 层级中按同一轮 delay 选择最快地区。每轮只对每个 provider 触发一次原生 health-check，再依依赖顺序测量各 capability selector；所有 selector 写入、protected probes 和失败恢复仍属于同一个原子 activation owner。supervisor 只负责到期调度和进程失联 grace，不实现 comparator、不持久化排名，也不增加第二循环。

模块与策略只通过 policy 组合：全局开关不改变 capability 配置；capability 开关不改变 provider/region 资源；`manual|automatic` 决定可见选择面是否包含自动入口及是否参与周期轮次，不改变资源事实；provider `role` 只决定运行期主用/备用层级；`region_switch_margin_ms` 和 `leaf_switch_margin_ms` 可由 capability 覆盖全局默认。机场角色、计费类型、地区授权、测速合同和保护探针各自保留在独立分区，engine 不按 capability、机场或地区名称分支。

用户实际使用顺序固定为：先在 Nikki 选择并验证原始 Profile；安装 NetFleet 后由首次设置读取当前 Profile、稳定命名 subscription cache、原始策略组和真实节点名称，生成不含 URL/token/节点正文的接管预览。发现器只把 cache 中实际存在可用节点的已知地区写入初始 policy，所有机场默认属于主用层，不从名称、计费属性或顺序猜测备用角色。发现器优先绑定原 Profile 的 `MATCH` 目标组；无法唯一识别入口组、没有有效订阅 cache、当前 Profile 不是可恢复原生 Profile 或 Nikki owner 不健康时拒绝接管。用户一次确认后，activation owner 原子完成 `policy 写入 -> compile -> enable -> supervisor enable/start -> owner readback`；任一步失败都恢复原 Profile 并删除本次生成的 policy/artifact。之后由 Nikki/Mihomo 继续负责数据面。高级用户仍可在 LuCI 调整 provider role、地区和 capability；Fleet 运维也可继续通过 deployment bundle 提供精确声明。

跨地区自动选择不是 MVP-1 的前提，但已经成为 MVP-2 的真实 caller。自动选优在 enable 初次决定、用户明确触发和 `automation.selection_interval_seconds` 到期时执行同一个有界候选轮次；不并发重入，不为后台另建算法或证据。当前地区仍有合格叶子时，只有最快替代地区比当前代表叶子的 Mihomo proxy-path delay 至少快 `selection.region_switch_margin_ms`（默认 150）才切换；当前地区无合格叶子时不受该门槛限制。`checks.latency` 只负责速度排序，`fail_open.probes` 负责事务提交和运行期 fallback 资格，quota 只作同速 tie-break；三者不能互相代换。

## 硬下限

1. 默认无副作用：安装 package 和首次发现预览不改变 Nikki 当前 Profile、selector、DNS、nft、路由或数据面；只有用户确认“一键接管”或显式 deployment action 才可进入 activation 事务。
2. 显式启用：只有用户确认 enable 后，Nikki 才能切到 NetFleet 派生 Profile。
3. 上游先决条件：enable 在切换 Profile 前必须确认 WAN interface 已 up 且存在 IPv4 默认路由；上游不可用时保持原 Profile，不触碰 Nikki。
4. 原生退路：disable 和 Nikki 手工切回原始 Profile 都不依赖 NetFleet 后台进程。
5. 安全卸载：NetFleet Profile active 时必须先恢复并验证原始 Profile，或完成已验证且持久的 Nikki passthrough；两条路径都不能证明时拒绝卸载。
6. 生命周期归属不变：Nikki 继续拥有订阅下载/cache 字节、Mihomo、DNS、nft 和路由；第一阶段 SubscriptionOwner 只编排官方 refresh 并投影脱敏状态。NetFleet 不实现自己的 cleanup，也不复制 Nikki GPLv3 源码。
7. 单一控制面：每项状态和 mutation 只有一个 owner，不建立第二套事实、后台投影或恢复循环。
8. 远程可恢复边界：NetFleet 的开发、部署、验收和故障恢复都不包含设备 `reboot`、`poweroff`、`sysupgrade`、固件写入或任何依赖现场/OOB 才能撤销的动作。软件路径无法恢复管理面时必须停止并返回 `needs_local_recovery`，不能把物理操作当成部署步骤。

## Owner

| Owner | 唯一责任 |
| --- | --- |
| Policy Source | 提供流量分类、首条命中规则顺序、原始组名和未绑定组行为；内置 bundle 使用锁定 MRS 做业务分类，但不声明 DNS；`kind=profile` 继续逐字保留原 Profile 规则和 DNS；只作为 compiler 输入 |
| Recovery Profile | NetFleet 关闭、事务失败和进程级恢复时由 Nikki 选择的完整原生 owner；不参与正常选优 |
| Platform declaration | 私有 `platform.json` 声明目标 Nikki UCI 与 OpenWrt flow-offload 值；canonical deploy owner 负责校验、快照、应用、官方 reload/restart 和 readback，不直接生成 nft/ip rule |
| Ruleset lock | 公共 `rulesets.lock.json` 锁定上游 commit、URL、格式、大小、SHA-256 和许可证；提供内置 Policy Source 已引用的业务、地域和私网 MRS，不拥有规则顺序或自动更新 |
| Nikki | 订阅 URL/token、官方下载与格式校验、单机场 cache 原子替换、Profile 选择、Mihomo 生命周期、DNS/nft/路由清理 |
| 第一阶段 SubscriptionOwner | 只读发现 policy 中已启用的稳定 Nikki section，投影显示名、cache 存在性/digest、quota/expiry 和最近 refresh 结果；在唯一 mutation owner 与设备锁内逐个调用 Nikki 官方 `update_subscription`。失败保留该 section 上一份已验证 cache。不拥有 URL/token，不建立第二 cache，不接管 Mihomo/DNS/nft/路由 |
| Mihomo | 节点连接、组内健康检查、URLTest delay 和叶子切换 |
| latency adapter | 按 `checks.provider_healthcheck_timeout_ms` 并发触发 provider 原生 health-check，再对候选组当前代理链按 `checks.latency` 做一次有界 delay，输出标准化 delay 或 `unavailable`；不判断业务资格 |
| quota adapter | 只读 Nikki 官方 subscription metadata，输出 `available|exhausted|unknown` 和可选剩余量 |
| qualification/comparator | 纯函数消费标准化测量和 policy，先判资格、再按 delay 和显式 tie-break 排序；不执行 I/O |
| NetFleet compiler | 一次性读取显式配置和 Nikki 本地缓存，生成一个 staged 派生 Profile；用户可见 Mihomo 组名由 compiler 用固定中文模板拼接，不是 UI i18n，也不是 policy 字段 |
| NetFleet onboarding owner | 纯发现逻辑从 Nikki 当前 Profile、稳定 subscription cache 和节点名称生成初始 policy 与脱敏预览；不读取订阅 URL、不下载节点、不猜备用角色，写入和接管仍交给 `main.uc` activation owner |
| NetFleet I/O adapter | `adapters/uci.uc` 是 JSON/YAML 只读转换、UCI、quota metadata、文件摘要和 evidence 落盘的唯一 I/O 边界，不是第二配置源 |
| NetFleet activation owner | 唯一 one-shot 进程是 `main.uc`，执行 compile、enable、disable 和有限 select 事务；`core/activation.uc` 只提供前置条件、active 判定和 passthrough 纯函数，不持有 I/O 或恢复循环 |
| NetFleet supervisor | 只在 policy 允许时调度既有 automatic 轮次，并在 active runtime 连续失联超过 grace 后调用既有 recovery owner；不判断候选、不保存排名、不清理 DNS/nft/路由 |
| canonical deploy owner | 为 Fleet/可重复运维从精确 Git commit/tree 和私有 deployment bundle 完成兼容性预检、依赖补齐、Nikki 原生基线准备、NetFleet 安装/恢复和 installed parity；它不是独立插件首次设置的前置条件 |
| NetFleet UI | owner 状态的只读投影和有限命令，不拥有配置或算法；门槛、周期、着色和说明只读 status 投影 |

依赖只能向下流动，不能由投影反向写入事实：

```text
PolicySource + target-local config + Nikki cache
    -> one-shot compiler
    -> staged Profile + manifest
    -> activation owner <- one procd supervisor (schedule / runtime grace only)
    -> Nikki Profile
    -> Mihomo current state
    <- status/UI read-only projection

RecoveryProfileRef
    -> activation rollback / disable / recover
    -> Nikki official cleanup / passthrough
```

解耦规则如下：Policy Source 只提供编译输入；Recovery Profile 只负责原生恢复；binding 只负责把策略来源中的精确组名接到 capability；capability 只负责开关、资格、地区范围和选择参数；region/provider 是 capability 可复用的网络资源；provider 只引用 Nikki section；measurement adapters 只负责采样；qualification/comparator 只处理标准化结果；compiler 只做一次性转换，并拥有生成 Profile 的用户可见组名模板；`main.uc` 是唯一命令入口和 mutation owner，`application/onboarding.uc`、`application/configuration.uc` 只承载同一进程内的事务实现；UI/transport 只投影和转发。任何模块都不得维护第二份可刷新的订阅事实、维护选择历史、改写 DNS/nft/路由或从 runtime snapshot 反向修改配置。若设备不能消费 `type:file` provider source，compile 必须失败并保持 Recovery Profile，不得引入第二下载器或节点副本。没有新的激活合同和真实 caller 时，不增加第二进程、daemon、锁、状态或 owner，不把组名模板做成配置系统，也不为伪节点卫生正则增加独立 policy 分区。

### 解耦审查结论

| 边界 | 结论 | 必须保留的证明 |
| --- | --- | --- |
| PolicySource -> Binding | 这是有意的窄耦合：NetFleet 必须知道用户要增强哪个真实组，但不能猜名称 | 策略来源身份/组清单 digest；组不存在或变化时 compile 拒绝 |
| RecoveryProfile -> Activation | 已与正常编译输入解耦；只供 enable 前置、rollback、disable 和 recover 使用 | 独立 ref/digest；原生 owner/runtime readback |
| Binding -> Capability | 已解耦；binding 只声明 `entry|policy` 和 capability，不知道 provider、节点或地区 | 每个启用 capability 恰有一个 `entry`；`policy` 组只复用 capability 用户选择面；disabled binding 保持原组不变 |
| Capability -> Region/Provider | 需要保持单向：capability 定资格，region 定范围，provider 定 Nikki 来源和角色 | 不产生第二套 ProviderPolicy；未知资格不进入候选 |
| Measurement -> Qualification | 必须保持单向：测量只产出事实，资格规则解释事实 | proxy-path delay、业务 status、quota 三种结果不能互相代换 |
| Qualification -> Comparator | 必须保持单向：先过滤，再排序 | comparator 不读取 URL、UCI、订阅原文或 runtime 文本 |
| Compiler -> Activation | 通过 staged artifact + manifest 解耦；不能共享可变缓存 | enable 前检查输入身份，readback 用 manifest 对账 |
| Compiler -> 用户可见组名 | 当前由 compiler 用固定中文模板拼接 Mihomo 组名（自动选优 / 主用机场 / 备用机场 / 当前优选 / 代理路径）；`display_name`、`flag` 和 Nikki metadata 只填充可变部分 | 组名变化改 compiler；UI 不得再实现一套拓扑命名；不为 i18n 增加组名配置 |
| Application 实现边界 | `main.uc` 是唯一命令入口和 mutation owner；`application/*.uc` 只拆分同一进程内的 onboarding、配置和 provider 读取事务；`core/activation.uc` 只判定，supervisor/UI/rpcd 只调用 | 不增加第二进程、daemon、锁、状态或 owner，不复制恢复路径 |
| Activation -> Nikki/Mihomo | 是平台适配边界，不应把 Nikki 生命周期复制进 NetFleet | 只调用官方切换/restart/cleanup，并做 effective/runtime readback |
| Runtime selection -> history | 选择器不得依赖历史；evidence 只作有界展示输入 | supervisor 只复用当前轮次，不读取历史、LKG、排名或 generation |
| UI/RPC -> owner | 只读投影/命令转发，不能成为事实源；门槛和延迟着色读 `status.selection` | 无订阅解析、无客户端候选排序或资格判定、无隐式 mutation；展示排序只影响表格，不得写死 150，不得按 capability id 子串猜测图标或文案 |

### YAML 适配边界

NetFleet 自有 policy、platform、ruleset lock、evidence、manifest 和 artifact 均使用 JSON，避免设备版 YAML 工具参与核心对象解析。Nikki/Mihomo 的外部 Profile 仍是 YAML，因此 adapter 只允许用 `yq -M -p yaml -o json` 做一次只读转换；禁止原地编辑、复杂表达式、订阅重写或把 YAML 转换变成第二配置源。真实 canary 已证明 Mihomo 可直接校验 JSON artifact，因此不再保留 JSON -> YAML 转换。yq 不可执行或不支持该最小转换时，compile 直接失败且不改变当前 Profile、DNS、nft 或路由。

因此产品对象和 artifact 边界已经解耦：compiler 经 staged manifest 交给 activation，selector 不读 I/O，UI 不拥有事实，策略输入身份与恢复目标身份也各自绑定。机场无关 `PolicySource(kind=bundle)` 已是默认正常输入；`kind=profile` 只保留为现有目标迁移期间的只读输入，并与 bundle 共用同一个 compiler 和 activation owner。这不等于一文件一 owner；quota I/O 与 JSON/YAML/evidence 同在 `adapters/uci.uc`，`application/*.uc` 只从过大的入口文件拆出同一进程内的 onboarding、配置与 provider 事务，enable/disable/select/recover 仍由 `main.uc` 这一唯一入口拥有。运行时必须继续证明：Policy Source 变化不会静默套用旧 binding；Recovery Profile 变化不会复用旧 manifest；Nikki cache 刷新不会生成第二份节点事实；supervisor 消失时数据面保持、由 `procd` 重启 owner，用户仍能独立从 Nikki 切回。任一 gate 失败都应缩小功能，而不是增加状态层。

纯 Mihomo 拓扑能完成节点/provider/DIRECT 数据面 fallback，但不能在 Mihomo 永久退出、Nikki 的有限 respawn 已耗尽后调用 Nikki 官方 cleanup，也不能按用户要求定期执行跨地区 comparator。因此准入唯一一个前台、无持久调度状态的 `procd` supervisor。它不得扩展为 worker、第二健康算法、业务 URL 轮询器或第二 mutation owner。

## 最小对象

### PolicySource

正常编译策略的唯一输入。Schema v2 接受互斥的 `{"kind":"bundle","ref":"bundle:<stable-id>"}` 与迁移用 `{"kind":"profile","ref":"subscription:...|file:..."}`。bundle 是随包安装的机场无关 JSON Profile 基线，只包含稳定策略、规则和必要的 Mihomo 原语，不包含机场节点、订阅或秘密；profile 只读现有 Nikki Profile。两种输入共用同一个 compiler，manifest 分别绑定 kind、ref 和 digest。

内置 `base-v1` 在海外分流前先将 Tailscale 控制/中继域名、STUN 目标端口 `3478` 以及默认 WireGuard UDP 源/目标端口 `41641` 交给 `DIRECT`。这只防止网络覆盖层的控制和 NAT 打洞流量绕道机场，不承诺对称 NAT 下一定建立直连；设备若修改 Tailscale 监听端口，目标私有配置必须同步声明对应的直连例外。

### RecoveryProfileRef

用户明确选择并独立验证的完整 Nikki Profile。它只用于 enable 前置身份、事务回滚、disable、supervisor recover 和手工原生恢复，不参与正常编译、机场选优或 capability 资格。

### ProviderRef

一个稳定 ID 指向一个 Nikki subscription section，并声明计费类型 `subscription` 或 `buyout`。故障层级 `primary` 或 `reserve` 与计费类型分开；故障层级只决定明确的 fallback 顺序，不是正常速度排序的权重。计费类型只影响同速 tie-break，不得压过真实 delay。剩余流量和到期状态只从 Nikki 官方 subscription metadata 读取，不写回 policy。NetFleet 不识别机场品牌，不下载订阅，也不保存 URL、token 或节点副本。

### Binding

策略来源中一个策略组的精确名称通过对象映射到一个出口能力：`{"capability":"standard","kind":"entry"}` 或 `{"capability":"standard","kind":"policy"}`。每个启用 capability 必须恰有一个 `entry`，compiler 把规则及 Policy Source 内的其他组引用改写到 capability 的可见 selector；当可见名称与原入口名不同时，保留一个隐藏的单跳 alias，从原入口名指向新 selector。该 alias 不包含节点、不参与选择，只为 Nikki 在 Profile 之后应用的全局 mixin 提供跨 Recovery Profile/NetFleet 的稳定引用。`policy` 保留业务组名称并把成员标准化为该 capability 的 `user_members`。同一能力的业务组不需要原始结构等价，也不拥有第二个选择算法。disabled capability 的 binding 保留但不编译，策略来源组逐字保持原行为；未绑定组同样保持原行为。不存在名称猜测或机场硬编码。

### Capability

capability 是通用的 policy 对象，包含稳定 ID、`enabled`、`manual|automatic`、可选允许/排除地区和可选选择门槛；engine 不按 ID 分支。当前产品配置先提供：

- `standard`：普通代理出口；
- `ai-compatible`：AI 分类出口；通过 `excluded_regions` 排除香港，并以 `prefer_region_from` 优先跟随海外加速的合规地区。

当前 Policy Source 已有 OpenAI/Claude 分类组和对应规则，因此 `ai-compatible` 可以作为第二个 automatic capability；它与根能力共用同一个 one-shot selection/activation owner，不增加后台循环或第二证据库。只有真实出口合同不同且现有能力无法表达时，才增加 capability 配置；增加配置不需要新增代码模块。

### RegionPolicy

地区和 provider-region mapping 是 capability-neutral 网络资源；capability 通过允许/排除地区复用它们。地区只标为 `automatic` 或 `manual_only`，并可用纯展示的 `display_order` 固定策略组与配置页中的地区顺序；它不持有 capability 或基础组引用。`display_order` 同值或缺失时按稳定 ID 排序，不能影响选路。unknown 地区不得进入 automatic；AI 的 unknown 地区不得进入未来任何 automatic 候选。

### 配置解耦合同

target-local 配置只保留下列 owner 分区：

- `main`：`target`、`enabled`；
- `policy_source`：优先使用 `kind=bundle` 与稳定 bundle ID；迁移期可使用 `kind=profile` 及 Nikki Profile `ref`；
- `recovery_profile`：独立的 Nikki Profile `ref`；
- `routing_rules`：可选的 target-local 结构化规则，只保存 `domain_suffix`、域名后缀和 capability ID；compiler 将其投影到生成 Profile 的 capability selector，不写入 Nikki 全局 mixin，也不改变 Recovery Profile；
- `provider`：稳定 ID、Nikki subscription section、`subscription|buyout` 计费类型、enabled，以及必需的 `primary|reserve` 故障层级；
- `binding`：基础策略组的精确名称到 `{capability, kind: entry|policy}`；
- `capability`：显示名、纯展示 `display_order`、enabled、`manual|automatic`、允许/排除地区、可选的 `prefer_region_from` 和两个门槛覆盖；
- `region`：稳定 region ID、显示名、可选国旗、纯展示 `display_order` 和 `automatic|manual_only`；
- `provider_regions`：provider 到 region 的显式 filter mapping；
- `selection`：`region_switch_margin_ms: 150` 和 `leaf_switch_margin_ms: 150` 默认值，不拥有模式；
- `automation`：唯一 supervisor 的 enabled、选择周期、轻量状态周期和 runtime grace；
- `checks`：Mihomo delay 与 quota 适配合同；
- `evidence`：唯一固定路径，仅保存有界显示证据；
- `fail_open`：protected probe 列表，以及 path/guard probe ID、timeout、interval 和失败次数组成的 Mihomo fallback healthcheck。

不创建 `ProviderBinding` 与 `ProviderPolicy` 两套存储，不提交订阅 URL、token、节点、resolver 或完整配置。跨设备安装所需的订阅凭据、target-local `routing_rules`、provider bootstrap DNS mixin 和 `platform.json` 属于用户私有 OPL Instance 所生成的 deployment bundle；只有稳定 section ID 被 policy 引用。mixin 只保留确有设备证据的 provider 入口 DNS 例外，不能重新拥有规则、策略组或全局平台值；platform 不是 engine 配置，也不能成为算法分支。未知组、未知能力、歧义引用、未知地区和 AI 香港候选必须在 compile 阶段拒绝或排除。provider source、生成文件和运行快照留在设备私有 state，Git 只保存脱敏合同、机场无关规则与真正被 caller 消费的实现。

设备配置 owner 可以通过结构化 LuCI 请求增删上述 policy 中的 provider、region、capability、binding 和 `routing_rules`，但只能引用设备已经存在的稳定 Nikki subscription、共享地区目录及当前 Policy Source 已存在的策略组。provider ID 使用 subscription section；自动发现与高级编辑共用同一个地区目录和 filter owner，浏览器不能创建正则或节点副本。该能力只把单设备的 policy 结构从 private renderer 迁入 target-local owner，不改变订阅、mixin、platform、Nikki 或 Mihomo 的责任。

### CompiledProfile

同批生成的 JSON 与无秘密 manifest：

- `staged`：已验证但未控制数据面；
- `active`：Nikki 当前 Profile 精确指向该 artifact，且 manifest 身份一致。

唯一内部 artifact 固定为 `/etc/nikki/profiles/opl-netfleet/mvp.json`，同批 manifest 只存在于该内部目录。compiler 另在 Nikki Profile 根目录建立稳定的相对软链接 `/etc/nikki/profiles/OPL-NetFleet.json -> opl-netfleet/mvp.json`，Nikki owner 只写 `file:OPL-NetFleet.json`，使官方 LuCI 的非递归 Profile 列表能够显示当前 owner。该链接不复制配置字节、不承载第二份 manifest，也不是第二事实源；同名普通文件、错误目标或其他 owner 的软链接必须在写 artifact 前拒绝，不能覆盖。历史值 `file:opl-netfleet/mvp.json` 只作为升级时 disable、回滚和卸载保护的有界输入，新 enable 永远不再写它。

active 时禁止结构性 compile。配置变化必须先 disable，再生成新的 staged artifact。
