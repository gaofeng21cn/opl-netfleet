# 产品对象与 Owner

本文是 NetFleet 当前产品边界、核心对象、唯一 owner 和依赖方向的权威合同。测量与选择、
运行事务和公开接口分别由同目录其他文档负责。插件发现、服务绑定、命令路由和代码
生命周期由[微内核与功能插件](microkernel.md)定义；本文只定义各功能服务的业务归属。

## 后端与订阅归属

`/etc/opl-netfleet/backend.json` 是唯一后端选择，值为 `nikki-mihomo` 或
`native-mihomo`；缺省使用前者。选择器是 root 私有 JSON，不能通过普通配置保存
静默切换。安装软件包不启动数据面；切换必须进入显式迁移或首次设置事务。

| 运行边界 | nikki-mihomo | native-mihomo |
| --- | --- | --- |
| UCI namespace | `nikki` | `netfleet` |
| Profile、订阅与运行目录根 | `/etc/nikki` | `/etc/opl-netfleet/native` |
| Mihomo 生命周期 | Nikki 官方 init | `opl-netfleet-core` procd 服务 |
| mixin 与网络接管 | Nikki 官方实现 | 固定版本的 Nikki mixin/nft 模块，由 NetFleet gateway 编排 |
| 订阅编辑与下载 | Nikki；NetFleet 只投影并编排官方更新 | `subscriptions.store`，共用现有设备 mutation lock |

原生订阅使用稳定的 UCI `subscription` section，保留 `name/url/user_agent/info_url/prefer`
和额度、到期、更新元数据语义；policy 只引用 section ID，不保存凭据。缓存路径为
`/etc/opl-netfleet/native/subscriptions/<section>.yaml`，正文保存完整订阅的 JSON 对象，可供同一份编译输入、
恢复 Profile 和 Mihomo file provider 使用。目录 `0700`、私有文件与 UCI 配置 `0600`；
URL、凭据和响应头只经过私有输入文件，不进入命令行、公共状态、日志或 Git；经过认证的
订阅编辑界面可以读取当前来源地址，具体传输与缓存边界见[公开接口](interfaces.md)。

编辑与运行应用分开：保存 URL/UA 不下载、不停服务、不替换当前有效缓存。来源身份改变后
投影为 `pending_update`；仍在使用旧有效缓存时标明 `using_previous_cache`，不能把它
标为当前新来源已接受。旧额度和最近成功时间属于该有效版本；失败更新保留这些事实。
删除必须同时检查 policy、当前 Profile 和 live file-provider 引用，任何真实引用仍存在
都拒绝删除。显示名变化不改变来源或内容身份。

下载支持 HTTP/HTTPS 与独立 info URL，使用系统 CA、私有 curl 配置、有界时间和大小。
完整响应经只读 YAML 转换和真实 `mihomo -t` 后才原子替换；相同内容不重写缓存正文或
mtime，成功时间与额度可以更新。缓存正文摘要与已接受来源身份共同决定
`cache_current`，不能仅凭文件存在声称新来源就绪。更新、重编译、恢复用户模式和失败
回滚由 `refresh.control` 负责，详见[运行事务](runtime-and-recovery.md#activation)。

每月流量重置日归 SubscriptionOwner 的订阅元信息：原生订阅 `quota_reset_day` 为可选 1–31 的整数，显式 `null` 清空、省略保留已有值；认证订阅管理可读写，状态只投影 quota 的 `reset_day` 与 `reset_day_source: manual`。当前标准 `Subscription-Userinfo` 没有可靠月重置日，不能从到期日、URL 或机场名称推算。该字段不进入 policy、下载身份或测速统计身份，保存不下载、不重编译、不重载；订阅刷新保留手工值。它只作套餐参考，不按日期清零用量、解除耗尽或改变可用性；月末日期的实际结算以机场为准。买断制不显示月重置日，未设置不作告警。

## 产品定位

NetFleet 是由微内核组合功能插件的设备端网络管理平台。默认产品提供跨机场、跨地区的
策略、订阅、配置、诊断和运行管理。两种后端共用 policy、compiler、manifest、activation、
selection、evidence、调度插件与 LuCI，使用同一套多机场选择和恢复规则。

`nikki-mihomo` 保留 Nikki 已可独立工作的 Profile、订阅和数据面；NetFleet 是可选增强层。
`native-mihomo` 由 NetFleet 管理订阅与 Mihomo，并复用 Nikki 开源网络接管模块，不要求
安装 Nikki。原生网络接入当前选择 TCP 与 UDP TProxy，默认 DNS 为 redir-host；
Mihomo 自身具备 TUN/Redirect，但 NetFleet 未提供这两种模式的系统接管与恢复适配，
不能把核心已有能力当作插件可切换模式。业务流量 fallback、关闭时恢复原始配置与最终网络直通是不同语义，
任何 backend 都必须遵守相同安全下限。

已有 Nikki 用户通过显式迁移保留订阅、私有 mixin、规则资源与能力配置；空白设备通过
原生首次设置建立订阅和基础运行环境，再进入共享接管向导。sing-box 等后端仍属于
[长期方向](../product/whitepaper.md)，没有可用适配器时不显示为可切换选项。实现、VM
资格验证、公开包和真实设备验收是独立证据层，任何一层不能替另一层宣称完成。

## 能力分层与使用逻辑

Mihomo 始终负责节点连接、组内健康检查、URLTest 与规则执行；所选运行后端负责订阅、Profile、DNS、透明代理和进程生命周期。NetFleet 增强层负责显式出口绑定、跨 provider/地区资源组织与可验证的生成、启用、退回事务。原生后端复用固定版本的 Nikki mixin/nft 实现并保留许可证与来源标注，不另写一套流量分类或选择算法。

| 增强能力 | 用户怎样使用 |
| --- | --- |
| 显式出口绑定 | 每个启用 capability 用一个 `entry` 接管规则出口；`policy` 绑定保留业务分类组名称并复用同一选择面 |
| provider/地区资源引用 | 引用所选后端的真实 subscription section；compiler 使用本地 `type:file` source，不下载或复制节点 |
| 手动地区或直连 | 为已绑定能力选择允许的多机场地区聚合组或 DIRECT，再回读当前链 |
| staged/active 安全激活 | compile 只生成 staged；显式 enable 才切换运行 Profile，失败按统一合同恢复 |
| 关闭与安全卸载 | 优先恢复 Recovery Profile；原生 runtime 恢复失败才停止后端并清理接管 |
| 地区选优与故障转移 | 首次启用、单次选优和到期轮次共用 comparator；运行期 fallback 仍由 Mihomo 执行 |
| 能力资格约束 | capability 显式限定地区，并可通过 `prefer_region_from` 跟随上游能力的合规地区 |
| 设备配置与运行回读 | UI 只投影 owner 状态、编辑结构化配置并提交命令，不解析订阅或排序候选 |

capability 是 policy 中的可组合增强单元，与提供代码和服务的功能插件分别建模。`main.enabled` 是全局启用许可；每个 capability 再独立声明 `enabled`、`manual|automatic`、允许或排除地区和选择门槛；可选 `display_order` 只控制 Profile/status 的显示顺序，同值时按稳定 ID 排序，不能影响选路。每个启用能力必须恰有一个 `entry` binding；它是规则与组引用改写到 capability 可见 selector 的唯一接入点。零个或多个 `policy` binding 保留原业务分类组名称，但把其成员标准化为该 capability 的同一套用户选择面，不复制算法、节点或状态。机场运行层级只由 provider 的 `primary|reserve` role 决定：当前优选失效后先在全部主用机场中选择，主用层全部失效才进入备用机场，最后进入 `DIRECT`。生成 Profile 不复制策略来源组作为第二条 native 路径；恢复整个 Recovery Profile 只属于 enable/select/disable 的事务恢复。该差异完全由数据配置决定，engine 不按 AI、地区、机场或组名分支。全局关闭时允许全部 capability 关闭并保留配置；全局允许启用时至少要有一个 capability 开启。多个 capability 共享 provider/region 资源和同一 activation/Fail-Open owner；disabled capability 可以保留配置和 binding，compiler 直接忽略它并保持对应策略来源组原样。Fail-Open、activation 和 backend 由共享功能服务提供；接管、退出和恢复所需的服务依赖必须完整，插件替换或卸载先完成资源交接。

`policy_source`、`recovery_profile`、`platform.json` 与 provider role 是四个独立 owner 边界：`policy_source` 只决定正常编译所读取的规则、DNS 和策略组；`recovery_profile` 只决定 NetFleet 关闭、事务失败或用户手工切回时由所选后端完整恢复的原生 Profile；Fleet 模式的私有 `platform.json` 只声明 Nikki/OpenWrt 的透明代理、DNS 模式、controller、sniffer、日志和 flow-offload 平台参数；provider role 只决定 NetFleet Profile active 时的主用/备用机场层级。`kind=bundle` 从 `/etc/opl-netfleet/policy-sources/<stable-id>.json` 读取机场无关的 JSON 基线，`kind=profile` 仍可只读引用完整所选后端 Profile；两者共用同一个 compiler、manifest、activation 和 status 路径。恢复 Profile 可以与某个 provider 使用同一个机场，但二者不能互相冒充，也不能复制该机场的节点、DNS 或订阅字节。每个 target 只能选择一份已经独立验证过规则、DNS、保护业务和可用额度的恢复 Profile；机场计费属性不能替代独立验收，也不允许影响 active Profile 的可见策略组或自动排序。

automatic capability 必须形成无环依赖图，并且只有一个不声明 `prefer_region_from` 的根能力。跟随能力先过滤自身的 allowed/excluded 地区和候选资格；根能力选中的地区仍合格时直接复用该地区，否则在自身 primary、reserve 层级中按同一轮 delay 选择最快地区。每轮只对每个 provider 触发一次原生 health-check，再依依赖顺序测量各 capability selector；所有 selector 写入、protected probes 和失败恢复仍属于同一锁内的选择或激活事务，并共享 `recovery.control`。`scheduler.control` 只负责到期调度和进程失联 grace，不实现 comparator、不持久化排名，也不增加第二循环。

模块与策略只通过 policy 组合：全局开关不改变 capability 配置；capability 开关不改变 provider/region 资源；`manual|automatic` 决定可见选择面是否包含自动入口及是否参与周期轮次，不改变资源事实；provider `role` 只决定运行期主用/备用层级；`region_switch_margin_ms` 和 `leaf_switch_margin_ms` 可由 capability 覆盖全局默认。机场角色、计费类型、地区授权、测速合同和保护探针各自保留在独立分区，engine 不按 capability、机场或地区名称分支。

首次设置、编译、启用、退出与 supervisor 的完整顺序由[运行与恢复](runtime-and-recovery.md)维护；
候选测量、地区门槛与同轮能力组合由[选择合同](selection.md)维护。

## 硬下限

1. 默认无副作用：安装 package 和首次发现预览不改变所选后端当前 Profile、selector、DNS、nft、路由或数据面；只有用户确认“一键接管”或显式 deployment action 才可进入 activation 事务。
2. 显式启用：只有用户确认 enable 后，所选后端才能切到 NetFleet 派生 Profile。
3. 上游先决条件：enable 在切换 Profile 前必须确认 WAN interface 已 up 且存在 IPv4 默认路由；上游不可用时保持原 Profile，不触碰当前后端。
4. 原生退路：disable 不依赖 NetFleet supervisor；Nikki 模式也允许从 Nikki 手工切回原始 Profile。
5. 安全卸载：增强层退出优先恢复原始 Profile，失败才进入已验证且持久的 passthrough；卸载原生核心包则必须停止核心并清理其网络接管。不能证明安全终点时拒绝卸载。
6. 生命周期 owner 唯一：Nikki 模式调用 Nikki 官方生命周期；原生模式由 NetFleet gateway 持有进程、接管规则和策略路由。复用的 Nikki 模块保留其来源与许可证，不能让两个后端同时接管网络。
7. 单一控制面：每项状态和 mutation 只有一个 owner，不建立第二套事实、后台投影或恢复循环。
8. 远程可恢复边界：NetFleet 的开发、部署、验收和故障恢复都不包含设备 `reboot`、`poweroff`、`sysupgrade`、固件写入或任何依赖现场/OOB 才能撤销的动作。软件路径无法恢复管理面时必须停止并返回 `needs_local_recovery`，不能把物理操作当成部署步骤。

## Owner

| Owner | 唯一责任 |
| --- | --- |
| Policy Source | 提供流量分类、首条命中规则顺序、原始组名和未绑定组行为；内置 bundle 使用锁定 MRS 做业务分类，但不声明 DNS；`kind=profile` 继续逐字保留原 Profile 规则和 DNS；只作为 compiler 输入 |
| Recovery Profile | NetFleet 关闭、事务失败和进程级恢复时由所选后端选择的完整原始 Profile；不参与正常选优 |
| Platform declaration | Fleet 模式的私有 `platform.json` 声明目标 Nikki UCI 与 OpenWrt flow-offload 值；canonical deploy owner 负责校验、快照、应用、官方 reload/restart 和 readback，不直接生成 nft/ip rule |
| Ruleset lock | 公共 `rulesets.lock.json` 锁定上游 commit、URL、格式、大小、SHA-256 和许可证；提供内置 Policy Source 已引用的业务、地域和私网 MRS，不拥有规则顺序或自动更新 |
| Runtime backend | `platform.runtime` 解析后端身份与 namespace；`mihomo.backend` 统一 Profile、服务和运行回读。Nikki 模式调用官方服务，原生模式由 `mihomo.gateway` 与 `opl-netfleet-core` 持有运行资源，`mihomo.lifecycle` 负责插件更新时的资源交接 |
| Subscription owner | `subscriptions.store` 持有原生订阅的私有编辑、验证下载、有效缓存和元数据；`subscriptions.providers` 与 `subscriptions.facts` 提供编译输入和事实投影。Nikki 模式只读发现并编排官方更新，运行中应用统一交给 `refresh.control` |
| Mihomo | 节点连接、组内健康检查、URLTest delay 和叶子切换 |
| latency adapter | `mihomo.latency` 按 `checks.provider_healthcheck_timeout_ms` 并发触发 provider 原生 health-check，再对候选组当前代理链按 `checks.latency` 做一次有界 delay，输出标准化 delay 或 `unavailable`；不判断业务资格 |
| quota adapter | `platform.subscriptions.subscription_quota` 只读所选后端的 subscription metadata，输出 `available|exhausted|unknown` 和可选剩余量 |
| qualification/comparator | `selection.algorithm` 纯函数消费标准化测量和 policy，先判资格、再按 delay 和显式 tie-break 排序；`selection.round` 编排单轮测量，`selection.control` 持有手动和自动选择事务 |
| NetFleet compiler | `compilation.compiler` 执行纯转换，`compilation.control` 读取显式配置和后端缓存、校验并安装 staged Profile。用户可见 Mihomo 组名使用 compiler 的固定中文模板，不是 UI i18n 或 policy 字段 |
| NetFleet onboarding owner | `configuration.onboarding-model` 从当前 Profile、稳定 subscription cache 和节点名称生成初始 policy 与脱敏预览；`configuration.onboarding` 持有确认后的写入与接管事务，复用编译和激活服务 |
| 平台能力提供者 | 存储、路径、profile、凭据、订阅元数据、设备状态和进程调用分别绑定服务；`platform.files` 与 `platform.service` 提供限定范围的私有文件和服务操作，不形成第二配置源。接口边界见[微内核](microkernel.md#平台能力边界) |
| Native setup owner | `setup.native` 在空白设备上绑定发现 revision，创建私有订阅与 DNS/controller 配置，验证基础 gateway，再交给共享 onboarding；失败恢复设置前状态 |
| Backend migration owner | `setup.migration` 将已工作的 Nikki 私有输入投影到原生 namespace，串行交接后执行共享 compile/enable/readback；失败恢复旧后端，不双写、不常驻 |
| Policy configuration owner | `configuration.editor` 持有 policy 的资源发现、受限编辑和应用事务，复用编译、激活与恢复命令 |
| Network management owner | `network.editor` 通过受限结构管理原生 UCI/mixin 的 DNS、代理范围与监听；只保存声明并调用既有 runtime owner，保留未公开字段，不持有第二套 nft 或路由实现 |
| Maintenance owner | `maintenance.editor` 管理本地 Profile、限定范围的配置备份恢复、核心维护与有界诊断；所有运行变化继续复用既有 activation/runtime owner |
| Dashboard resource owner | `dashboard.control` 管理原生 Zashboard 的已安装资源身份、显式版本检查和可恢复更新；不拥有核心包、controller 或后台更新循环 |
| NetFleet activation owner | `activation.control` 持有 enable、disable 和 resume 事务；`models.activation` 只提供前置条件、active 判定和 passthrough 纯函数 |
| NetFleet recovery owner | `recovery.control` 持有原生恢复、故障直通和事务异常处理；`recovery.state` 保存自动恢复意图；低层 selector 与 DIRECT 路径操作由 `mihomo.paths` 执行 |
| NetFleet scheduler | `scheduler.control` 按 policy 调度共享选优、刷新和故障恢复命令，返回下一轮定时状态；supervisor 引导内核每轮加载当前调度服务，不判断候选、不保存排名、不清理 DNS/nft/路由 |
| Status and events | `status.control`、`status.events`、`status.connections` 组合当前事实；`events.record` 与 `events.store` 持有有界事件，`events.operation` 持有操作进度，均不参与候选排名 |
| Component update owner | `components.control` 发现已安装包和显式 Feed 候选，管理默认产品包组合与可恢复更新；功能插件安装状态来自内核清单 |
| canonical deploy owner | 为 Fleet/可重复运维从精确 Git commit/tree 和私有 deployment bundle 完成兼容性预检、依赖补齐、Nikki 原生基线准备、NetFleet 安装/恢复和 installed parity；它不是独立插件首次设置的前置条件 |
| NetFleet UI | owner 状态的只读投影和有限命令，不拥有配置或算法；门槛、周期、着色和说明只读 status 投影 |
| Plugin host | 按[微内核合同](microkernel.md)解析各插件 manifest 中的服务依赖与命令；HTTPS 兼容和 Zashboard 分别由 `https-compat.control`、`dashboard.control` 提供，不维护静态业务注册表 |

依赖只能向下流动，不能由投影反向写入事实：

```text
PolicySource + target-local config + selected subscription cache
    -> compilation.control / compilation.compiler
    -> staged Profile + manifest
    -> activation.control <- scheduler.control <- supervisor / kernel
    -> selected backend Profile
    -> Mihomo current state
    <- status/UI read-only projection

RecoveryProfileRef
    -> recovery.control <- activation / selection / scheduler
    -> selected backend Recovery Profile (cleanup only if recovery fails)
```

解耦规则如下：Policy Source 只提供编译输入；Recovery Profile 只负责原生恢复；binding 只负责把策略来源中的精确组名接到 capability；capability 只负责开关、资格、地区范围和选择参数；region/provider 是 capability 可复用的网络资源；provider 只引用所选后端的 subscription section；measurement adapters 只负责采样；qualification/comparator 只处理标准化结果；compiler 只做一次性转换，并拥有生成 Profile 的用户可见组名模板。`main.uc` 只引导内核，命令由 manifest 路由到对应功能服务；配置、订阅、编译、激活、选择和恢复各自持有事务，复用同一设备 mutation lock。UI/transport 只投影和转发。非 owner 模块不得维护第二份可刷新的订阅事实、私自改写 DNS/nft/路由或从 runtime snapshot 反向修改配置；订阅和 gateway 各自在其限定写集内执行已授权事务。若设备不能消费 `type:file` provider source，compile 必须失败并保持 Recovery Profile，不得引入第二下载器或节点副本。新的功能插件通过声明服务依赖组合现有 owner，不能借插件边界复制订阅事实、恢复路径或后台循环。

### YAML 适配边界

NetFleet 自有 policy、platform、ruleset lock、evidence、manifest 和 artifact 均使用 JSON，避免设备版 YAML 工具参与核心对象解析。Mihomo 的外部 Profile 仍是 YAML，因此 adapter 只允许用 `yq -M -p yaml -o json` 做一次只读转换；禁止原地编辑、复杂表达式或把 YAML 转换变成第二配置源。Mihomo 可直接校验 JSON artifact，因此不保留 JSON -> YAML 转换。yq 不可执行或不支持该最小转换时，compile 直接失败且不改变当前 Profile、DNS、nft 或路由。

## 最小对象

### PolicySource

正常编译策略的唯一输入。Schema v2 接受互斥的 `{"kind":"bundle","ref":"bundle:<stable-id>"}` 与 Profile 输入 `{"kind":"profile","ref":"subscription:...|file:..."}`。bundle 是随包安装的机场无关 JSON Profile 基线，只包含稳定策略、规则和必要的 Mihomo 原语，不包含机场节点、订阅或秘密；profile 只读所选后端的原始 Profile。两种输入共用同一个 compiler，manifest 分别绑定 kind、ref 和 digest。

内置 `base-v1` 在海外分流前先将 Tailscale 控制/中继域名、STUN 目标端口 `3478` 以及默认 WireGuard UDP 源/目标端口 `41641` 交给 `DIRECT`。这只防止网络覆盖层的控制和 NAT 打洞流量绕道机场，不承诺对称 NAT 下一定建立直连；设备若修改 Tailscale 监听端口，目标私有配置必须同步声明对应的直连例外。

### RecoveryProfileRef

用户明确选择并独立验证的完整原始 Profile。它只用于 enable 前置身份、事务回滚、disable、supervisor recover 和手工原生恢复，不参与正常编译、机场选优或 capability 资格。

### ProviderRef

一个稳定 ID 指向所选后端的 subscription section，并声明计费类型 `subscription` 或 `buyout`。故障层级 `primary` 或 `reserve` 与计费类型分开；故障层级只决定明确的 fallback 顺序，不是正常速度排序的权重。计费类型不参与 comparator；同速 tie-break 读取已知剩余量与稳定身份，详见[选择合同](selection.md)。剩余流量和到期状态只从所选后端的 subscription metadata 读取，不写回 policy。selection/compiler 不识别机场品牌、不下载订阅，也不保存 URL、token 或节点副本；私有输入由唯一订阅 owner 持有。

### Binding

策略来源中一个策略组的精确名称通过对象映射到一个出口能力：`{"capability":"standard","kind":"entry"}` 或 `{"capability":"standard","kind":"policy"}`。每个启用 capability 必须恰有一个 `entry`，compiler 把规则及 Policy Source 内的其他组引用改写到 capability 的可见 selector；当可见名称与原入口名不同时，保留一个隐藏的单跳 alias，从原入口名指向新 selector。该 alias 不包含节点、不参与选择，只为所选后端在 Profile 之后应用的全局 mixin 提供跨 Recovery Profile/NetFleet 的稳定引用。`policy` 保留业务组名称并把成员标准化为该 capability 的 `user_members`。同一能力的业务组不需要原始结构等价，也不拥有第二个选择算法。disabled capability 的 binding 保留但不编译，策略来源组逐字保持原行为；未绑定组同样保持原行为。不存在名称猜测或机场硬编码。

### Capability

capability 是通用的 policy 对象，包含稳定 ID、`enabled`、`manual|automatic`、可选允许/排除地区和可选选择门槛；engine 不按 ID 分支。当前产品配置先提供：

- `standard`：普通代理出口；
- `ai-compatible`：AI 分类出口；通过 `excluded_regions` 排除香港，并以 `prefer_region_from` 优先跟随海外加速的合规地区。

当前 Policy Source 已有 OpenAI/Claude 分类组和对应规则，因此 `ai-compatible` 可以作为第二个 automatic capability；它与根能力共用同一个 one-shot selection/activation owner，不增加后台循环或第二证据库。只有真实出口合同不同且现有能力无法表达时，才增加 capability 配置；增加配置不需要新增代码模块。

### RegionPolicy

地区和 provider-region mapping 是 capability-neutral 网络资源；capability 通过允许/排除地区复用它们。地区只标为 `automatic` 或 `manual_only`，并可用纯展示的 `display_order` 固定策略组与配置页中的地区顺序；它不持有 capability 或基础组引用。`display_order` 同值或缺失时按稳定 ID 排序，不能影响选路。未声明或未获授权地区不得进入 automatic。

### 配置解耦合同

target-local 配置只保留下列 owner 分区：

- `main`：`target`、`enabled`；
- `policy_source`：优先使用 `kind=bundle` 与稳定 bundle ID；也可使用 `kind=profile` 及所选后端 Profile `ref`；
- `recovery_profile`：独立的所选后端 Profile `ref`；
- `routing_rules`：可选的有序 target-local 规则，`kind` 为 `domain_suffix` 或 `ip_cidr`，`value` 为域名后缀或 IPv4/IPv6 网络前缀；目标二选一：`capability` 引用启用能力，或 `target:"direct"` 表示直连且不得同时携带 capability。地址由平台 IP 解析器校验，CIDR 必须没有主机位，IPv6 规范化后判重。compiler 只将规则投影到生成 Profile，不写入后端全局 mixin，也不改变 Recovery Profile；
- `provider`：稳定 ID、所选后端 subscription section、`subscription|buyout` 计费类型、enabled，以及必需的 `primary|reserve` 故障层级；
- `binding`：基础策略组的精确名称到 `{capability, kind: entry|policy}`；
- `capability`：显示名、纯展示 `display_order`、enabled、`manual|automatic`、允许/排除地区、可选的 `prefer_region_from` 和两个门槛覆盖；
- `region`：稳定 region ID、显示名、可选国旗、纯展示 `display_order` 和 `automatic|manual_only`；
- `provider_regions`：provider 到 region 的显式 filter mapping；
- `selection`：`region_switch_margin_ms: 150` 和 `leaf_switch_margin_ms: 150` 默认值，不拥有模式；
- `automation`：`scheduler.control` 的选择开关、选择周期、轻量状态周期和 runtime grace；
- `checks`：Mihomo delay 与 quota 适配合同；
- `evidence`：唯一固定路径，仅保存有界显示证据；
- `fail_open`：protected probe 列表，以及 path/guard probe ID、timeout、interval 和失败次数组成的 Mihomo fallback healthcheck。

不创建 `ProviderBinding` 与 `ProviderPolicy` 两套存储，不提交订阅 URL、token、节点、resolver 或完整配置。跨设备安装所需的订阅凭据、target-local `routing_rules`、provider bootstrap DNS mixin 和 `platform.json` 属于用户私有 OPL Instance 所生成的 deployment bundle；只有稳定 section ID 被 policy 引用。mixin 只保留确有设备证据的 provider 入口 DNS 例外，不能重新拥有规则、策略组或全局平台值；platform 不是 engine 配置，也不能成为算法分支。未知组、未知能力、歧义引用和未授权地区必须在 compile 阶段拒绝或排除；地区排除由 capability 配置决定。provider source、生成文件和运行快照留在设备私有 state，Git 只保存脱敏合同、机场无关规则与真正被 caller 消费的实现。

设备配置 owner 可以通过结构化 LuCI 请求增删上述 policy 中的 provider、region、capability、binding 和 `routing_rules`，但只能引用设备已经存在的稳定 subscription、共享地区目录及当前 Policy Source 已存在的策略组。provider ID 使用 subscription section；自动发现与高级编辑共用同一个地区目录和 filter owner，浏览器不能创建正则或节点副本。该能力只把单设备的 policy 结构从 private renderer 迁入 target-local owner，不改变订阅 owner、mixin、platform 或 Mihomo 的责任。

原生网络声明与本地配置文件属于独立管理对象，不增加 policy 分区。network owner 的受限
表单修改当前 gateway 已消费的 UCI/mixin；maintenance owner 管理私有 Profile 和备份。
二者都不能把运行快照变成另一份配置源，也不能通过通用 JSON/UCI 编辑绕过已选后端的
安全边界。详细对象、文件范围和恢复合同统一见[设备独立管理](management.md)。

### CompiledProfile

同批生成的 JSON 与无秘密 manifest：

- `staged`：已验证但未控制数据面；
- `active`：所选后端当前 Profile 精确指向该 artifact，且 manifest 身份一致。

唯一内部 artifact 为所选后端根目录下的 `profiles/opl-netfleet/mvp.json`，manifest 同目录。`profiles/OPL-NetFleet.json -> opl-netfleet/mvp.json` 是稳定相对软链接；运行 owner 使用 `file:OPL-NetFleet.json`。Nikki 根为 `/etc/nikki`，原生根为 `/etc/opl-netfleet/native`，引用语义和生成算法相同。该链接不复制配置或 manifest；同名普通文件、错误目标或其他 owner 的软链接必须在写 artifact 前拒绝。

active 时禁止结构性 compile。配置变化必须先 disable，再生成新的 staged artifact。
