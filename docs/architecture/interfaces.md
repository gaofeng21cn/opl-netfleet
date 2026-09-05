# 公开接口与 UI

本文是 NetFleet 当前 RPC、状态投影、React 本地参考面、原生 LuCI 页面和浏览器缓存边界的
权威合同。视觉语言由 [UI 设计合同](../design/ui.md)负责。

## 原生准备 CLI

原生来源只提供 root CLI：`main.uc native-sources-get` 返回脱敏来源和缓存状态；
`main.uc native-sources-set <private-json-file>` 完整保存来源清单；
`main.uc native-sources-refresh [source-id]` 刷新指定来源或全部启用来源。
set/refresh 内部取得现有全局 mutation lock，锁忙时零写入拒绝，调用者不得重复包裹同一锁。
返回值只包含来源 ID、显示名、启用状态、就绪状态、节点数、内容摘要、更新时间和错误代码；
不返回 URL、user-agent、节点或上游错误正文。非法输入只报告字段错误和条目位置。
这些入口无需已存在 policy 或运行中的 Nikki，但只完成[原生订阅准备](domain-model.md#原生订阅准备)，
不允许由现有 RPC、React 桥接或 supervisor 隐式调用。

## 当前运行接口

原生核心另提供 root CLI：`native-core-stage <private-compiled-json-file>`、
`native-core-start`、`native-core-status`、`native-core-stop`。stage 的可选 mixed 端口取编译
输入的 `mixed-port`，缺省为 `17890`，只接受非特权 TCP 端口。状态仅报告 prepared、running、
controller_ready、listener_ready、mixed_port 和配置摘要，不返回节点或编译正文；`transparent_proxy=false`
明确表示没有接管 LAN。详细边界见[原生核心生命周期](runtime-and-recovery.md#原生核心生命周期)。
这些命令不暴露为 LuCI/RPC，也不由现有 Nikki supervisor 调度。

原生 LuCI 是当前第一个真实公开 caller，接口只提供：

- `status`：一次读取 policy、manifest、最近一次 evidence、服务状态、package 自有 build identity（source 部署时回退部署器原子持久化身份），以及 Mihomo `/proxies` 和 `/providers/proxies` 各一次；安装身份只投影经过格式校验的 NetFleet 版本、source commit 和 source tree，供用户确认当前设备字节并用于静态资源缓存失效，不参与运行决策；`apk upgrade` 后 package identity 必须优先于可能仍属于上一次声明式部署的 `installed.json`，避免状态页继续报告旧代码；当前已承载流量的 capability 以健康的生成 URLTest 组、组内当前成员和 manifest 绑定 source 中唯一的真实代理身份投影当前叶子，`/providers/proxies` 的节点 `alive` 只补充下一轮候选与机场/地区库存健康，不能用可能滞后的单节点健康位推翻当前组和独立 protected probes 已证明的实际路径；机场节点库存按 manifest 绑定的 source 从 `/providers/proxies` 读取、按节点名去重并独立投影 `available_node_count/node_count/node_count_known`，不能把跨 capability 的地区候选组 `available_count/candidate_count` 标成节点；同一读取还经第一阶段 SubscriptionOwner 投影顶层 `subscriptions`：每个已启用订阅只返回 `section`/`ref`、`display_name`、`cache_present`、`cache_sha256`、原始 `node_count`、`quota`、`last_attempt`、`last_success` 和 `last_result`，用于解释订阅条目与 Mihomo 已加载节点的差异；`last_success` 优先取最近一次 NetFleet 成功刷新事件，尚无事件时回退到设备上 Nikki 订阅缓存的实际修改时间，不使用测量时间或摘要推断；机场投影通过 `subscription_section` 明确引用对应条目，UI 不按显示名猜测绑定；不得返回 URL、token、节点名称或订阅正文；该读取不测速、不探测、不修改 selector；
- `events`：读取有界 NetFleet 决策事件和 Nikki/Mihomo core log 中最近的 `NETFLEET-` 行；不轮询、不修改 owner；
- `probe`：执行与设备 owner CLI 相同的一轮有界保护探测并返回真实结果；只读网络状态，不刷新订阅、不测速选优、不修改 selector、Profile 或服务；
- `enable`：在同一个 target-local mutation lock 内依次调用现有 `compile -> enable` owner；不接受浏览器上传的 policy、Profile 或候选；
- `select_auto`：只接受 status 已公开且当前可执行的 automatic 根 capability ID，调用现有 `select <capability> auto` owner 执行一次有界轮次，并把可见 selector 恢复到“自动选优”；
- `refresh`：不接受 URL、section 或订阅内容，只调用同一个 policy-driven refresh owner；浏览器/LuCI 可以显示第一阶段订阅投影并请求 refresh，但不得提交 URL/token 或解析订阅内容；
- `disable`：调用与 CLI 相同的 native Profile owner/runtime 恢复并独立返回 `business_ok`；只有 runtime 无法恢复时才转入官方 cleanup passthrough，并返回 `safe`、`persistent`、`business_ok`。

UI 有两个明确宿主。`ui/` 的 React/Vite 应用只用于本机快速参考开发，可注入 target-private 实时只读 client 或使用脱敏 fixture client；生产设备只部署原生 LuCI `view.extend`/`E()` 页面，不动态加载、挂载或打包 React。运行观察面共享“概览 / 出口 / 机场 / 地区 / 实时运行 / 配置 / 事件与诊断”信息架构，其中“实时运行”是打开独立 Zashboard 的外部入口，不是 NetFleet 内容页；原生 LuCI 另按 React 已确认的“基础接入 / 机场 / 地区映射 / 出口策略 / 自动运行 / 安全与恢复”提供配置页和首次设置向导。两端共享显示语义和交互合同，不共享组件实现或 bundle，也不要求像素一致。React 定稿只决定信息与交互参考，LuCI 原生 source 才是设备页面的部署 owner。当前视觉语言、主题映射、排版和组件规则由 [UI 设计合同](../design/ui.md)统一约束；它只负责 UI 设计，不拥有产品对象、状态或动作合同。

实时只读桥接的目标只从本机环境变量取得，只允许固定读取 `status`、`events` 和 `connections`，浏览器不持有 SSH 凭据，也不能通过该桥接调用任何 mutation；桥接结果必须显示目标、连接状态、最后读取时间和读取耗时。`connections` 只在用户打开或刷新“事件与诊断”时从 Mihomo 当前 `/connections` 读取最多 50 条活动连接，投影目标 host/IP、目标端口、网络、命中规则、规则载荷和实际代理链；不得返回 source IP、进程、连接 ID、流量计数或其他不必要字段，也不得写入事件 owner、fixture 或浏览器展示缓存。该诊断使用 Mihomo 已执行的真实首条命中结果，不在 NetFleet 或浏览器中重做规则匹配。事件页以 NetFleet 持久化选路事件为主，活动连接只在默认折叠的辅助区显示；瞬时连接快照不能累计或外推为规则组触发频数，除非未来真实 owner 提供可去重、可定义生命周期的持久计数。fixture 仅用于离线、异常和边界场景，可在内存中模拟命令后的投影变化；它必须遵守当前 `status`/`events` 形状且不得包含订阅、完整节点清单、设备地址或其他私有 target 数据，不是运行事实，也不能被生产 LuCI 页面读取。

当前 `nikki-mihomo` 后端下，NetFleet LuCI 在“地区”和“配置”之间提供“实时运行”入口，并直接复用 Nikki 官方 `tools.nikki.openDashboard()` 打开独立、完整的 Zashboard。NetFleet 只拥有入口、`dashboard_lan_ready` 就绪判断和不可用原因；Nikki 仍拥有 Zashboard 静态资源、Mihomo controller 配置、secret 读取和浏览器 URL 生成，NetFleet 不复制资源、不创建第二 controller，也不读取或保存 secret。该入口只获得 `luci.nikki.profile` 的最小读取权限；Mihomo 未运行、controller 不可读或局域网访问条件未就绪时必须禁用，不能打开一个已知不可达页面。

Nikki 当前官方打开方式会把 controller secret 放入新标签页 URL，现阶段 NetFleet 明确沿用这一兼容行为，因此该 URL 属于带凭据的临时运行面地址，不得进入 NetFleet 状态、日志、展示缓存或文档。Zashboard 保留上游完整功能；用户在其中执行的 selector 切换、连接关闭等操作属于 Mihomo 当前运行态，不是 NetFleet 持久配置事务，也不替代 NetFleet 的 policy、订阅编排、启停和恢复 owner。未来 `native-mihomo` 接管后，由 NetFleet 自己拥有 dashboard 资源、controller 配置和打开入口，但仍保持独立页面与现有用户习惯，不以嵌入、复制页面或并行 controller 作为迁移方案。长期定位见[设计白皮书](../product/whitepaper.md)和 [Zashboard 决策](../decisions/0005-zashboard-observation-surface.md)。

两个宿主首次加载都各读取一次 `status` 和 `events`，空闲零轮询，用户刷新时才重新读取；`connections` 不随页面首次加载或后台缓存刷新读取。supervisor 的后台周期不改变浏览器请求数。LuCI 可以把最近一次成功读取的 `status`、去除 Nikki 原始日志后的 `events`、读取时间和耗时保存为带 schema 版本的浏览器只读展示缓存；再次打开页面时先显示缓存并立即在后台各读取一次 `status` 和 `events`，成功后原地替换并更新缓存，失败时保留缓存且明确显示旧数据年龄和刷新失败。展示缓存不得包含 `connections`，不是运行事实 owner，不参与编译、排序、候选资格、回滚、探测、mutation precondition 或按钮授权；缓存启动和实时刷新失败状态下，除重新读取外的 mutation 控件必须禁用。没有有效缓存的首次加载仍等待实时 RPC，缓存损坏或 schema 不匹配时直接忽略且不阻断实时读取。

LuCI 的启用、单次选优、立即更新订阅、关闭和配置应用都必须二次确认，mutation 完成后重新读取 owner 投影。生产 mutation 仍只由 rpcd 调用 one-shot UCode owner。React 的实时设备桥接始终只读；React 配置页、向导、保存、校验和应用按钮只能改变浏览器内的本地预览草稿，必须持续标明“不会写入设备”，不得转发任何配置或 mutation 到 SSH bridge。浏览器不解析订阅、不实现编译、排序、候选资格、回滚或探测逻辑；生产按钮是否可用来自实时 owner 投影，浏览器缓存只能延续显示，不能延续操作授权。事件 owner 仍返回有界事件窗口，LuCI 的“选路事件”在这个窗口内按最新优先每 20 条一页展示，刷新后回到最新一页；分页不触发额外设备读取。所有 LuCI mutation、supervisor 和设备部署使用同一个短生命周期 lock，不能形成并行 writer。

概览的“最近决策”只从 `enable|select|disable` 事件中选取最新记录，同秒按 owner 写入顺序取最后一条；`refresh` 是订阅操作摘要，不覆盖选路决策。事件列表对订阅更新显示实际变化数、失败数和更新结果，延迟标为“不适用”。只有明确的 `native_restored` 恢复事件才能显示“已恢复原生配置”；缺少路由字段只代表未记录，不能推断回退。退出直通按实际恢复原因显示“已恢复网络直通”，不显示测量缺失；订阅触发的选优标为“订阅更新后选优”。

RPC 是调用 one-shot UCode owner 的薄适配器，不创建 daemon、worker、plan、operation history 或第二状态 owner。

未配置设备额外暴露 `onboarding_get / onboarding_apply`。`onboarding_get` 只读 Nikki 当前
Profile、稳定 subscription cache 和节点地区，返回脱敏预览、阻断原因及绑定发现 revision；
不得返回订阅 URL、token 或节点正文。`onboarding_apply` 必须携带同一 revision 和显式确认，
在全局 mutation lock 内重新发现并拒绝漂移，然后由 `main.uc` 唯一事务 owner 写入初始
policy、compile、enable、启动 supervisor 并回读。已有有效 policy 时 onboarding 接口只返回
`required=false`，不能覆盖现有配置；失败时必须恢复原生 Profile、服务状态和本次创建的文件。

设备端配置由 `config_get / config_validate / config_save / config_apply` 四个结构化 RPC 暴露。浏览器每次配置操作先读取 fresh `config_get`，并携带 policy SHA-256 revision；陈旧 revision 必须拒绝，展示缓存不得授权配置 mutation。唯一 target-local 配置 owner 发现 Nikki 已有稳定命名订阅、订阅 cache 中可识别的地区、当前 Policy Source 策略组和内置 Policy Source，把白名单结构化选择 merge 到现有 canonical policy、校验全部引用，并用同目录临时文件原子替换。`config_save` 只允许在 NetFleet 未接管时更新 policy，不改变数据面；active 配置必须使用 `config_apply`，后者先返回可解释变更供 LuCI 二次确认，再在全局 mutation lock 内快照旧 policy/artifact/manifest，复用 `disable -> compile -> enable` activation owner 切换，失败恢复旧字节和旧 active owner。

高级配置允许用户在设备已经存在的资源边界内维护结构：从 Nikki 已有稳定命名 subscription 新增或移除 provider；使用同一共享地区目录维护 provider-region mapping；新增、移除和命名 capability，设置其自动依赖和地区许可；把当前 Policy Source 已存在的策略组声明为 `entry|policy` binding；新增或移除只支持 `domain_suffix` 的 target-local routing rule。新增 provider 的稳定 ID 固定使用 Nikki section，地区 filter 固定来自设备 owner 返回的共享目录，浏览器不能提交自定义正则。所有结构变化仍先经过完整 policy validator，并且必须保留至少一个启用的主用 provider、每个启用 capability 恰好一个 entry、automatic 依赖无环且恰好一个根。

配置 owner 仍不接受 raw policy、订阅 URL/token、节点正文、DNS/nft 命令、浏览器生成的 Profile、自定义 provider cache 路径、自定义地区正则或 quota metadata 映射。订阅凭据与下载仍由 Nikki 管理；Nikki mixin、透明代理参数、DNS 和 OpenWrt flow-offload 仍属于 Nikki/OpenWrt 或声明式 Fleet 的 platform owner，不因结构化 policy UI 而转移给浏览器。

## LuCI 显示层合同

状态中的机场正式名称由 UCI 引用的 Nikki subscription section 的 `name` 提供；section 没有名称时才回退到稳定 section ID。恢复配置的用户显示名由 status owner 通过同一 target-local Nikki metadata 解析并投影为 `recovery_profile_display_name`；无法取得可靠名称时返回 `null`，UI 显示“当前原生配置”，不得从 `subscription:`/`file:` 引用或 provider 计费属性猜名称。capability 的可见 Mihomo 组名来自 policy `display_name`；地区可见名称由可选 `flag` 与 `display_name` 组合，缺失时回退到稳定 region ID，共享 UI 再把任意一对 regional-indicator 字符通用转换为 ASCII 两位地区代码，统一显示为“地区代码 + 中文名称”，不能依赖 emoji 字体或为单个地区写特例。这些显示名只用于编译的用户表面和 status/UI projection，不参与 provider、地区或节点选择，也不能成为算法分支。内部对象仍用稳定 ID，provider/region 内部组一律 hidden。NetFleet inactive 时，status 另从当前 Nikki owner 和一次 controller `/proxies` 读取每个绑定策略来源组的原生实际链；LuCI 显示“当前原生出口”，capability 只标注为“下次启用配置”。原生组缺失、controller 不可用和 Nikki 网络直通必须分别显示，不能统一降级成“未知”。

地区目录与当前地区规划是两层对象。policy 的 `regions` 与 `provider_regions` 只定义稳定地区 ID、显示名、Provider filter 映射和 capability 许可；status 完整投影目录供 owner 关联运行状态和历史，目录项本身不代表当前必须可用。当前地区规划只包含同一次设备状态中 `available_node_count > 0` 且 `available_provider_count > 0` 的地区：它既是地区页的可操作列表，也是首页地区数量、最近最优和平均最优的统计边界。机场和地区的实时可用数只有在 NetFleet 已接管、生成配置存在且 Mihomo 控制面可读时才具有故障语义；NetFleet 未接管或控制面不可读时，UI 必须显示“未测量”，不得把 status 中用于占位的零值解释为机场或地区下线。没有真实可用路径的目录项不进入当前规划、不作为首页分母，也不触发“不可用地区”警告；只有当前正在使用的地区失去真实路径时才作为运行异常提示。不能用“至少两个节点”或“至少两个机场”等数量门槛排除合法的小众地区，一条真实可用的 Provider/节点路径即可进入当前规划。

机场表的“可用地区”是去重后的 provider-region 数量，地区表的“可用机场”是去重后的 region-provider 数量；机场的“节点”是 manifest 绑定 source 在 `/providers/proxies` 中的 Mihomo 已加载库存，按节点名去重并使用 `alive` 统计可用数，不因地区识别或 capability 许可排除小众节点；当 SubscriptionOwner 读取的原始订阅条目数与已加载数不同，机场同一单元格补充“订阅 N 条”，不能把未被 Mihomo 接受的条目计作可用节点。地区的“节点”以 `/proxies` 当前 group 的成员关系为边界，并用同一 source 补充 file-provider 叶子身份和健康状态，嵌套组和 `DIRECT`/`COMPATIBLE` 等控制面占位值不计入。任一 owner 缺少可靠成员列表时显示“未提供”，不能缓存或伪造零值。没有真实可用叶子的地区不能凭历史 evidence 占位。机场表和地区表都显示 evidence 中的“最近最优”“平均最优”、有效样本数与最后测量时间；机场详情把 SubscriptionOwner 的 `last_success` 标为“订阅更新时间”，把 `last_attempt` 标为“最近尝试”；没有 NetFleet 刷新事件时，“最近尝试”显示“尚未执行”，“订阅更新时间”显示 Nikki 订阅缓存的实际修改时间，缓存也不存在才显示“尚未执行”，不得拿最后测量或 cache digest 猜更新时间。机场值是一轮内该机场全部合格地区候选的最小有效 delay，地区值是一轮内该地区全部合格机场候选的最小有效 delay。`delay_sample_count < 2` 时平均列显示“样本不足”，达到 2 个样本后才显示真实平均值，即使它与最近值恰好相同也不得改写。只有延迟测量口径变化才重置累计；其他更新与当前拓扑变化按上一段的稳定 ID 合同保留或裁剪。订阅制机场另从同一次 target-local Nikki metadata 读取 `expire` 并投影为 quota `expires_at`；缺失显示“未提供”，买断制显示“不适用”，UI 不得从节点名称或订阅 URL 猜测。地区展示顺序固定为当前选中项、最近最优 delay 升序、平均最优 delay 升序、可用节点数降序、可用机场数降序、显示名；机场表继续按当前选中项、可用地区数、最近最优 delay 和显示名排序。两者都只是展示顺序，不改变运行时 comparator 或 selector。

配置模式来自 policy：`automatic` 能力允许“自动选优 / 地区 / DIRECT”，`manual` 能力只允许地区和 DIRECT，地区级 `manual_only` 不进入自动池。运行模式来自 Mihomo 可见 selector 的当前成员：选择“自动选优”时 supervisor 定期重排；选择地区或 DIRECT 时显示“手动保持”并暂停后台选择。LuCI 配置页按“基础接入 / 机场 / 地区映射 / 出口策略 / 自动运行 / 安全与恢复”组织结构化草稿；首次设置按“环境与恢复 / 机场 / 地区 / 出口 / 运行与安全”推进，不把 raw policy 字段逐项暴露。顶部“NetFleet 已启用”只表示生成 Profile 是当前 owner；能力卡标题不重复显示状态，摘要中的“策略”是唯一模式投影，说明块使用“选优规则”。compiler 根据 Policy Source 中每个 `policy` 业务组的首选成员，把默认行为投影为 `capability` 或 `direct`；status 优先读取该 manifest 投影，兼容旧 manifest 时只允许从 Mihomo 当前组的有序成员回读，不按组名猜测。出口页分别显示“默认走此出口”和“默认直连、可临时切换”，不再把 entry 与 policy binding 混成“接管的原始策略组”。用户可见的“运行时网络退路”只按 status 从 manifest 返回的 role stages 投影为“当前优选 → 主用机场 → 备用机场 → 直连”，没有 reserve stage 时明确显示“备用机场（未配置）”。机场的 `primary|reserve` role 与 `subscription|buyout` 计费是独立事实，UI 不得用买断属性推断备用角色。

“退出与故障恢复”是独立区块：优先恢复 `recovery_profile_display_name` 对应的原生配置；只有该恢复失败时，最终退路才是停止 Nikki 并恢复网络直通。这是条件关系，不能与运行时网络退路合并，也不能用一条连续箭头暗示每次都会执行两步。用户可见文案使用“直连 / 网络直通 / 原生配置”，不暴露 `DIRECT`、`passthrough`、`RecoveryProfileRef` 等内部标识。界面中的门槛、周期和说明必须直接读取 status 返回的 policy 值，不能在前端写死 capability、地区、机场或阈值。机场表和地区表的延迟着色使用 `status.selection.region_switch_margin_ms` 作为展示分界，缺失或非数字时不加警告色；该分界只服务展示，不冒充 comparator。UI 不得按 capability id 是否包含 `ai` 或其他子串选择图标或文案，跟随能力的说明必须读取该能力的 `prefer_region_from` 显示名。
