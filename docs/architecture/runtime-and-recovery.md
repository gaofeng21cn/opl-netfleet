# 运行、激活与故障恢复

本文是 compiler、staged/active 转换、activation、supervisor 和 Fail-Open 恢复顺序的
权威合同。对象身份见[产品对象与 Owner](domain-model.md)，选择规则见
[测量、资格与选择](selection.md)。

## 运行后端与原生网关

后端选择和 namespace 见[产品对象](domain-model.md#后端与订阅归属)。两种后端
共用下文的 compiler、activation 和选择合同；`adapters/backend.uc` 是 Profile、
服务启停和运行回读边界。Nikki 模式调用官方服务；原生模式由
`application/native_gateway.uc` 与 `opl-netfleet-core` 管理，不增加第二控制器。

原生服务使用固定版本的 Nikki `mixin.uc`、`hijack.ut` 和所需辅助模块。上游来源与
许可证保留，UCI namespace 和受控路径映射到 NetFleet。gateway 从当前 Profile、
私有 JSON mixin 与 UCI 投影生成 effective config；按开关替换列表和对象后再合并，
不能把原生配置与派生配置的 DNS 或规则列表重复累加。

当前支持 IPv4/IPv6 的 TCP 与 UDP TProxy，以及路由器本机和 LAN 的 DNS 接管。
默认使用 redir-host；TUN、auto-route、auto-redirect 和 redirect 模式不在当前支持面。
这是 NetFleet 的 OpenWrt 接管、排他与清理边界，不是 Mihomo 缺少这些功能；当前
配置界面也不提供未经该生命周期适配的模式切换。
不满足监听器、后端排他或路由身份前提时拒绝接管，不借机修改 WAN/LAN 地址或默认路由。

`prepare` 只读取已选 Profile 并生成候选 JSON，经真实 `mihomo -t` 后原子安装到
`/etc/opl-netfleet/native/run/config.yaml`；扩展名供既有适配器使用，正文仍是 JSON。
procd 直接持有 Mihomo 子进程，并提供有限 respawn。gateway 通过精确命令、真实 PID、
私有 Unix controller 和服务 cgroup 确认运行 owner；LAN controller 仍由 API secret 保护。
同服务的轻量生命周期实例订阅 procd 的真实 service 通知，在通知回调退出后调用同一
加锁 reconcile：核心退出时清理截获，新核心就绪后重新 attach，重试耗尽时保持直通。
它不测速、不选路，也不构成核心存活证据。正常 restart 等待旧核心退出后才启动新核心。

`attach` 在核心就绪后渲染上游 nft 模板，先检查规则语法、既有 table/路由冲突，再写入
本 owner 的 IPv4/IPv6 策略路由和 `inet netfleet` table。cgroup 排除避免核心流量再次
进入自身代理。路由身份、受影响地址族与原 bridge 参数写入私有 ownership 对象，
只用于本 owner 的清理，不作为另一个网络配置源。

停止和失败收口先删除拦截，再撤销本 owner 的策略路由并恢复其修改的 bridge 参数。
发现不明来源 table、身份不匹配或无法回读清理结果时报告失败，不清除其他 owner 的状态。
服务正常退出、崩溃后的恢复与停止都必须取得实际运行或清理证据；不能用 procd 注册、
配置文件或源码存在代替就绪。VM 只证明其隔离环境内的路径，真实设备与发布包另行验收。

网络表单、配置备份恢复和显式核心维护同样进入上述运行 owner，不直接写生成的
nft/路由对象。network owner 先校验候选配置，再保存旧声明和运行选择，调用原生服务
应用并回读；maintenance owner 的重启、重载及备份恢复也保留用户选择并验证网络，
失败恢复原文件和运行状态，无法证明恢复时停止核心并执行正式清理。Zashboard 资源
更新只交换经校验的静态目录，不重启核心或修改连接凭据。各事务的输入与持久化范围见
[设备独立管理](management.md)，不得由 UI 另建恢复路径。

## 首次设置与迁移

空白设备的 `native-setup-get` 只读检查依赖、现有 owner、私有配置和可达上游 DNS。
显式 `native-setup-apply` 绑定该 revision，建立私有 UCI、随机 controller secret、
订阅与 DNS 配置，下载并验证订阅后启动正式 gateway。只有 gateway 与共享 onboarding
发现都可回读时才启用开机服务；成功结果明确 `onboarding_required=true`，随后由用户
确认共享接管预览。它不覆盖已有 Nikki/native 配置，不让软件包安装隐式启用代理。

`migration-get` 只读识别正在工作的 Nikki、当前 policy、订阅、恢复 Profile、私有 mixin、
Profile 引用的资源与 Dashboard。准备目录中保留完整订阅和所需资源，只映射当前受控
Nikki 路径到原生目录；不会从品牌名猜配置，也不靠重新下载取代已有可用输入。

`migration-apply` 必须明确确认且 revision 未变。它在共享设备锁内保存原 UCI、
后端选择、policy/evidence/events、服务与开机状态；先通过源业务探针，再暂停 supervisor，
停止并清理 Nikki，安装私有原生投影后切换 selector。原生恢复配置就绪后执行同一个
`compile -> enable -> status/probe`，全部通过才启用原生开机服务和 supervisor。
成功后 Nikki 不再运行或自动启用，原配置仍保留，不建立双写或运行时自动回落后端。

迁移失败先确认原生拦截已清理，再恢复原文件、selector 和 Nikki 启动状态，使用已接受
缓存恢复旧 runtime 并回读 Profile 与业务。清理或恢复不能证明时保留隔离恢复目录，
返回真实 blocker，不删除证据或重启设备。首次设置失败同样恢复设置前状态，不伪造
一个原本不存在的旧运行 owner。

## 唯一纵向链

```text
target-local UCI
  + PolicySource
  + selected subscription cache
    -> one-shot compiler
       -> staged profile + manifest
          -> enable transaction
             -> selected backend profile switch/restart
                -> Mihomo current owner state

RecoveryProfileRef
  -> enable precondition / rollback / disable / recover
     -> selected backend profile switch/restart
        -> cleanup / passthrough only if recovery fails
```

新增运行机制必须服务于这条真实调用链；开发准入规则见[AGENTS.md](../../AGENTS.md)。

## Compiler

compiler 是无后台状态的一次性转换：

1. 读取 policy、Policy Source、Recovery Profile 身份和所选后端已落盘缓存；
2. 保留 Policy Source 的规则顺序和未绑定组；迁移 Profile 中已有的 DNS 逐字保留，内置 bundle 不声明 DNS，设备 DNS 继续由所选后端的 Profile/mixin owner 提供。target-local `routing_rules` 在开头连续的管理链路直连规则之后、其他分类规则之前投影为 Mihomo 规则：域名后缀生成 `DOMAIN-SUFFIX`，IPv4/IPv6 CIDR 分别生成 `IP-CIDR`/`IP-CIDR6` 并带 `no-resolve`；目标由 capability ID 解析为可见 selector，或明确指定 `DIRECT`。它们只存在于生成 Profile，不进入后端全局 mixin 或 Recovery Profile。随后把每个 `entry` 的规则目标及组引用改写到 capability 可见 selector，删除旧入口及仅由该入口可达、现已 caller-zero 的旧 Auto/地区闭包；不依赖 `hidden` 维持用户界面正确性；
3. 每个 capability 生成一个由 `display_name` 命名的可见 selector，成员固定为“本能力自动选优 / 共享地区出口 / DIRECT”。根能力拥有唯一一套可见地区出口；声明 `prefer_region_from` 的跟随能力复用上游能力的地区出口，并按自身允许/排除地区过滤，不再生成只差能力前缀的重复可见地区组。跟随能力仍保留自身 automatic 候选链，以维持独立资格和自动决策。每个 `policy` 业务组保留原名并使用其绑定能力的相同成员，Policy Source 以 `DIRECT` 为首项时只调整默认顺序，不直接暴露机场叶子。这些中文模板以及“主用机场 / 备用机场 / 当前优选 / 代理路径”是当前生成 Profile 的合同，由 compiler 拥有，不是 UI i18n，也不是 policy 字段。地区名称由 policy 的 `flag + display_name` 生成，机场名称来自所选后端 subscription metadata；稳定 ID 只保留在 manifest；
4. Mihomo provider `exclude-filter` 只做通用输入卫生，正则是 compiler 常量 `PSEUDO_PROXY_FILTER`，不是 policy 字段，也不决定 automatic 资格；automatic 模式的 Provider 级 fallback 还必须使用该 Provider 全部已授权 `provider_regions` filter 的并集，未映射节点、未知地区和订阅元数据不得进入 automatic 或机场回退；
5. 校验引用完整性、循环、重复稳定身份和 `mihomo -t`；
6. 原子写入 staged JSON 与同批 manifest，建立并回读所选后端根目录稳定入口；入口、内部 artifact 摘要和 `mihomo -t` 必须同时一致。

provider 的唯一路径是引用所选后端的 subscription cache。每个 enabled provider 由稳定
section 派生路径；compiler 确认 section owner 与可用 cache 后生成 `type:file` source，
并在对应 Mihomo run 目录内建立指向该 cache 的受控 symlink。只允许在自身命名空间内
原子改向同一后端的合法 subscription cache；普通文件、越界目标或其他 owner 文件拒绝覆盖。
compiler 不下载、合并或复制节点。订阅下载、凭据与内容校验属于唯一 subscription owner，
运行更新则属于下文共享 refresh 事务。

Provider/地区候选组使用 `checks.latency` 的 Mihomo 原生 `url-test` 负责同目标 delay 和叶子切换；同地区聚合入口先在 primary Provider/地区候选中按同目标 delay 选择，再进入 reserve，最后 DIRECT。Provider tier 组使用 `path_probe_id` 的业务健康合同，不拿测速目标冒充兜底资格。automatic 模式的每个 Provider 组必须同时应用该 Provider 已生成地区组的授权 filter 并集，不能退回未过滤的机场全集；因此 preferred 与 primary/reserve tier 共享同一地区授权边界。compiler 生成 `visible capability selector -> automatic path | shared region aggregate | DIRECT`；automatic path 固定为 `当前优选 -> primary provider tier -> reserve provider tier -> DIRECT`，每个 tier 内由 Mihomo 在该层精确列出的 provider group 中选择健康路径。买断机场是否作为兜底只由其 provider `role=reserve` 表达。策略来源中的 `policy` 业务组会展开为同一 capability 的自动出口、全部合规共享地区和 DIRECT；原始组以 DIRECT 为首项时继续以直连为默认，否则以自动出口为默认，从而允许国内媒体、Steam、Xbox、PlayStation 和 Nintendo Switch 等业务在 Zashboard 临时改路但不改变其重启后的默认策略。Profile 顺序固定为 capability 出口、策略来源顺序中的 `policy` 业务组、其他保留组和 NetFleet 内部组；Mihomo 保留的 `GLOBAL` 只代表全局模式控制面，Policy Source 不得再创建大小写近似的 `Global` 业务组。内部组仍设置 hidden 供支持该字段的客户端使用，但正确拓扑和可见业务组绝不依赖 hidden。生成物不复制节点、订阅、DNS、Policy Source 或 Recovery Profile。`DIRECT` 是明确的终端数据面逃生路径。`fail_open.probes` 是 enable/select 的成功条件；DIRECT、Recovery Profile 恢复和 passthrough 只把同一结果作为独立业务证据。artifact manifest 分别保存 Policy Source 和 Recovery Profile 的 ref/digest，并保存稳定 ID、entry/policy 映射、全部显示组、精确有序的 Fail-Open stages、provider section、runtime source path 和 policy digest。

内置 bundle 的业务分类只引用同一上游 commit 的锁定 MRS，不维护第二份按域名手抄的服务清单。Mihomo 按规则数组首条命中，因此顺序固定为：Tailscale/管理链路直连、target-local `routing_rules`、私网 domain/IP、AI、Netflix、YouTube、Telegram、社交媒体、Steam/Xbox/PlayStation/Nintendo、Microsoft/Apple/Google、国内媒体、CN domain/IP、`geolocation-!cn`、`MATCH`。更具体业务必须在更宽泛的厂商、CN 或非 CN 分类之前；IP 规则使用 `no-resolve`，避免为了匹配规则额外解析。没有当前真实分类规则的“下载”等分组不得存在；需要临时改路的现有业务组统一由 compiler 展开为自动出口、共享地区出口和 DIRECT 的排列组合。

显示证据的持久化和可比性见[显示证据](evidence.md)；它不参与编译或选择。

手动和自动模式都生成 Provider 级 URLTest 组；自动模式的 Provider 级组只包含已授权地区映射，作为数据面机场回退，另生成 Provider/地区 URLTest 候选组供一次 `select auto` 比较。编译仍只引用已接受的订阅 cache，不复制订阅，也不允许未映射节点通过机场回退绕过 automatic 资格。

一个全局、隐藏、只含 `DIRECT` 的直连护栏组专门承接 path/guard 健康检查。保护探针的 delay 只写入该内部组历史，最终数据路径仍为 `DIRECT`，但不得污染 Mihomo 内置 `DIRECT` 在 Zashboard 中的节点延迟。用户可见策略的手工直连仍直接选择内置 `DIRECT`。

## Activation

配置、订阅、首次设置、迁移、设备维护及 `onboarding_apply|compile|enable|disable|select|refresh` 均由 `main.uc` 的前台命令入口执行；`core/activation.uc` 只提供纯函数判定。网络配置、备份恢复、核心维护和 Zashboard 更新与这些动作共用设备 mutation lock，不能并行替换运行输入。supervisor 只通过同一个锁调用内部 `maintain|refresh|recover`，不得直接写 UCI、subscription cache、selector、DNS、nft 或路由。

- onboarding preview 完全只读；apply 在同一锁内重新绑定所选后端当前 Profile、subscription cache
  和生成 policy revision。package 安装不触发 apply；只有用户在 LuCI 明确确认才进入事务；
- onboarding apply 使用当前原生 Profile 同时作为初始 Policy Source 和 Recovery Profile，
  因此不需要 host 生成 policy、复制订阅或下载内置 ruleset。成功前原始 Profile 不得变化；
- onboarding apply 失败时先使用仍在场的新 policy/manifest 调用同一 disable owner 恢复原生
  Profile，再删除本次生成的 policy/artifact/provider link，并恢复 supervisor 原状态；恢复无法
  证明时返回真实 recovery blocker，不得继续覆盖或报告完成；

- compile 仅在 NetFleet Profile 非 active 时执行；
- enable 要求所选后端当前 Profile 仍是 RecoveryProfileRef，且 staged 中 Policy Source、Recovery Profile、policy 和 artifact 身份均未变化；`kind=profile` 还回读原入口 selector 供事件解释，`kind=bundle` 不要求 Recovery Profile 存在同名组，失败恢复始终切回完整 Recovery Profile；
- enable 先安装完整 artifact，再调用所选后端 Profile 切换与 restart；
- enable 后先给所选后端与 Mihomo 一个有界的 owner-readiness grace，确认 capability group 已发布且包含目标成员后只写一次 selector，再等待所选 provider/地区组出现真实叶子并回读 owner 状态和所有 target-local protected probes；所有 `automatic` capability 的可见 selector 必须最终精确回读为其“自动选优”成员，实际数据路径必须是优选或自动 fallback，不能把 `manual DIRECT` 当作启用成功；选定路径后只对该候选组执行一次 Mihomo 原生路径健康确认，刷新组级健康状态，不再并行遍历全部可见分支，结果不参与候选排名或延迟统计。未使用分支或祖先组在重启收敛期暂时报告 `alive=false`，不能推翻已绑定真实叶子、实际链和事务探针的成功 readback；grace 内只等待启动和 provider 收敛，不重试 selector 或健康确认；超时仍恢复原 Profile；
- enable、select 或其异常处理在 active artifact 上失败时，先把全部 active capability guard 切到 DIRECT 并逐一回读，再只执行一次保护探针，随后恢复 Recovery Profile。原生 owner/runtime 恢复成功就停止 mutation，并把保护探针结果独立返回，不能因为远端业务探针失败而关闭一个健康的原生 owner；runtime 恢复失败时才调用所选后端 stop/cleanup 进入 passthrough，绝不重新启用已失败的 NetFleet Profile；
- disable 先恢复 RecoveryProfileRef 并验证原生 owner/runtime；恢复成功即完成关闭，`business_ok` 单独返回。只有原生 runtime 无法恢复时才调用所选后端 stop/cleanup；`safe && persistent` 即可完成 passthrough，两项前提任一无法证明时拒绝卸载；
- refresh 是唯一运行应用 writer：全局更新范围由启用 provider、Profile 型 Policy Source、
  Recovery Profile 和当前 subscription Profile 的真实引用去重形成。单项更新只下载指定
  来源；来源已被任一对象引用时仍进入同一运行应用事务，真正未使用的来源只下载并校验缓存。
- Nikki 模式调用官方 updater；原生模式调用 subscription owner，保存原 cache 与
  `netfleet` UCI 元数据。上游不可用不开始更新；单来源失败保留其 LKG，不能擦除其他有效来源。
  全部内容摘要不变时只提交成功时间、quota 和来源接受身份，不 compile、restart 或修改 selector。
- 内容变化且 NetFleet active 时，保存 artifact/manifest、原生订阅元数据与全部可见 selector，
  重新编译、重启、恢复用户模式并执行共享 automatic 轮次和 protected probes。任一编译、
  owner readback、选择或探针失败，恢复更新前 cache/UCI/artifact/manifest 与原 NetFleet runtime。
  所以“下载成功”不能单独宣称运行更新成功。
- NetFleet inactive 但原生 core 已运行时，被当前 Profile 或其编译输入引用的变更仍须重载
  当前 Profile 并取得 owner readback；失败恢复旧 cache/UCI 和原运行状态。原来未运行的
  core 不因普通 refresh 被启动。Nikki 模式继续遵守官方原生 Profile 的生命周期边界。
- 订阅状态投影来源、有效缓存、摘要、额度、尝试/成功时间及当前 pending/LKG 状态；
  refresh 事件只记录 section、结果和 digest，不包含凭据或正文。
- 用户已在所选后端切到其他原始 Profile 时，NetFleet 不再把旧派生 Profile 视为 active，不擅自重新接管；
- uninstall 先执行同一 disable 合同并停止 supervisor，再通过精确 symlink target
  所有权检查删除 NetFleet 生成的 Profile、manifest 和 provider links；恢复失败或
  生成物所有权不匹配时拒绝卸载，不删除运行文件或第三方 Profile。原生核心包卸载另须
  停止 `opl-netfleet-core` 并回读接管清理，不能把仍依赖待卸载核心的恢复 Profile 当作终点。
- supervisor 每次只做轻量 owner readback。当前可见 capability selector 选择“自动选优”时，按 `selection_interval_seconds` 调用同一个 `select auto`；任何 capability 处于手动地区或 DIRECT 时暂停这组依赖能力的定期选择。`subscription_refresh_enabled` 默认开启，按 `subscription_refresh_interval_seconds`（默认 `43200`，12 小时）调用同一个 `refresh`；锁忙时不把失败尝试当作已执行。Mihomo/controller、LAN TProxy ingress 或 DNS 接管连续失联超过 `runtime_grace_seconds` 时调用同一个 `recover`；锁忙或恢复失败不重置失联起点，下一轮继续尝试。LAN ingress 以 effective `allow_lan`、TCP/UDP `7892` wildcard listener 和所选后端 nft TProxy rule 为准；DNS 接管以 effective `dns_enabled`、TCP/UDP DNS listener、所选后端 LAN DNS redirect rule，以及保护探针域名经路由器 resolver 的真实解析为准。进程/controller 失联优先恢复 Recovery Profile；LAN/DNS ingress 属于所有 Profile 共享的平台故障，切换 Recovery Profile 不能修复，因此直接调用所选后端 stop/cleanup 并持久进入 passthrough。恢复成功后 NetFleet 不再拥有数据面，失败后等待下一次 owner readback，不在同一轮反复重启。

网络 mutation 必须使用 fresh precondition digest。是否需要分离的 `plan -> apply` 公开接口由第一条真实远程 caller 决定；不得为了没有 caller 的协议预先维护 worker、Host、schema 或 operation history。

部署器的输入、资格与目标端事务见[Fleet 部署事务](../operations/deployment.md)。

## Fail-Open

Fail-Open 的终点是数据面可脱离代理，而不是“所有业务探针都必须成功”。active guard、原生恢复和 passthrough 都把数据面/readback 与 `business_ok` 分开：`DIRECT` guard 以 selector/runtime readback 为安全条件；原生恢复以 `runtime_ok` 为安全条件；passthrough 以 `safe && persistent` 为安全条件。`safe` 表示所选后端 cleanup 已停止其 Mihomo、撤销其 DNS/nft 接管、策略路由和所创建设备；`persistent` 表示下次后端启动不会再次选择失败的 NetFleet artifact；`business_ok` 表示保护探针结果，可为 `true`、`false` 或 `null`（未执行/无法判定）。远端业务失败不能推翻已经成立的数据面安全终点，也不得触发重启、重新启用或伪造业务成功。

数据面退路顺序固定为：

```text
preferred -> primary provider tier -> reserve provider tier -> DIRECT
```

Mihomo 仍运行时，代理组自行沿该链路选择，`DIRECT` 是明确的终端出口。内层 path probe 失败后先在全部主用机场中按同一健康目标选择，主用层全部失效后进入备用机场；外层 guard probe 失败后进入 DIRECT。两层都由 Mihomo 按 policy 的 interval 和失败次数运行。NetFleet supervisor 只调度跨地区轮次和进程失联 grace，不轮询业务 URL，也不介入 Mihomo 数据面 fallback。Fallback 不会重放已经失败的同一个连接：故障瞬间允许一个请求失败，后续连接才使用新的成员。Recovery Profile 不在 active Profile 内复制；它只在事务失败、disable、supervisor recovery 或用户显式切回原始 Profile 时恢复整个 owner。Mihomo 或运行后端本身异常，或事务回退无法证明 Recovery Profile 可用时，NetFleet 只调用所选后端 `stop`/cleanup 进入 passthrough；增强策略层不自行删除 DNS、nft、路由或进程；清理由所选后端的唯一生命周期 owner 执行。业务探针结果不是 cleanup 或持久化的门槛，也不允许伪造成功。

| 故障 | Owner 动作 |
| --- | --- |
| 安装/compile/staged 校验失败或 WAN 上游不可用 | 当前后端 Profile、DNS、nft、路由和服务完全不变 |
| enable、owner readback 或 protected probe 失败 | active guard 先切 DIRECT 建立即时安全护栏，再恢复 Recovery Profile owner/runtime；runtime 失败才调用所选后端 stop/cleanup。保护探针失败单独报告，绝不重新启用失败的 NetFleet Profile |
| 手动 select 后 protected probe 失败 | 恢复原 selector；selector 回退失败则先切 active guard 到 DIRECT，再恢复 Recovery Profile，原生 runtime 失败才进入后端 passthrough |
| 单节点或同地区单 provider 失败 | connection refused 立即、其他错误按 `max_failed_times`/timeout 窗口触发原生 health-check；当前叶子失活后下一次选路换叶子，健康叶子只有替代项严格快超过 `leaf_switch_margin_ms` 才换 |
| 当前地区仍可用但替代地区 proxy-path delay 优势小于 `selection.region_switch_margin_ms`（默认 150） | 保持当前地区 |
| 当前地区无合格叶子，或替代地区 proxy-path delay 至少快该门槛 | 选择最快合格地区 |
| Provider 明确 quota exhausted | 下一次 enable、显式或定期 automatic 轮次中排除；不建立独立 quota 轮询。若耗尽造成当前优选链实际失败，Mihomo fallback 先用其余合格 primary，全部失败后才进入 reserve，最后进入 DIRECT |
| 当前地区所有 primary 失败 | 在 manifest 已声明的 primary provider tier 内使用其他健康路径 |
| 全部 primary 失败 | 选择 reserve |
| preferred 地区链失败 | Mihomo 原生 fallback 先使用精确列出的 primary provider tier，再使用 reserve provider tier，最后使用 DIRECT；NetFleet 进程和 UI 不参与 |
| preferred 仍通过速度 URL，但 path/guard protected probe 失败 | Mihomo 按 `path_probe_id` 切换 provider；`guard_probe_id` 仍失败时进入 DIRECT；定期重排仍按自己的周期运行，不由这次业务失败创建第二轮 |
| 显式轮次全部候选失败 | 当前保护路径健康则保持实际 fallback；否则按 active guard DIRECT -> Recovery Profile -> 后端 passthrough 恢复 |
| supervisor 或 UI 失败 | 不改变当前数据面；supervisor 由 `procd` 重启，用户仍可调用关闭 owner 恢复原始配置 |
| 运行后端/Mihomo 连续失联，或 LAN TProxy/DNS 接管链失效且劫持可能残留 | supervisor 超过运行 grace 后调用 activation owner；进程/controller 故障先尝试 Recovery Profile，LAN/DNS ingress 故障直接调用所选后端 stop/cleanup；锁忙时下一轮继续尝试，supervisor 不自行清理 DNS/nft/路由 |
| disable/uninstall 原生恢复失败 | 不重新启用 NetFleet；调用所选后端 stop/cleanup。若 `safe && persistent`，关闭/卸载可以成功，即使 `business_ok` 为 `false`/`null`；否则拒绝删除并保留 artifact |

增强算法与 supervisor 不直接修改 nft、DNS、默认路由或防火墙。Nikki 模式交由官方服务清理；原生模式只清理 gateway 持有的接管对象，不修改默认路由或其他防火墙 owner。若 stop 后直连保护域名本身不可达，系统只能如实报告该物理出口限制；这不表示 cleanup 失败，也不能声称“代理耗尽后仍保证这些域名可用”。

运行期闭环由唯一 supervisor 完成：NetFleet Profile 是当前 owner 时读取所选后端 enabled、Mihomo 进程、controller、LAN TProxy ingress 和 DNS 接管状态；只有整条本地接管链健康才清零失联起点。连续失联超过 `runtime_grace_seconds` 后，在全局 mutation lock 下调用 `recover`。进程/controller 故障先恢复 Recovery Profile；所有 Profile 共享的 LAN/DNS ingress 故障先由后端 cleanup 进入 passthrough。自动降级不撤销启用意图：activation owner 在设备私有 `recovery.json` 中保存绑定后端和 Recovery Profile 的恢复请求与重试时间，重启后仍有效。supervisor 每隔至少 300 秒调用同一 owner 的 `resume`，经过上游检查、恢复配置准备、重新编译、启用和业务回读；失败继续保留安全恢复配置或 passthrough，成功清除请求。关闭周期选优不关闭故障恢复。手工 disable 即使当前已降级也清除请求；策略关闭、后端变更或用户切换到其他 Profile 时不自动接管。状态保留真实 `active`，另投影 `recovery`，界面将自动降级显示为“降级恢复中”，不冒充手工关闭。supervisor 不修改后端 respawn 参数、不捕获每个进程事件、不轮询远端业务 URL；DNS 查询只验证现有本地 resolver，业务验证仅发生在恢复事务内。
