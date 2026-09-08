# 公开接口与 UI

本文是 NetFleet 当前 RPC、状态投影、插件页面宿主、React 本地参考面和浏览器缓存边界的
权威合同。视觉语言由 [UI 设计合同](../design/ui.md)负责，服务绑定与命令路由由
[微内核合同](microkernel.md)负责。

## 原生接入与管理

功能服务插件和进程插件统一使用内核自带 `opl-netfleet.plugins` ubus 对象的
`plugins_list`、`plugin_read`、`plugin_call`。清单只发现安装文件，读取和写入分别授权；
请求为 `{request:{id,action,instance?,revision?,confirm?,params?}}`，写入必须携带当前
revision 和明确确认。组件页管理已安装插件的加载、重载、退出及声明的自定义动作。
服务插件的 `actions` 将业务动作绑定到本插件服务方法，进程插件由 `control` 执行动作。
`configuration` 引用自身配置动作，`ui` 贡献页面；清单按已配置实例投影这些声明，
浏览器不能提交模块路径或即时绑定。默认产品既有业务 RPC 继续由功能插件在
`opl-netfleet` 对象提供，通用插件管理不依赖该业务对象。
状态与私有配置由插件持有；进程插件回读 loaded/ready，服务插件回读启用状态与绑定依赖是否可用。
包管理器专用 `plugin-drain` 与 `plugin-package-*` 不暴露给 RPC。
同一管理对象提供 `system_get`、`system_validate`、`system_apply`，均要求写权限，避免
向只读会话泄露可能含凭据的实例配置。后两者接受 `{request:{revision,config,confirm?}}`；
apply 必须明确确认。组件页的“服务组合”先读取私有覆盖、校验依赖并预览影响，再应用。
输入限制为 64 KiB；编辑后的配置不能沿用旧预览，过期 revision 必须重新读取。
服务组合编辑器按默认与具名实例展示插件开关和服务提供者选择；默认值、有效绑定与
可选提供者由同一管理 owner 返回。表单和高级 JSON 编辑同一份待提交私有覆盖，
实例继承通过删除局部覆盖表达；界面不自行解析依赖或保存另一份组合。
接口及安装切换合同见[模块与扩展](extensions.md)和[微内核合同](microkernel.md)。

原生后端的可选 [HTTPS 兼容模块](https-compatibility.md) 使用独立的
`compatibility_get/apply/enable/disable/probe/ca` 动作。rpcd 经内核将请求交给
`https-compat.control` 服务，再调用组件 controller；该 controller 复用现有 mutation lock，不运行全局配置应用。
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
未被 policy、恢复配置或当前 Profile 引用的来源只下载并校验缓存，不重启；使用中的来源复用完整 refresh 事务，
只下载指定来源；全局更新才遍历相关机场。LuCI 每项更新先确认，成功后重读订阅和配置资源选项。
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

事件与诊断页提供网站诊断：输入只在浏览器中规范化为域名或 IP，用于筛选 Mihomo 已返回的
活动连接，不发起任意目标请求、不重做规则匹配、不持久保存输入或连接。域名只匹配自身和
子域名，IP 精确匹配；无匹配、截断、读取失败和实际运行异常分别呈现，未捕获到连接不能
推断网站不可达。DNS 与透明代理就绪仅说明当前监听及接管状态，不证明指定网站解析成功、
请求成功或速度达标。实际链路缺失不能推断直连；当前出口状态不改写连接已经命中的链路。
诊断刷新复用现有 status/events/connections 读取，空闲不增加轮询或新 RPC。

操作确认按真实行为说明影响：保存订阅元信息和更新面板资源不重启核心；使用中订阅内容
变化、策略应用、网络接入变更和核心/基础包升级可能中断连接。无变化结果明确显示未重载，
完成操作后的读取失败显示为“操作已完成，状态读取失败”，不能将其混同为执行失败或自动重试。
网络接入应用前展示变化分类及影响，不在摘要中回显密码。恢复成功不代表原操作成功。

## 当前运行接口

默认产品页面按插件 revision 共享资源工厂的下载和编译结果；切页重新创建页面绑定、
权限守卫与作用域。加载失败允许重试，取消一个页面不取消其他页面共用的资源请求。
私有配置与 API 响应不进入这个工厂缓存。

`status.recovery` 由 `status.control` 投影 `recovery.state` 持有的自动降级恢复请求；存在请求时允许用户执行 disable 取消恢复，界面显示“降级恢复中”。`active` 仍只表示当前实际接管状态，恢复原因与重试时间不能由界面自行推断。

`status.runtime.backend` 返回当前后端的 `id/display_name`，`backend_enabled` 表示其服务
启用状态；配置投影的 `backend` 来自同一 owner。UI 不保留 Nikki 专用状态字段别名，
恢复文案使用实际后端名称，不能把“NetFleet 原生后端运行”描述成 Nikki 运行。

root CLI 的管理动作与 RPC 经内核路由到相同功能服务：`subscriptions-get/set/refresh`、
`native-setup-get/apply`、`migration-get/apply`、`network-get/validate/apply`、
`maintenance-get`、`profile-get/save/delete`、`backup-export/restore`、`core-action`、
`diagnostics-get` 和 `dashboard-get/check/update`。涉及私有结构化输入
的 CLI 读取设备私有文件，不通过命令行参数传递订阅地址。核心启停和网关配置由
[正式运行 owner](runtime-and-recovery.md#运行后端与原生网关)负责，浏览器不直接调用
gateway 的准备、附加或清理动作，不建立第二条核心生命周期。原生 init 与首次设置使用
内部 `subscriptions-update-result` 命令更新尚未进入运行应用事务的来源；运行中被引用的
订阅仍须经 `refresh.control`，不能借内部入口绕过刷新恢复合同。

LuCI 的默认产品界面插件是这些业务接口的公开 caller，除上述接入与管理接口外提供：

- `status`：一次读取 policy、manifest、最近一次 evidence、服务状态、package 自有 build identity（source 部署时回退部署器原子持久化身份），以及 Mihomo `/proxies` 和 `/providers/proxies` 各一次；安装身份只投影经过格式校验的 NetFleet 版本、source commit 和 source tree，供用户确认当前设备字节并用于静态资源缓存失效，不参与运行决策；`apk upgrade` 后 package identity 必须优先于可能仍属于上一次声明式部署的 `installed.json`，避免状态页继续报告旧代码；当前已承载流量的 capability 以健康的生成 URLTest 组、组内当前成员和 manifest 绑定 source 中唯一的真实代理身份投影当前叶子，`/providers/proxies` 的节点 `alive` 只补充下一轮候选与机场/地区库存健康，不能用可能滞后的单节点健康位推翻当前组和独立 protected probes 已证明的实际路径；机场节点库存按 manifest 绑定的 source 从 `/providers/proxies` 读取、按节点名去重并独立投影 `available_node_count/node_count/node_count_known`，不能把跨 capability 的地区候选组 `available_count/candidate_count` 标成节点；同一读取还经 SubscriptionOwner 投影顶层 `subscriptions`：每个已启用订阅只返回 `section`/`ref`、`display_name`、`cache_present`、`cache_sha256`、原始 `node_count`、`quota`、`last_attempt`、`last_success` 和 `last_result`，用于解释订阅条目与 Mihomo 已加载节点的差异；`last_success` 优先取最近一次 NetFleet 成功刷新事件，尚无事件时回退到设备上当前后端订阅缓存的实际修改时间，不使用测量时间或摘要推断；机场投影通过 `subscription_section` 明确引用对应条目，UI 不按显示名猜测绑定；不得返回 URL、token、节点名称或订阅正文；该读取不测速、不探测、不修改 selector；
- `events`：读取有界 NetFleet 决策事件和当前后端 core log 中最近的 `NETFLEET-` 行，字段为 `core_lines/core_lines_persistent`；不轮询、不修改 owner；
- `probe`：执行与设备 owner CLI 相同的一轮有界保护探测并返回真实结果；只读网络状态，不刷新订阅、不测速选优、不修改 selector、Profile 或服务；
- `enable`：在同一个 target-local mutation lock 内依次调用现有 `compile -> enable` owner；原生核心完全停止时由 activation 复用恢复 owner 建立已验证基线，再启用候选。实时状态仍提供启动入口；不接受浏览器上传的 policy、Profile 或候选；
- `select_auto`：只接受 status 已公开且当前可执行的 automatic 根 capability ID，调用现有 `select <capability> auto` owner 执行一次有界轮次，并把可见 selector 恢复到“自动选优”；
- `refresh`：不接受 URL、section 或订阅内容，只调用同一个 policy-driven refresh owner；来源凭据修改由独立 subscriptions_set 完成，浏览器不解析订阅内容；
- `disable`：调用与 CLI 相同的 native Profile owner/runtime 恢复并独立返回 `business_ok`；只有 runtime 无法恢复时才转入官方 cleanup passthrough，并返回 `safe`、`persistent`、`business_ok`。

## 浏览器宿主与读取边界

LuCI 入口是插件页面壳，通过共享 `plugin-host.js` 从安装清单组合导航，加载插件的
`mount(context)`，并在切页、更新和卸载时关闭旧作用域。React/Vite 的
`PluginApplication` 使用同一宿主模块；注入具备插件 API 的 client 时按清单加载页面。
`ui/` 同时保留本机实时只读和脱敏 fixture 参考开发入口，这些参考组件不作为设备部署产物。

默认设备的概览、出口、机场、地区、配置、组件与更新、事件与诊断由 `product-ui` 插件
贡献，页面源码和静态资源随该插件分发。其实现复用原生 LuCI 组件，生产宿主不强制第三方
采用某个界面框架。Zashboard 在产品工具区提供独立外链；配置页把网络接入和配置文件
与备份作为独立管理分区，不混入 policy 草稿的应用按钮。首次设置向导复用适用字段组件。
视觉语言、主题与组件规则由[UI 设计合同](../design/ui.md)负责。

页面 context 提供当前挂载节点、绑定插件和实例的读写 API、配置动作、动态 `readOnly`、
AbortSignal 和资源作用域。宿主校验每次写请求的当前权限，并绑定代码 revision；页面
声明不能绕过 RPC ACL。`navigate` 接受当前插件内的页面 ID 或清单中存在的全局页面
身份。具名实例的页面分别显示实例名，动作携带同一 instance。清单读取失败时保留已有
显示、标明错误并暂停写入；没有页面或加载失败时提供对应空态或重试入口。

LuCI 壳与 React 插件宿主每五秒读取插件清单，以发现安装、启停和 revision 变化；离开
宿主时撤销该读取。清单发现只读安装元数据，不执行业务状态读取、网络探测或插件代码。
插件页面的业务请求仍由各页面管理，清单刷新不触发默认产品的 status 轮询。

实时只读桥接的目标只从本机环境变量取得，只允许固定读取 `status`、`events`、`config_get`、`connections`、`components_get`、`operation_get`、`network_get`、`maintenance_get` 和 `diagnostics_get`，浏览器不持有 SSH 凭据，也不能通过该桥接调用任何 mutation；桥接结果必须显示目标、连接状态、最后读取时间和读取耗时。组件、网络配置、文件清单和核心日志按需独立读取，不并入常规网络快照。网络投影隐藏解析 URL 的凭据和私有路径，不返回认证密码；文件清单不包含正文或备份。`connections` 只在用户打开或刷新“事件与诊断”时从 Mihomo 当前 `/connections` 读取最多 50 条活动连接，投影目标 host/IP、目标端口、网络、命中规则、规则载荷和实际代理链；不得返回 source IP、进程、连接 ID、流量计数或其他不必要字段，也不得写入事件 owner、fixture 或浏览器展示缓存。该诊断使用 Mihomo 已执行的真实首条命中结果，不在 NetFleet 或浏览器中重做规则匹配。事件页以 NetFleet 持久化选路事件为主，活动连接只在默认折叠的辅助区显示；瞬时连接快照不能累计或外推为规则组触发频数，除非未来真实 owner 提供可去重、可定义生命周期的持久计数。fixture 仅用于离线、异常和边界场景，可在内存中模拟命令后的投影变化；它必须遵守当前接口形状且不得包含订阅、完整节点清单、设备地址或其他私有 target 数据，不是运行事实，也不能被生产 LuCI 页面读取。

### Dashboard 打开与资源版本

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

LuCI 宿主与传输适配使用包版本命名空间；插件页面资源位于
`/luci-static/resources/netfleet/plugins/<id>/<revision>/resources/`。入口、静态 import
子模块和样式使用同一 revision 目录中的相对资源，完整模块图随版本改变 URL。软件包与
源码部署共用投影入口，revision 与内核安装清单一致；不依赖只给入口增加查询参数或用户
清理缓存。文件布局与版本归属见[软件包合同](packaging.md#软件包组合)。

NetFleet 沿用 Nikki/Zashboard 的带凭据新标签页连接方式，controller secret 只用于本次
URL 构造，不得进入 NetFleet status、日志、展示缓存或文档。Zashboard 保留上游完整功能；
其中 selector 切换、连接关闭属于 Mihomo 当前运行态，不替代 NetFleet 的持久配置、订阅
编排、启停和恢复 owner。两种后端都保持独立完整页面，不嵌入或复制控制器。长期定位见
[设计白皮书](../product/whitepaper.md)和 [Zashboard 决策](../decisions/0005-zashboard-observation-surface.md)。

### 展示缓存与操作授权

已配置的默认业务页面首次挂载各读取一次 `status` 和 `events`，后续按页面进入、用户
刷新和操作完成读取，不建立全局 status 定时轮询。插件清单的五秒发现周期、运行中操作
的进度读取与业务状态读取分别管理；supervisor 周期不触发浏览器业务请求。
`connections` 不随页面首次加载或展示缓存刷新读取。

产品界面可以把最近一次成功读取的 `status`、去除核心原始日志后的 `events`、读取时间
和耗时保存为带 schema 版本的浏览器只读展示缓存。再次打开页面时先显示缓存，同时
读取当前 status/events；成功后原地替换，失败时保留缓存并显示旧数据年龄和刷新失败。
展示缓存不包含 connections，不参与编译、排序、候选资格、回滚、探测、mutation
前置校验或按钮授权。缓存启动和实时刷新失败时禁用 mutation；损坏或 schema 不匹配
的缓存直接忽略，无有效缓存时等待实时读取。缓存不持有插件清单、可执行代码或私有配置。

LuCI 的启用、单次选优、立即更新订阅、关闭和配置应用都必须二次确认，mutation 完成后重新读取 owner 投影。这些网络操作由 rpcd 调用 one-shot UCode owner；软件包更新由下述一次性后台事务执行。React 的实时设备桥接始终只读；React 配置页、向导、保存、校验和应用按钮只能改变浏览器内的本地预览草稿，必须持续标明“不会写入设备”，不得转发任何配置或 mutation 到 SSH bridge。浏览器不解析订阅、不实现编译、排序、候选资格、回滚或探测逻辑；生产按钮是否可用来自实时 owner 投影，浏览器缓存只能延续显示，不能延续操作授权。事件 owner 仍返回有界事件窗口，LuCI 的“选路事件”在这个窗口内按最新优先每 20 条一页展示，刷新后回到最新一页；分页不触发额外设备读取。所有涉及网络的 LuCI mutation、supervisor 网络动作和设备部署使用同一个短生命周期 lock，不能形成并行网络 writer。仅访问插件私有数据的服务动作可使用插件锁，与组合及备份事务的数据租约配合；锁与实例合同由[微内核](microkernel.md#作用域与实例)统一定义。

概览的“最近决策”只从 `enable|select|disable` 事件中选取最新记录，同秒按 owner 写入顺序取最后一条；`refresh` 是订阅操作摘要，不覆盖选路决策。事件列表对订阅更新显示实际变化数、失败数和更新结果，延迟标为“不适用”。只有明确的 `native_restored` 恢复事件才能显示“已恢复原生配置”；缺少路由字段只代表未记录，不能推断回退。退出直通按实际恢复原因显示“已恢复网络直通”，不显示测量缺失；订阅触发的选优标为“订阅更新后选优”。

## 组件与操作进度

`components_get.extensions` 由 `components.control` 使用内核清单投影插件安装版本、
代码 revision、服务与页面声明、实例、启用状态、接口 major 和依赖；`runtime` 区分 `service` 与 `process`。
它不表示运行健康，不触发网络检查或启动引擎；Zashboard 的资源状态
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
`operation_get` 返回订阅、选优和组件操作的最新进度：标识、状态、阶段、开始/更新时间、已处理数、
总数、当前对象显示名、脱敏错误码及恢复结果 `recovery`；恢复结果区分已恢复、恢复失败和
网络直通，未发生恢复时为 `null`，不能把恢复成功当作原操作成功。不返回 URL、凭据、命令
输出或无限增长的操作历史。
订阅下载、校验、编译、重载、选优、探测和回滚阶段由实际执行者写入；没有内容变化时直接
返回真实结果，不伪造后续阶段或百分比。执行进程消失但没有终态时显示中断未确认，不冒充成功。
初次加载与进入机场、组件页时读取一次当前操作；只在存在运行中操作时每秒读取独立进度，
结束后停止轮询并刷新受影响的数据。操作标识绑定执行结果，旧操作终态不能确认新请求完成。
终态结果可在浏览器会话内关闭；此显示偏好不修改 operation owner，不取消执行或隐藏当前
运行故障。完成时间使用设备 `finished_at`，缺失时不得把当前读取时间当作完成时间。

## 首次设置与策略配置接口

未配置设备额外暴露 `onboarding_get / onboarding_apply`。`onboarding_get` 只读当前后端
Profile、稳定 subscription cache 和节点地区，返回脱敏预览、阻断原因及绑定发现 revision；
不得返回订阅 URL、token 或节点正文。`onboarding_apply` 必须携带同一 revision 和显式确认，
在全局 mutation lock 内重新发现并拒绝漂移，然后由 `configuration.onboarding` 写入初始
policy，复用编译和激活服务、启动 supervisor 并回读。已有有效 policy 时 onboarding 接口只返回
`required=false`，不能覆盖现有配置；失败时必须恢复原生 Profile、服务状态和本次创建的文件。

设备端配置由 `config_get / config_validate / config_save / config_apply` 四个结构化 RPC 暴露。浏览器每次配置操作先读取 fresh `config_get`，并携带 policy SHA-256 revision；陈旧 revision 必须拒绝，展示缓存不得授权配置 mutation。唯一 target-local 配置 owner 发现当前后端已有稳定命名订阅、订阅 cache 中可识别的地区、当前 Policy Source 策略组和内置 Policy Source，把白名单结构化选择 merge 到现有 canonical policy、校验全部引用，并用同目录临时文件原子替换。`config_save` 只允许在 NetFleet 未接管时更新 policy，不改变数据面；active 配置必须使用 `config_apply`，后者先返回可解释变更供 LuCI 二次确认，再在全局 mutation lock 内快照旧 policy/artifact/manifest，复用 `disable -> compile -> enable` activation owner 切换，失败恢复旧字节和旧 active owner。

高级配置允许用户在设备已经存在的资源边界内维护结构：从当前后端已有稳定命名 subscription 新增或移除 provider；使用同一共享地区目录维护 provider-region mapping；新增、移除和命名 capability，设置其自动依赖和地区许可；把当前 Policy Source 已存在的策略组声明为 `entry|policy` binding；新增或移除 `domain_suffix` 或 `ip_cidr` 的 target-local routing rule，目标为启用的 capability 或直连。规则字段与校验由[产品对象](domain-model.md#配置解耦合同)负责。新增 provider 的稳定 ID 固定使用当前后端 subscription section，地区 filter 固定来自设备 owner 返回的共享目录，浏览器不能提交自定义正则。所有结构变化仍先经过完整 policy validator，并且必须保留至少一个启用的主用 provider、每个启用 capability 恰好一个 entry、automatic 依赖无环且恰好一个根。

policy 配置 owner 不接受 raw policy、订阅 URL/token、节点正文、DNS/nft 命令、浏览器生成的 Profile、自定义 provider cache 路径、自定义地区正则或 quota metadata 映射。订阅凭据单独提交给 subscriptions owner，不混入 policy；原生 DNS、代理范围和监听设置通过独立 network owner 的受限结构编辑。配置文件通过 maintenance owner 校验，不能借文件导入建立另一条配置应用链。OpenWrt flow-offload、WAN/LAN 地址和任意防火墙参数不属于这些管理表单。

## 请求时限与显示分工

LuCI 同步 mutation 与 rpcd/uhttpd execution timeout 使用 300 秒有界预算，覆盖启动收敛、测速、owner readback 和必要回滚；成功路径不会等待到上限。package post-install 和 deployment owner 都只在 rpcd 或 uhttpd 当前上限低于 300 秒时提升到 300，保留更高值并重启、回读 RPC surface，deployment owner 还必须把 `/etc/config/rpcd` 和 `/etc/config/uhttpd` 原字节纳入同一部署回滚。不得通过后台 worker、第二选择器或伪造提前成功规避这个 owner 事务。

事件与显示聚合见[显示证据](evidence.md)，生成拓扑见[编译合同](runtime-and-recovery.md#compiler)。

字段的用户解释、库存计数、空态和展示排序由[状态呈现](ui-state.md)维护；
历史聚合由[显示证据](evidence.md)维护。
