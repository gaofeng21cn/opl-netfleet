# 公开接口与 UI

本文是 NetFleet 当前 RPC、状态投影、React 本地参考面、原生 LuCI 页面和浏览器缓存边界的
权威合同。视觉语言由 [UI 设计合同](../design/ui.md)负责。

## 原生接入与管理

原生后端的可选 [HTTPS 兼容模块](https-compatibility.md) 使用独立的
`compatibility_get/apply/enable/disable/probe/ca` 动作。rpcd 和 UCode 入口将请求交给
组件 controller；该 controller 复用现有 mutation lock，不运行全局配置应用。
返回值区分用户意图、实际接管、旁路原因、配置 revision 和验证结果。组件缺失时读取
返回未安装，基础管理页仍然可用。公开 CA 下载需要 LuCI 读取权限，信任记录与接管
变更需要写权限；浏览器不能下载 CA 私钥。

`native_setup_get / native_setup_apply` 为没有已配置后端的设备提供首次接入：预检只读，
apply 接受绑定 revision 的明确确认和一份私有订阅输入，完成来源下载、原生核心与数据面
就绪后进入现有 onboarding。已有 Nikki 或原生 owner 时拒绝覆盖；已有 Nikki 的迁移使用
独立 `migration_get / migration_apply`，不能借首次接入隐式替换运行 owner。

`subscriptions_get / subscriptions_set` 是当前经过 LuCI 认证的原生订阅管理接口，分别用于读取
和保存单项来源或删除。`get` 返回 `managed_by`、revision 和来源列表，包括当前
`url/user_agent/info_url` 编辑值、缓存身份、节点数、更新时间、配额及 pending 状态，不返回节点正文。
`set` 的私有请求为 `{revision, source:{id,name,url?,user_agent?,info_url?,prefer?}, delete?}`；
编辑表单显示当前真实地址和 User-Agent；未提交的字段由 owner 保留。来源修改不立即重启或下载，
运行继续使用上次可用缓存，`pending_update/cache_current/using_previous_cache` 明确区分待更新
与已接受缓存；只有显式更新成功后新来源才生效。`subscriptions_refresh` 只接受稳定来源 ID，
未被启用 policy 引用的来源只下载并校验缓存，不重启；使用中的来源复用完整 refresh 事务，
可能同时刷新其他已启用机场。LuCI 每项更新先确认，成功后重读订阅和配置资源选项。
删除仍被 policy、当前 Profile 或运行配置引用的订阅必须拒绝。Nikki 模式继续打开 Nikki
原有订阅管理，不能同时写两份来源配置。

LuCI 在机场页和配置的机场区提供同一个订阅管理入口，新增、编辑、删除均调用上述 owner。
订阅来源持久保存在设备 UCI，接受后的正文保存在设备私有缓存；打开管理器不下载或测速。
页面预读取管理来源列表，仅在当前页面内存中复用，返回和再次打开直接显示；保存、删除、更新后
失效并读取 owner 新状态。浏览器不持久保存凭据，也不复制一份可写来源配置。
配置的基础接入区提供后端迁移：`migration_get` 返回 ready、revision 和缺失条件；
`migration_apply` 接受 `{revision,confirmed:true,backend:"native-mihomo"}`，执行当前后端
迁移事务。成功后重读真实 status/config；失败必须显示 owner 返回的 rollback 结果，不把
请求结束、浏览器超时或旧数据显示为迁移成功。这些结构化管理请求通过 rpcd 的
`request: Table` 参数进入同一全局 mutation lock；配置文件正文和备份的大体积传输使用
下文独立的认证 CGI 通道，最终仍交给相同设备 owner。

## 独立设备管理接口

管理对象与恢复边界由[设备独立管理](management.md)负责。`network_get` 按需返回当前
原生网络配置、revision 和已有接口资源；`network_validate / network_apply` 接受
`{revision,settings}`，其中 `settings` 分为 `dns / lan / router / listeners`。DNS 包括
普通、引导、代理节点与直连解析上游，以及精确域名的解析覆盖；LAN 包括入口接口与
按 IPv4/IPv6、MAC 匹配的代理和 DNS 接入规则；监听包括 HTTP/SOCKS/mixed 端口与认证。
读取不返回密码，只显示是否已配置；编辑未提交密码时保留原值。该接口不接受代理模式、
WAN/LAN 地址、默认路由或任意 UCI 字段，也不修改 policy。校验与应用拒绝旧 revision，
应用结果区分已保存、已重启回读及失败恢复，不能以 HTTP 请求完成代替网络就绪。

`maintenance_get` 按需返回本地 Profile 清单、引用与可编辑状态、revision、核心可执行
维护动作和备份格式，不返回文件正文或凭据。`profile_get/save/delete` 与
`backup_export/restore` 共用维护 owner；保存、删除、恢复携带 revision，备份恢复另须
明确确认。当前被策略来源、恢复配置或运行选择引用的 Profile 拒绝覆盖与删除。

LuCI 通过 `fs.exec_direct` 调用白名单 `opl-netfleet-transfer`，经 `cgi-exec` 下载 Profile
或备份；上传的完整私有 envelope 经 `cgi-upload` 保存到专用随机文件，再由 RPC 仅提交
`upload_id`，最终 owner 校验私有文件、读取并删除。浏览器不把大体积正文放入普通 ubus
请求或响应，也不将下载内容保存到展示缓存。root CLI 和小体积结构化 RPC 输入仍调用
同一实现，不能绕过 revision、路径、大小和引用校验。

`core_action` 接受 `{revision,action:"restart"|"reload",confirm:true}`，只执行所选原生
运行 owner 的维护事务；`diagnostics_get` 返回最多 120 条有界、脱敏的核心启动与运行
日志，以及核心和 controller 可用性。诊断不依赖 controller 成功响应，按用户进入或刷新
诊断区读取，不成为另一个日志持久化 owner。

## 当前运行接口

`status.runtime.backend` 返回当前后端的 `id/display_name`，`backend_enabled` 表示其服务
启用状态；配置投影的 `backend` 来自同一 owner。UI 不保留 Nikki 专用状态字段别名，
恢复文案使用实际后端名称，不能把“NetFleet 原生后端运行”描述成 Nikki 运行。

root CLI 的管理动作与 RPC 共用同一实现：`subscriptions-get/set/refresh`、
`native-setup-get/apply`、`migration-get/apply`、`network-get/validate/apply`、
`maintenance-get`、`profile-get/save/delete`、`backup-export/restore`、`core-action`、
`diagnostics-get` 和 `dashboard-get/check/update`。涉及私有结构化输入
的 CLI 读取设备私有文件，不通过命令行参数传递订阅地址。核心启停和网关配置由
[正式运行 owner](runtime-and-recovery.md#运行后端与原生网关)负责，浏览器不直接调用
gateway 的准备、附加或清理动作，不建立第二条核心生命周期。

原生 LuCI 是当前第一个真实公开 caller，除上述接入与管理接口外提供：

- `status`：一次读取 policy、manifest、最近一次 evidence、服务状态、package 自有 build identity（source 部署时回退部署器原子持久化身份），以及 Mihomo `/proxies` 和 `/providers/proxies` 各一次；安装身份只投影经过格式校验的 NetFleet 版本、source commit 和 source tree，供用户确认当前设备字节并用于静态资源缓存失效，不参与运行决策；`apk upgrade` 后 package identity 必须优先于可能仍属于上一次声明式部署的 `installed.json`，避免状态页继续报告旧代码；当前已承载流量的 capability 以健康的生成 URLTest 组、组内当前成员和 manifest 绑定 source 中唯一的真实代理身份投影当前叶子，`/providers/proxies` 的节点 `alive` 只补充下一轮候选与机场/地区库存健康，不能用可能滞后的单节点健康位推翻当前组和独立 protected probes 已证明的实际路径；机场节点库存按 manifest 绑定的 source 从 `/providers/proxies` 读取、按节点名去重并独立投影 `available_node_count/node_count/node_count_known`，不能把跨 capability 的地区候选组 `available_count/candidate_count` 标成节点；同一读取还经第一阶段 SubscriptionOwner 投影顶层 `subscriptions`：每个已启用订阅只返回 `section`/`ref`、`display_name`、`cache_present`、`cache_sha256`、原始 `node_count`、`quota`、`last_attempt`、`last_success` 和 `last_result`，用于解释订阅条目与 Mihomo 已加载节点的差异；`last_success` 优先取最近一次 NetFleet 成功刷新事件，尚无事件时回退到设备上当前后端订阅缓存的实际修改时间，不使用测量时间或摘要推断；机场投影通过 `subscription_section` 明确引用对应条目，UI 不按显示名猜测绑定；不得返回 URL、token、节点名称或订阅正文；该读取不测速、不探测、不修改 selector；
- `events`：读取有界 NetFleet 决策事件和当前后端 core log 中最近的 `NETFLEET-` 行，字段为 `core_lines/core_lines_persistent`；不轮询、不修改 owner；
- `probe`：执行与设备 owner CLI 相同的一轮有界保护探测并返回真实结果；只读网络状态，不刷新订阅、不测速选优、不修改 selector、Profile 或服务；
- `enable`：在同一个 target-local mutation lock 内依次调用现有 `compile -> enable` owner；不接受浏览器上传的 policy、Profile 或候选；
- `select_auto`：只接受 status 已公开且当前可执行的 automatic 根 capability ID，调用现有 `select <capability> auto` owner 执行一次有界轮次，并把可见 selector 恢复到“自动选优”；
- `refresh`：不接受 URL、section 或订阅内容，只调用同一个 policy-driven refresh owner；来源凭据修改由独立 subscriptions_set 完成，浏览器不解析订阅内容；
- `disable`：调用与 CLI 相同的 native Profile owner/runtime 恢复并独立返回 `business_ok`；只有 runtime 无法恢复时才转入官方 cleanup passthrough，并返回 `safe`、`persistent`、`business_ok`。

UI 有两个明确宿主。`ui/` 的 React/Vite 应用只用于本机快速参考开发，可注入 target-private 实时只读 client 或使用脱敏 fixture client；生产设备只部署原生 LuCI `view.extend`/`E()` 页面，不动态加载、挂载或打包 React。两端共享[UI 设计合同](../design/ui.md)定义的七页信息架构，Zashboard 在工具区提供独立外链；配置页把网络接入和配置文件与备份作为独立管理分区，不混入 policy 草稿的应用按钮。首次设置向导复用适用的字段组件，不重复提供完整维护工具。两端共享显示语义和交互合同，不共享组件实现或 bundle，也不要求像素一致。React 定稿只决定信息与交互参考，LuCI 原生 source 才是设备页面的部署 owner。UI 设计合同负责视觉语言、主题映射、排版和组件规则，不拥有产品对象、状态或动作合同。

实时只读桥接的目标只从本机环境变量取得，只允许固定读取 `status`、`events`、`config_get`、`connections`、`components_get`、`operation_get`、`network_get`、`maintenance_get` 和 `diagnostics_get`，浏览器不持有 SSH 凭据，也不能通过该桥接调用任何 mutation；桥接结果必须显示目标、连接状态、最后读取时间和读取耗时。组件、网络配置、文件清单和核心日志按需独立读取，不并入常规网络快照。网络投影隐藏解析 URL 的凭据和私有路径，不返回认证密码；文件清单不包含正文或备份。`connections` 只在用户打开或刷新“事件与诊断”时从 Mihomo 当前 `/connections` 读取最多 50 条活动连接，投影目标 host/IP、目标端口、网络、命中规则、规则载荷和实际代理链；不得返回 source IP、进程、连接 ID、流量计数或其他不必要字段，也不得写入事件 owner、fixture 或浏览器展示缓存。该诊断使用 Mihomo 已执行的真实首条命中结果，不在 NetFleet 或浏览器中重做规则匹配。事件页以 NetFleet 持久化选路事件为主，活动连接只在默认折叠的辅助区显示；瞬时连接快照不能累计或外推为规则组触发频数，除非未来真实 owner 提供可去重、可定义生命周期的持久计数。fixture 仅用于离线、异常和边界场景，可在内存中模拟命令后的投影变化；它必须遵守当前接口形状且不得包含订阅、完整节点清单、设备地址或其他私有 target 数据，不是运行事实，也不能被生产 LuCI 页面读取。

NetFleet LuCI 在页面标题的工具区提供独立的“Zashboard”外链，不作为内部标签页，以 `dashboard_get` 返回的
可用性、controller 端口、协议、可选 UI 名称和 secret 打开独立完整的 Zashboard。
浏览器只使用当前页面 hostname 构造 `/ui/` 路径与上游认可的连接参数，通过 `#/setup`
让 Zashboard 校验并选用本次连接，避免已有浏览器后端记录继续使用旧凭据；不加载 `tools.nikki`，
也不需要 `luci.nikki.profile` 权限。Nikki 模式的资源与 controller 仍来自当前后端 owner；
原生模式使用 NetFleet 的资源与 controller，不创建第二控制器。Mihomo 未运行、controller
不可读或局域网条件未就绪时禁用入口。

页面预读取 Dashboard 连接信息，仅在内存中构造真实链接，点击直接打开目标，不先打开
空白页再等待 RPC。交互 RPC 使用 LuCI `nobatch` 立即发送，不能依赖后台标签页的动画帧
刷新队列。状态读取不等待配置资源发现；配置独立加载，原生 JSON 使用直接结构化读取，
只有 YAML 输入才调用转换器。只读性能优化不改变写入校验与故障恢复前置条件。
状态页的 DNS 就绪取自监听和转发规则，不在页面读取中执行 DNS 网络探针；运行 owner、
supervisor 与显式 probe 的保护探测保持不变。

LuCI 发布入口及其全部 NetFleet JavaScript 依赖使用同一版本命名空间。软件包与源码部署
共用资源生成器，重写模块间依赖，避免新版入口加载浏览器缓存的旧模块。不能只给入口
加版本号，也不能依赖用户清理缓存恢复升级后的正常使用。

NetFleet 沿用 Nikki/Zashboard 的带凭据新标签页连接方式，controller secret 只用于本次
URL 构造，不得进入 NetFleet status、日志、展示缓存或文档。Zashboard 保留上游完整功能；
其中 selector 切换、连接关闭属于 Mihomo 当前运行态，不替代 NetFleet 的持久配置、订阅
编排、启停和恢复 owner。两种后端都保持独立完整页面，不嵌入或复制控制器。长期定位见
[设计白皮书](../product/whitepaper.md)和 [Zashboard 决策](../decisions/0005-zashboard-observation-surface.md)。

两个宿主首次加载都各读取一次 `status` 和 `events`，空闲零轮询，用户刷新时才重新读取；`connections` 不随页面首次加载或后台缓存刷新读取。supervisor 的后台周期不改变浏览器请求数。LuCI 可以把最近一次成功读取的 `status`、去除核心原始日志后的 `events`、读取时间和耗时保存为带 schema 版本的浏览器只读展示缓存；再次打开页面时先显示缓存并立即在后台各读取一次 `status` 和 `events`，成功后原地替换并更新缓存，失败时保留缓存且明确显示旧数据年龄和刷新失败。展示缓存不得包含 `connections`，不是运行事实 owner，不参与编译、排序、候选资格、回滚、探测、mutation precondition 或按钮授权；缓存启动和实时刷新失败状态下，除重新读取外的 mutation 控件必须禁用。没有有效缓存的首次加载仍等待实时 RPC，缓存损坏或 schema 不匹配时直接忽略且不阻断实时读取。

LuCI 的启用、单次选优、立即更新订阅、关闭和配置应用都必须二次确认，mutation 完成后重新读取 owner 投影。这些网络操作由 rpcd 调用 one-shot UCode owner；软件包更新由下述一次性后台事务执行。React 的实时设备桥接始终只读；React 配置页、向导、保存、校验和应用按钮只能改变浏览器内的本地预览草稿，必须持续标明“不会写入设备”，不得转发任何配置或 mutation 到 SSH bridge。浏览器不解析订阅、不实现编译、排序、候选资格、回滚或探测逻辑；生产按钮是否可用来自实时 owner 投影，浏览器缓存只能延续显示，不能延续操作授权。事件 owner 仍返回有界事件窗口，LuCI 的“选路事件”在这个窗口内按最新优先每 20 条一页展示，刷新后回到最新一页；分页不触发额外设备读取。所有 LuCI mutation、supervisor 和设备部署使用同一个短生命周期 lock，不能形成并行 writer。

概览的“最近决策”只从 `enable|select|disable` 事件中选取最新记录，同秒按 owner 写入顺序取最后一条；`refresh` 是订阅操作摘要，不覆盖选路决策。事件列表对订阅更新显示实际变化数、失败数和更新结果，延迟标为“不适用”。只有明确的 `native_restored` 恢复事件才能显示“已恢复原生配置”；缺少路由字段只代表未记录，不能推断回退。退出直通按实际恢复原因显示“已恢复网络直通”，不显示测量缺失；订阅触发的选优标为“订阅更新后选优”。

`components_get.extensions` 按[模块合同](extensions.md)投影模块安装版本、接口 major、
依赖与后端适用性。它不表示运行健康，不触发网络检查或启动引擎；Zashboard 的资源状态
仍复用同一 `dashboard` 读取，避免重复探测。HTTPS `get` 额外投影 `managed` 和
`management_reason`，不兼容时禁止新接管和编辑，保留关闭与排空。

RPC 是调用设备 owner 的薄适配器，不维护第二份网络状态。`components_get` 只读已安装组件、
实际运行核心版本、关键依赖、最近一次 Feed 检查及独立的 `dashboard` 资源状态；`components_check` 与 `components_update`
分别启动显式版本检查及固定组件、固定版本的后台更新。更新流程见[软件包合同](packaging.md)。
`dashboard` 不作为 APK 包：`installed_version` 来自有效安装记录或本地资源识别，两者均
无可靠证据时才返回 `null`；识别规则见[设备独立管理](management.md#规则与运行面)。
`dashboard_check` 显式查询官方
Release 并缓存候选，`dashboard_update` 接受用户确认的版本，绑定该候选的官方 HTTPS
资产与摘要执行有界资源事务。两者都不随组件页读取自动执行，也不重启核心；资源事务
和恢复合同见[设备独立管理](management.md#规则与运行面)。
`operation_get` 返回订阅和组件操作的最新进度：标识、状态、阶段、开始/更新时间、已处理数、
总数、当前对象显示名、脱敏错误码及恢复结果 `recovery`；恢复结果区分已恢复、恢复失败和
网络直通，未发生恢复时为 `null`，不能把恢复成功当作原操作成功。不返回 URL、凭据、命令
输出或无限增长的操作历史。
订阅下载、校验、编译、重载、选优、探测和回滚阶段由实际执行者写入；没有内容变化时直接
返回真实结果，不伪造后续阶段或百分比。执行进程消失但没有终态时显示中断未确认，不冒充成功。
初次加载与进入机场、组件页时读取一次当前操作；只在存在运行中操作时每秒读取独立进度，
结束后停止轮询并刷新受影响的数据。操作标识绑定执行结果，旧操作终态不能确认新请求完成。

未配置设备额外暴露 `onboarding_get / onboarding_apply`。`onboarding_get` 只读当前后端
Profile、稳定 subscription cache 和节点地区，返回脱敏预览、阻断原因及绑定发现 revision；
不得返回订阅 URL、token 或节点正文。`onboarding_apply` 必须携带同一 revision 和显式确认，
在全局 mutation lock 内重新发现并拒绝漂移，然后由 `main.uc` 唯一事务 owner 写入初始
policy、compile、enable、启动 supervisor 并回读。已有有效 policy 时 onboarding 接口只返回
`required=false`，不能覆盖现有配置；失败时必须恢复原生 Profile、服务状态和本次创建的文件。

设备端配置由 `config_get / config_validate / config_save / config_apply` 四个结构化 RPC 暴露。浏览器每次配置操作先读取 fresh `config_get`，并携带 policy SHA-256 revision；陈旧 revision 必须拒绝，展示缓存不得授权配置 mutation。唯一 target-local 配置 owner 发现当前后端已有稳定命名订阅、订阅 cache 中可识别的地区、当前 Policy Source 策略组和内置 Policy Source，把白名单结构化选择 merge 到现有 canonical policy、校验全部引用，并用同目录临时文件原子替换。`config_save` 只允许在 NetFleet 未接管时更新 policy，不改变数据面；active 配置必须使用 `config_apply`，后者先返回可解释变更供 LuCI 二次确认，再在全局 mutation lock 内快照旧 policy/artifact/manifest，复用 `disable -> compile -> enable` activation owner 切换，失败恢复旧字节和旧 active owner。

高级配置允许用户在设备已经存在的资源边界内维护结构：从当前后端已有稳定命名 subscription 新增或移除 provider；使用同一共享地区目录维护 provider-region mapping；新增、移除和命名 capability，设置其自动依赖和地区许可；把当前 Policy Source 已存在的策略组声明为 `entry|policy` binding；新增或移除 `domain_suffix` 或 `ip_cidr` 的 target-local routing rule，目标为启用的 capability 或直连。规则字段与校验由[产品对象](domain-model.md#配置解耦合同)负责。新增 provider 的稳定 ID 固定使用当前后端 subscription section，地区 filter 固定来自设备 owner 返回的共享目录，浏览器不能提交自定义正则。所有结构变化仍先经过完整 policy validator，并且必须保留至少一个启用的主用 provider、每个启用 capability 恰好一个 entry、automatic 依赖无环且恰好一个根。

policy 配置 owner 不接受 raw policy、订阅 URL/token、节点正文、DNS/nft 命令、浏览器生成的 Profile、自定义 provider cache 路径、自定义地区正则或 quota metadata 映射。订阅凭据单独提交给 subscriptions owner，不混入 policy；原生 DNS、代理范围和监听设置通过独立 network owner 的受限结构编辑。配置文件通过 maintenance owner 校验，不能借文件导入建立另一条配置应用链。OpenWrt flow-offload、WAN/LAN 地址和任意防火墙参数不属于这些管理表单。

## LuCI 显示层合同

状态中的机场正式名称由 UCI 引用的当前后端 subscription section 的 `name` 提供；section 没有名称时才回退到稳定 section ID。恢复配置的用户显示名由 status owner 通过同一 target-local 后端 metadata 解析并投影为 `recovery_profile_display_name`；无法取得可靠名称时返回 `null`，UI 显示“当前原生配置”，不得从 `subscription:`/`file:` 引用或 provider 计费属性猜名称。capability 的可见 Mihomo 组名来自 policy `display_name`；地区可见名称由可选 `flag` 与 `display_name` 组合，缺失时回退到稳定 region ID，共享 UI 再把任意一对 regional-indicator 字符通用转换为 ASCII 两位地区代码，统一显示为“地区代码 + 中文名称”，不能依赖 emoji 字体或为单个地区写特例。这些显示名只用于编译的用户表面和 status/UI projection，不参与 provider、地区或节点选择，也不能成为算法分支。内部对象仍用稳定 ID，provider/region 内部组一律 hidden。NetFleet inactive 时，status 另从当前后端 owner 和一次 controller `/proxies` 读取每个绑定策略来源组的原生实际链；LuCI 显示“当前原生出口”，capability 只标注为“下次启用配置”。原生组缺失、controller 不可用和网络直通必须分别显示，不能统一降级成“未知”。

地区目录与当前地区规划是两层对象。policy 的 `regions` 与 `provider_regions` 只定义稳定地区 ID、显示名、Provider filter 映射和 capability 许可；status 完整投影目录供 owner 关联运行状态和历史，目录项本身不代表当前必须可用。当前地区规划只包含同一次设备状态中 `available_count > 0` 且 `available_provider_count > 0` 的地区：它既是地区页的可操作列表，也是首页地区数量、最近最优和平均最优的统计边界。`available_count` 表示真实候选路径数量；`available_node_count` 只是后端库存诊断，可能未知，不能作为地区可用性的门槛。机场和地区的实时可用数只有在 NetFleet 已接管、生成配置存在且 Mihomo 控制面可读时才具有故障语义；NetFleet 未接管或控制面不可读时，UI 必须显示“未测量”，不得把 status 中用于占位的零值解释为机场或地区下线。没有真实可用路径的目录项不进入当前规划、不作为首页分母，也不触发“不可用地区”警告；只有当前正在使用的地区失去真实路径时才作为运行异常提示。不能用“至少两个节点”或“至少两个机场”等数量门槛排除合法的小众地区，一条真实可用的 Provider/节点路径即可进入当前规划。

机场表的“可用地区”是去重后的 provider-region 数量，地区表的“可用机场”是去重后的 region-provider 数量；机场的“节点”是 manifest 绑定 source 在 `/providers/proxies` 中的 Mihomo 已加载库存，按节点名去重并使用 `alive` 统计可用数，不因地区识别或 capability 许可排除小众节点；当 SubscriptionOwner 读取的原始订阅条目数与已加载数不同，机场同一单元格补充“订阅 N 条”，不能把未被 Mihomo 接受的条目计作可用节点。地区的“节点”以 `/proxies` 当前 group 的成员关系为边界，并用同一 source 补充 file-provider 叶子身份和健康状态。按 Mihomo 类型确认的直连、拒绝等控制面终端是已知的非节点，排除后不影响其他候选组计数；不得按节点显示名猜测类型。缺失成员列表或不能解析的嵌套组仍是未知，显示“节点清单暂不可读”，不能伪造零值。没有真实可用叶子的地区不能凭历史 evidence 占位。

机场表和地区表都显示 evidence 中的“最近最优”“平均最优”、有效样本数与最近有效测量时间。没有有效样本时合并延迟空态为“暂无有效测量”，仅有一次时显示“仅 1 次测量”，达到两次后才显示真实平均，即使与最近值相同也不改写。机场值是一轮内该机场全部合格地区候选的最小有效 delay，地区值是一轮内该地区全部合格机场候选的最小有效 delay。历史保留范围来自 manifest 的当前候选目录，不来自某轮成功解析的运行候选；临时失效或本轮未取得叶子不清空历史、不增加样本，也不把旧测量时间刷新为本轮时间。删除目录对象时裁剪，改变延迟测量口径时重置。UI 明确区分库存健康和有效测量历史，旧延迟不冒充本轮成功。

机场详情把 SubscriptionOwner 的 `last_success` 标为“订阅更新时间”，把 `last_attempt` 标为“最近尝试”；没有 NetFleet 刷新事件时，“最近尝试”显示“尚未执行”，“订阅更新时间”显示当前后端订阅缓存的实际修改时间，缓存也不存在才显示“尚未执行”，不得拿最后测量或 cache digest 猜更新时间。订阅制机场从同一次 target-local 后端 metadata 读取 `expire` 并投影为 quota `expires_at`；缺失显示“机场未返回到期时间”，买断制显示“不限时间”，不得从节点名称或订阅 URL 猜测。地区展示顺序固定为当前选中项、最近最优 delay 升序、平均最优 delay 升序、可用节点数降序、可用机场数降序、显示名；机场表继续按当前选中项、可用地区数、最近最优 delay 和显示名排序。两者都只是展示顺序，不改变运行时 comparator 或 selector。

配置模式来自 policy：`automatic` 能力允许“自动选优 / 地区 / DIRECT”，`manual` 能力只允许地区和 DIRECT，地区级 `manual_only` 不进入自动池。运行模式来自 Mihomo 可见 selector 的当前成员：选择“自动选优”时 supervisor 定期重排；选择地区或 DIRECT 时显示“手动保持”并暂停后台选择。LuCI 配置页按 [UI 设计合同](../design/ui.md#页面骨架)组织结构化草稿与独立管理分区；首次设置按“环境与恢复 / 机场 / 地区 / 出口 / 运行与安全”推进，不把 raw policy 字段逐项暴露。顶部“NetFleet 已启用”只表示生成 Profile 是当前 owner；能力卡标题不重复显示状态，摘要中的“策略”是唯一模式投影，说明块使用“选优规则”。compiler 根据 Policy Source 中每个 `policy` 业务组的首选成员，把默认行为投影为 `capability` 或 `direct`；status 优先读取该 manifest 投影，兼容旧 manifest 时只允许从 Mihomo 当前组的有序成员回读，不按组名猜测。出口页分别显示“默认走此出口”和“默认直连、可临时切换”，不再把 entry 与 policy binding 混成“接管的原始策略组”。用户可见的“运行时网络退路”只按 status 从 manifest 返回的 role stages 投影为“当前优选 → 主用机场 → 备用机场 → 直连”，没有 reserve stage 时明确显示“备用机场（未配置）”。机场的 `primary|reserve` role 与 `subscription|buyout` 计费是独立事实，UI 不得用买断属性推断备用角色。

“退出与故障恢复”是独立区块：优先恢复 `recovery_profile_display_name` 对应的原生配置；只有该恢复失败时，最终退路才是停止当前代理后端并恢复网络直通。这是条件关系，不能与运行时网络退路合并，也不能用一条连续箭头暗示每次都会执行两步。用户可见文案使用“直连 / 网络直通 / 原生配置”，不暴露 `DIRECT`、`passthrough`、`RecoveryProfileRef` 等内部标识。界面中的门槛、周期和说明必须直接读取 status 返回的 policy 值，不能在前端写死 capability、地区、机场或阈值。机场表和地区表的延迟着色使用 `status.selection.region_switch_margin_ms` 作为展示分界，缺失或非数字时不加警告色；该分界只服务展示，不冒充 comparator。UI 不得按 capability id 是否包含 `ai` 或其他子串选择图标或文案，跟随能力的说明必须读取该能力的 `prefer_region_from` 显示名。
