# 产品对象与 Owner

本文是 NetFleet 当前产品边界、核心对象、唯一 owner 和依赖方向的权威合同。测量与选择、
运行事务和公开接口分别由同目录其他文档负责。

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
| 订阅编辑与下载 | Nikki；NetFleet 只投影并编排官方更新 | `application/subscriptions.uc`，共用现有设备 mutation lock |

原生订阅使用稳定的 UCI `subscription` section，保留 `name/url/user_agent/info_url/prefer`
和额度、到期、更新元数据语义；policy 只引用 section ID，不保存凭据。缓存路径为
`/etc/opl-netfleet/native/subscriptions/<section>.yaml`，正文保存完整订阅的 JSON 对象，可供同一份编译输入、
恢复 Profile 和 Mihomo file provider 使用。目录 `0700`、私有文件与 UCI 配置 `0600`；
URL、凭据和响应头只经过私有输入文件，不进入命令行、UI 返回值、日志或 Git。

编辑与运行应用分开：保存 URL/UA 不下载、不停服务、不替换当前有效缓存。来源身份改变后
投影为 `pending_update`；仍在使用旧有效缓存时标明 `using_previous_cache`，不能把它
标为当前新来源已接受。旧额度和最近成功时间属于该有效版本；失败更新保留这些事实。
删除必须同时检查 policy、当前 Profile 和 live file-provider 引用，任何真实引用仍存在
都拒绝删除。显示名变化不改变来源或内容身份。

下载支持 HTTP/HTTPS 与独立 info URL，使用系统 CA、私有 curl 配置、有界时间和大小。
完整响应经只读 YAML 转换和真实 `mihomo -t` 后才原子替换；相同内容不重写缓存正文或
mtime，成功时间与额度可以更新。缓存正文摘要与已接受来源身份共同决定
`cache_current`，不能仅凭文件存在声称新来源就绪。更新、重编译、恢复用户模式和失败
回滚由共享 refresh owner 负责，详见[运行事务](runtime-and-recovery.md#activation)。

## 产品定位

NetFleet 统一提供跨机场、跨地区的网络增强策略和设备端管理。两种后端共用同一个
policy、compiler、manifest、activation、selection、evidence、supervisor 与 LuCI；
不因去除 Nikki 依赖而增加第二选择器或降低原有多机场能力。

`nikki-mihomo` 保留 Nikki 已可独立工作的 Profile、订阅和数据面；NetFleet 是可选增强层。
`native-mihomo` 由 NetFleet 管理订阅与 Mihomo，并复用 Nikki 开源网络接管模块，不要求
安装 Nikki。它当前只支持 TCP 与 UDP TProxy，不支持 redirect 或 TUN；原生默认 DNS
为 redir-host。业务流量 fallback、关闭时恢复原始配置与最终网络直通是不同语义，
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

capability 是 policy 中的可组合增强单元，不是动态代码插件、进程或第二控制面。`main.enabled` 是全局启用许可；每个 capability 再独立声明 `enabled`、`manual|automatic`、允许或排除地区和选择门槛；可选 `display_order` 只控制 Profile/status 的显示顺序，同值时按稳定 ID 排序，不能影响选路。每个启用能力必须恰有一个 `entry` binding；它是规则与组引用改写到 capability 可见 selector 的唯一接入点。零个或多个 `policy` binding 保留原业务分类组名称，但把其成员标准化为该 capability 的同一套用户选择面，不复制算法、节点或状态。机场运行层级只由 provider 的 `primary|reserve` role 决定：当前优选失效后先在全部主用机场中选择，主用层全部失效才进入备用机场，最后进入 `DIRECT`。生成 Profile 不复制策略来源组作为第二条 native 路径；恢复整个 Recovery Profile 只属于 enable/select/disable 的事务恢复。该差异完全由数据配置决定，engine 不按 AI、地区、机场或组名分支。全局关闭时允许全部 capability 关闭并保留配置；全局允许启用时至少要有一个 capability 开启。多个 capability 共享 provider/region 资源和同一 activation/Fail-Open owner；disabled capability 可以保留配置和 binding，compiler 直接忽略它并保持对应策略来源组原样。Fail-Open、activation 和 backend adapter 是公共且不可关闭的安全底座。

`policy_source`、`recovery_profile`、`platform.json` 与 provider role 是四个独立 owner 边界：`policy_source` 只决定正常编译所读取的规则、DNS 和策略组；`recovery_profile` 只决定 NetFleet 关闭、事务失败或用户手工切回时由所选后端完整恢复的原生 Profile；Fleet 模式的私有 `platform.json` 只声明 Nikki/OpenWrt 的透明代理、DNS 模式、controller、sniffer、日志和 flow-offload 平台参数；provider role 只决定 NetFleet Profile active 时的主用/备用机场层级。`kind=bundle` 从 `/etc/opl-netfleet/policy-sources/<stable-id>.json` 读取机场无关的 JSON 基线，`kind=profile` 仍可只读引用完整所选后端 Profile；两者共用同一个 compiler、manifest、activation 和 status 路径。恢复 Profile 可以与某个 provider 使用同一个机场，但二者不能互相冒充，也不能复制该机场的节点、DNS 或订阅字节。每个 target 只能选择一份已经独立验证过规则、DNS、保护业务和可用额度的恢复 Profile；机场计费属性不能替代独立验收，也不允许影响 active Profile 的可见策略组或自动排序。

automatic capability 必须形成无环依赖图，并且只有一个不声明 `prefer_region_from` 的根能力。跟随能力先过滤自身的 allowed/excluded 地区和候选资格；根能力选中的地区仍合格时直接复用该地区，否则在自身 primary、reserve 层级中按同一轮 delay 选择最快地区。每轮只对每个 provider 触发一次原生 health-check，再依依赖顺序测量各 capability selector；所有 selector 写入、protected probes 和失败恢复仍属于同一个原子 activation owner。supervisor 只负责到期调度和进程失联 grace，不实现 comparator、不持久化排名，也不增加第二循环。

模块与策略只通过 policy 组合：全局开关不改变 capability 配置；capability 开关不改变 provider/region 资源；`manual|automatic` 决定可见选择面是否包含自动入口及是否参与周期轮次，不改变资源事实；provider `role` 只决定运行期主用/备用层级；`region_switch_margin_ms` 和 `leaf_switch_margin_ms` 可由 capability 覆盖全局默认。机场角色、计费类型、地区授权、测速合同和保护探针各自保留在独立分区，engine 不按 capability、机场或地区名称分支。

共享接管流程从所选后端已经运行并验证的原始 Profile 开始；安装 NetFleet 后由首次设置读取当前 Profile、稳定命名 subscription cache、原始策略组和真实节点名称，生成不含 URL/token/节点正文的接管预览。发现器只把 cache 中实际存在可用节点的已知地区写入初始 policy，所有机场默认属于主用层，不从名称、计费属性或顺序猜测备用角色。发现器优先绑定原 Profile 的 `MATCH` 目标组；无法唯一识别入口组、没有有效订阅 cache、当前 Profile 不是可恢复原生 Profile 或当前 backend owner 不健康时拒绝接管。用户一次确认后，activation owner 原子完成 `policy 写入 -> compile -> enable -> supervisor enable/start -> owner readback`；任一步失败都恢复原 Profile 并删除本次生成的 policy/artifact。之后由所选后端与 Mihomo 继续负责数据面。高级用户仍可在 LuCI 调整 provider role、地区和 capability；Fleet 运维也可继续通过 deployment bundle 提供精确声明。

自动选优在 enable 初次决定、用户明确触发和 `automation.selection_interval_seconds` 到期时执行同一个有界候选轮次；不并发重入，不为后台另建算法或证据。当前地区仍有合格叶子时，只有最快替代地区比当前代表叶子的 Mihomo proxy-path delay 至少快 `selection.region_switch_margin_ms`（默认 150）才切换；当前地区无合格叶子时不受该门槛限制。`checks.latency` 只负责速度排序，`fail_open.probes` 负责事务提交和运行期 fallback 资格，quota 只作同速 tie-break；三者不能互相代换。

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
| Runtime backend | `adapters/runtime.uc` 只解析后端身份与 namespace；`adapters/backend.uc` 统一 Profile、服务和运行回读。Nikki 模式调用官方服务，原生模式调用 `native_gateway.uc` 与 `opl-netfleet-core` |
| Subscription owner | Nikki 模式只读发现并编排官方更新；原生模式拥有 `netfleet` subscription 的私有编辑、验证下载、有效缓存和元数据。运行中应用统一交给 main refresh，不持有选择算法或独立后台循环 |
| Mihomo | 节点连接、组内健康检查、URLTest delay 和叶子切换 |
| latency adapter | 按 `checks.provider_healthcheck_timeout_ms` 并发触发 provider 原生 health-check，再对候选组当前代理链按 `checks.latency` 做一次有界 delay，输出标准化 delay 或 `unavailable`；不判断业务资格 |
| quota adapter | 只读所选后端的 subscription metadata，输出 `available|exhausted|unknown` 和可选剩余量 |
| qualification/comparator | 纯函数消费标准化测量和 policy，先判资格、再按 delay 和显式 tie-break 排序；不执行 I/O |
| NetFleet compiler | 一次性读取显式配置和所选后端本地缓存，生成一个 staged 派生 Profile；用户可见 Mihomo 组名由 compiler 用固定中文模板拼接，不是 UI i18n，也不是 policy 字段 |
| NetFleet onboarding owner | 纯发现逻辑从所选后端当前 Profile、稳定 subscription cache 和节点名称生成初始 policy 与脱敏预览；不读取订阅 URL、不下载节点、不猜备用角色，写入和接管仍交给 `main.uc` activation owner |
| NetFleet I/O adapter | `adapters/uci.uc` 提供 JSON/YAML、UCI、quota、摘要和 evidence 的共享 I/O；私有文件与服务助手只在各 owner 的限定写集内使用，不形成第二配置源 |
| Native setup owner | 在空白设备上绑定发现 revision，创建私有订阅与 DNS/controller 配置，验证基础 gateway，再交给共享 onboarding；失败恢复设置前状态 |
| Backend migration owner | 将已工作的 Nikki 私有输入投影到原生 namespace，串行交接后执行共享 compile/enable/readback；失败恢复旧后端，不双写、不常驻 |
| NetFleet activation owner | 唯一 one-shot 进程是 `main.uc`，执行 compile、enable、disable 和有限 select 事务；`core/activation.uc` 只提供前置条件、active 判定和 passthrough 纯函数，不持有 I/O 或恢复循环 |
| NetFleet supervisor | 只在 policy 允许时调度既有 automatic 轮次，并在 active runtime 连续失联超过 grace 后调用既有 recovery owner；不判断候选、不保存排名、不清理 DNS/nft/路由 |
| canonical deploy owner | 为 Fleet/可重复运维从精确 Git commit/tree 和私有 deployment bundle 完成兼容性预检、依赖补齐、Nikki 原生基线准备、NetFleet 安装/恢复和 installed parity；它不是独立插件首次设置的前置条件 |
| NetFleet UI | owner 状态的只读投影和有限命令，不拥有配置或算法；门槛、周期、着色和说明只读 status 投影 |

依赖只能向下流动，不能由投影反向写入事实：

```text
PolicySource + target-local config + selected subscription cache
    -> one-shot compiler
    -> staged Profile + manifest
    -> activation owner <- one procd supervisor (schedule / runtime grace only)
    -> selected backend Profile
    -> Mihomo current state
    <- status/UI read-only projection

RecoveryProfileRef
    -> activation rollback / disable / recover
    -> selected backend Recovery Profile (cleanup only if recovery fails)
```

解耦规则如下：Policy Source 只提供编译输入；Recovery Profile 只负责原生恢复；binding 只负责把策略来源中的精确组名接到 capability；capability 只负责开关、资格、地区范围和选择参数；region/provider 是 capability 可复用的网络资源；provider 只引用所选后端的 subscription section；measurement adapters 只负责采样；qualification/comparator 只处理标准化结果；compiler 只做一次性转换，并拥有生成 Profile 的用户可见组名模板；`main.uc` 是唯一命令入口和 mutation owner，`application/onboarding.uc`、`application/configuration.uc` 只承载同一进程内的事务实现；UI/transport 只投影和转发。非 owner 模块不得维护第二份可刷新的订阅事实、私自改写 DNS/nft/路由或从 runtime snapshot 反向修改配置；订阅和 gateway 各自在其限定写集内执行已授权事务。若设备不能消费 `type:file` provider source，compile 必须失败并保持 Recovery Profile，不得引入第二下载器或节点副本。没有新的激活合同和真实 caller 时，不增加第二进程、daemon、锁、状态或 owner，不把组名模板做成配置系统，也不为伪节点卫生正则增加独立 policy 分区。

### 解耦审查结论

| 边界 | 结论 | 必须保留的证明 |
| --- | --- | --- |
| PolicySource -> Binding | 这是有意的窄耦合：NetFleet 必须知道用户要增强哪个真实组，但不能猜名称 | 策略来源身份/组清单 digest；组不存在或变化时 compile 拒绝 |
| RecoveryProfile -> Activation | 已与正常编译输入解耦；只供 enable 前置、rollback、disable 和 recover 使用 | 独立 ref/digest；原生 owner/runtime readback |
| Binding -> Capability | 已解耦；binding 只声明 `entry|policy` 和 capability，不知道 provider、节点或地区 | 每个启用 capability 恰有一个 `entry`；`policy` 组只复用 capability 用户选择面；disabled binding 保持原组不变 |
| Capability -> Region/Provider | 需要保持单向：capability 定资格，region 定范围，provider 定订阅来源和角色 | 不产生第二套 ProviderPolicy；未知资格不进入候选 |
| Measurement -> Qualification | 必须保持单向：测量只产出事实，资格规则解释事实 | proxy-path delay、业务 status、quota 三种结果不能互相代换 |
| Qualification -> Comparator | 必须保持单向：先过滤，再排序 | comparator 不读取 URL、UCI、订阅原文或 runtime 文本 |
| Compiler -> Activation | 通过 staged artifact + manifest 解耦；不能共享可变缓存 | enable 前检查输入身份，readback 用 manifest 对账 |
| Compiler -> 用户可见组名 | 当前由 compiler 用固定中文模板拼接 Mihomo 组名（自动选优 / 主用机场 / 备用机场 / 当前优选 / 代理路径）；`display_name`、`flag` 和所选后端 metadata 只填充可变部分 | 组名变化改 compiler；UI 不得再实现一套拓扑命名；不为 i18n 增加组名配置 |
| Application 实现边界 | `main.uc` 是唯一命令入口和 mutation owner；`application/*.uc` 只拆分同一进程内的 onboarding、配置和 provider 读取事务；`core/activation.uc` 只判定，supervisor/UI/rpcd 只调用 | 不增加第二进程、daemon、锁、状态或 owner，不复制恢复路径 |
| Activation -> Runtime backend/Mihomo | 是运行平台适配边界，共享业务算法不直接实现网络接管 | Nikki 模式调用官方生命周期；原生 gateway 复用上游 mixin/nft 并持有有界清理，均做 effective/runtime readback |
| Runtime selection -> history | 选择器不得依赖历史；evidence 只作有界展示输入 | supervisor 只复用当前轮次，不读取历史、LKG、排名或 generation |
| UI/RPC -> owner | 只读投影/命令转发，不能成为事实源；门槛和延迟着色读 `status.selection` | 无订阅解析、无客户端候选排序或资格判定、无隐式 mutation；展示排序只影响表格，不得写死 150，不得按 capability id 子串猜测图标或文案 |

### YAML 适配边界

NetFleet 自有 policy、platform、ruleset lock、evidence、manifest 和 artifact 均使用 JSON，避免设备版 YAML 工具参与核心对象解析。Mihomo 的外部 Profile 仍是 YAML，因此 adapter 只允许用 `yq -M -p yaml -o json` 做一次只读转换；禁止原地编辑、复杂表达式或把 YAML 转换变成第二配置源。Mihomo 可直接校验 JSON artifact，因此不保留 JSON -> YAML 转换。yq 不可执行或不支持该最小转换时，compile 直接失败且不改变当前 Profile、DNS、nft 或路由。

因此产品对象和 artifact 边界已经解耦：compiler 经 staged manifest 交给 activation，selector 不读 I/O，UI 不拥有事实，策略输入身份与恢复目标身份也各自绑定。机场无关 `PolicySource(kind=bundle)` 可作为正常输入；`kind=profile` 作为已有 Profile 与首次设置的只读输入，并与 bundle 共用同一个 compiler 和 activation owner。这不等于一文件一 owner；quota I/O 与 JSON/YAML/evidence 同在 `adapters/uci.uc`，`application/*.uc` 只从过大的入口文件拆出同一进程内的 onboarding、配置与 provider 事务，enable/disable/select/recover 仍由 `main.uc` 这一唯一入口拥有。运行时必须继续证明：Policy Source 变化不会静默套用旧 binding；Recovery Profile 变化不会复用旧 manifest；订阅 cache 刷新不会生成第二份节点事实；supervisor 消失时数据面保持、由 `procd` 重启 owner，用户仍能调用关闭 owner 恢复原始配置。任一 gate 失败都应缩小功能，而不是增加状态层。

纯 Mihomo 拓扑能完成节点/provider/DIRECT 数据面 fallback，但不能在 Mihomo 永久退出、后端的有限 respawn 已耗尽后完成网络清理，也不能按用户要求定期执行跨地区 comparator。因此准入唯一一个前台、无持久调度状态的 `procd` supervisor。它不得扩展为 worker、第二健康算法、业务 URL 轮询器或第二 mutation owner。

## 最小对象

### PolicySource

正常编译策略的唯一输入。Schema v2 接受互斥的 `{"kind":"bundle","ref":"bundle:<stable-id>"}` 与 Profile 输入 `{"kind":"profile","ref":"subscription:...|file:..."}`。bundle 是随包安装的机场无关 JSON Profile 基线，只包含稳定策略、规则和必要的 Mihomo 原语，不包含机场节点、订阅或秘密；profile 只读所选后端的原始 Profile。两种输入共用同一个 compiler，manifest 分别绑定 kind、ref 和 digest。

内置 `base-v1` 在海外分流前先将 Tailscale 控制/中继域名、STUN 目标端口 `3478` 以及默认 WireGuard UDP 源/目标端口 `41641` 交给 `DIRECT`。这只防止网络覆盖层的控制和 NAT 打洞流量绕道机场，不承诺对称 NAT 下一定建立直连；设备若修改 Tailscale 监听端口，目标私有配置必须同步声明对应的直连例外。

### RecoveryProfileRef

用户明确选择并独立验证的完整原始 Profile。它只用于 enable 前置身份、事务回滚、disable、supervisor recover 和手工原生恢复，不参与正常编译、机场选优或 capability 资格。

### ProviderRef

一个稳定 ID 指向所选后端的 subscription section，并声明计费类型 `subscription` 或 `buyout`。故障层级 `primary` 或 `reserve` 与计费类型分开；故障层级只决定明确的 fallback 顺序，不是正常速度排序的权重。计费类型只影响同速 tie-break，不得压过真实 delay。剩余流量和到期状态只从所选后端的 subscription metadata 读取，不写回 policy。selection/compiler 不识别机场品牌、不下载订阅，也不保存 URL、token 或节点副本；私有输入由唯一订阅 owner 持有。

### Binding

策略来源中一个策略组的精确名称通过对象映射到一个出口能力：`{"capability":"standard","kind":"entry"}` 或 `{"capability":"standard","kind":"policy"}`。每个启用 capability 必须恰有一个 `entry`，compiler 把规则及 Policy Source 内的其他组引用改写到 capability 的可见 selector；当可见名称与原入口名不同时，保留一个隐藏的单跳 alias，从原入口名指向新 selector。该 alias 不包含节点、不参与选择，只为所选后端在 Profile 之后应用的全局 mixin 提供跨 Recovery Profile/NetFleet 的稳定引用。`policy` 保留业务组名称并把成员标准化为该 capability 的 `user_members`。同一能力的业务组不需要原始结构等价，也不拥有第二个选择算法。disabled capability 的 binding 保留但不编译，策略来源组逐字保持原行为；未绑定组同样保持原行为。不存在名称猜测或机场硬编码。

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
- `policy_source`：优先使用 `kind=bundle` 与稳定 bundle ID；也可使用 `kind=profile` 及所选后端 Profile `ref`；
- `recovery_profile`：独立的所选后端 Profile `ref`；
- `routing_rules`：可选的 target-local 结构化规则，只保存 `domain_suffix`、域名后缀和 capability ID；compiler 将其投影到生成 Profile 的 capability selector，不写入后端全局 mixin，也不改变 Recovery Profile；
- `provider`：稳定 ID、所选后端 subscription section、`subscription|buyout` 计费类型、enabled，以及必需的 `primary|reserve` 故障层级；
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

设备配置 owner 可以通过结构化 LuCI 请求增删上述 policy 中的 provider、region、capability、binding 和 `routing_rules`，但只能引用设备已经存在的稳定 subscription、共享地区目录及当前 Policy Source 已存在的策略组。provider ID 使用 subscription section；自动发现与高级编辑共用同一个地区目录和 filter owner，浏览器不能创建正则或节点副本。该能力只把单设备的 policy 结构从 private renderer 迁入 target-local owner，不改变订阅 owner、mixin、platform 或 Mihomo 的责任。

### CompiledProfile

同批生成的 JSON 与无秘密 manifest：

- `staged`：已验证但未控制数据面；
- `active`：所选后端当前 Profile 精确指向该 artifact，且 manifest 身份一致。

唯一内部 artifact 为所选后端根目录下的 `profiles/opl-netfleet/mvp.json`，manifest 同目录。`profiles/OPL-NetFleet.json -> opl-netfleet/mvp.json` 是稳定相对软链接；运行 owner 使用 `file:OPL-NetFleet.json`。Nikki 根为 `/etc/nikki`，原生根为 `/etc/opl-netfleet/native`，引用语义和生成算法相同。该链接不复制配置或 manifest；同名普通文件、错误目标或其他 owner 的软链接必须在写 artifact 前拒绝。

active 时禁止结构性 compile。配置变化必须先 disable，再生成新的 staged artifact。
