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

仓库只在这条链的第一个真实 caller 出现时增加相应文件。不得先建立通用 framework、第二下载器、兼容层或空 facade。

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

`/etc/opl-netfleet/evidence.json` 是唯一 display evidence owner，并位于 OpenWrt 持久 overlay；不得放在指向 `/tmp` 的 `/var` 下。每次成功的 enable、显式或定期 `select auto` 按 capability 覆盖保存本轮有界候选结果，并分别维护固定空间的机场和地区 delay 聚合；每个机场或地区在一轮内只记其最小有效 delay，全局机场表和地区表都只投影根 automatic capability。聚合身份只绑定实际延迟测量口径（测量模型、URL、期望状态与 timeout），不绑定完整 artifact、Policy Source 或 policy：代码、显示文案、Fail-Open、自动周期、设备重启或其他不改变延迟可比性的更新不得清空历史。机场、地区或 capability 拓扑变化时，当前轮按稳定 ID 保留仍存在对象的聚合、移除已不存在对象并从单样本建立新增对象；测量口径变化才整体重置。旧 identity 在精确匹配当前 artifact/policy 时允许一次无损升级到新口径；部署 owner 首次升级时把仍存在的旧 `/var/lib/opl-netfleet/evidence.json` 原子迁入持久 owner，成功后删除旧路径，失败回滚恢复原字节。该聚合只用于 status/LuCI 展示，selector 永远只读当前轮，不得读取平均值或历史值。evidence 缺失、损坏或写入失败必须被忽略，不能阻断 enable、select、disable 或原生恢复。LuCI 同步 mutation 与 rpcd/uhttpd execution timeout 使用 300 秒有界预算，覆盖启动收敛、测速、owner readback 和必要回滚；成功路径不会等待到上限。package post-install 和 deployment owner 都只在 rpcd 或 uhttpd 当前上限低于 300 秒时提升到 300，保留更高值并重启、回读 RPC surface，deployment owner 还必须把 `/etc/config/rpcd` 和 `/etc/config/uhttpd` 原字节纳入同一部署回滚。不得通过后台 worker、第二选择器或伪造提前成功规避这个 owner 事务。

`/var/lib/opl-netfleet/events.json` 是固定上限的持久化 owner 事件，不是 operation history 或选择输入。它记录 one-shot owner 已实际完成的 enable、select、disable 和 subscription refresh；refresh 事件只保存执行时间、聚合结果、机场总数/变化数/失败数、是否重载、调用来源，以及每个稳定 section 的 `result`/`digest`，不保存 URL、token、节点、cache 内容或完整配置。写入失败不改变数据面结果。调用来源只允许 owner 已知的 `luci|cli|deployer|supervisor`，未知入口如实记录 `unknown`，不能据进程或时间猜测。Mihomo 自主 health-check/fallback 继续写所选后端管理的 core log，NetFleet 日志页只读展示其中与 `NETFLEET-` 相关的最近行，并明确受所选后端日志清理策略约束；NetFleet 不为捕捉每次叶子变化增加常驻监听器。

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
- refresh 是唯一运行应用 writer：更新范围由启用 provider、Profile 型 Policy Source、
  Recovery Profile 和当前 subscription Profile 的真实引用去重形成。指定来源已被任一对象
  引用时仍必须进入同一事务；只有真正未使用的新来源才允许单独下载。
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

### Canonical 部署事务

本节描述现有面向 Nikki 的 Fleet deployment bundle 安装入口；原生首次设置与后端迁移
使用上文设备端事务，不能把该四文件 bundle 或 host 部署器作为原生独立安装的前置条件。

开发、虚拟机资格验证和设备写入是三个独立阶段。开发 worktree 只产生经验证并吸收到远端 canonical `main` 的 source；QEMU 启动官方 OpenWrt 镜像，验证真实 BusyBox、`/var -> /tmp`、ubus/rpcd/procd、隔离安装和失败回滚后，才为该精确 commit/tree 生成一次 qualification receipt；设备部署只接受一个显式 Git ref，解析并冻结其 commit/tree，从 Git object 构建 bundle，不读取 checkout 的 dirty 或未提交字节。bundle 包含逐文件 SHA-256 和 source identity，目标端只用一次性前台进程执行，不增加 daemon、queue 或 operation history。VM receipt 只证明通用 OpenWrt 控制面和回滚合同，不证明机场、真实 DNS/TPROXY、硬件驱动或业务路径。

目标端部署 owner 使用独立短生命周期 `flock`。默认模式只允许 native/inactive target 安装并停在 staged；发现 target 正由 NetFleet 管理时不做 mutation，要求调用者明确选择后续动作。`--leave-disabled` 才授权将已有 active owner 恢复到 Recovery Profile 后安装并停在 staged；`--activate` 才授权完成 data-plane 切换，而且 host 必须验证 qualification receipt 的 `qualified=true`、source commit/tree 与本次 bundle 精确一致。receipt 缺失、过期或不匹配时在 SSH 前失败。不带 deployment bundle 时只升级已有设备安装；提供 bundle 时是完整声明式安装。deployment bundle 目录必须同时包含 `policy.json`、`subscriptions.json`、`nikki-mixin.yaml` 和 `platform.json`，缺一即在传输前失败。当前 CLI 参数名仍为 `--instance`，它只指定这个四文件 bundle，不代表 OPL Instance 的位置或配置 owner。`subscriptions.json` 只声明稳定命名 section、显示名、HTTPS URL 和可选 UA/info URL；Recovery Profile 和 provider 必须引用这些稳定 section，`kind=profile` 的 Policy Source 同样必须引用已声明 section，`kind=bundle` 则必须解析到随包安装且通过摘要校验的稳定 JSON 基线。任何对象都不能引用设备随机生成的 `cfg...` 或 UCI 数组序号。

安装器先用当前签名软件源补齐缺失的 Nikki/Mihomo/UCode/`yq` 等依赖；只安装缺失包，不执行 whole-system upgrade 或绕过签名。包管理器、架构或软件源不支持时，在数据面 mutation 前返回结构化不兼容结果。随后校验全部 bundle SHA、policy/platform schema、订阅 section 唯一性、HTTPS 来源、Policy Source、Recovery Profile 引用和 mixin YAML。公共 ruleset lock 固定上游 commit、HTTPS URL、`domain|ipcidr` MRS 格式、大小、SHA-256 与许可证；目标端在任何 device mutation 前下载到 `/tmp` staged 并逐项验真。Nikki runtime 可用时下载必须使用 controller 回读的 loopback mixed proxy 并复用其 UCI 认证，避免把路由器本机 root 流量误当成透明代理流量；没有可用 runtime 时才显式无代理直连。两条路径都不把下载的 MRS 数据提交或打进 source/package，也不追随 mutable `latest`。下载、TLS 或身份不符时零写入失败。之后才保存 `/etc/config/nikki`、`/etc/config/firewall`、mixin、相关 subscription cache、已安装 MRS 及全部 NetFleet state 的单槽 snapshot。已有 active owner 必须先通过 status/probe再 disable；全新设备不虚构旧 owner 门禁。

该 Nikki 部署入口的原生配置准备阶段由部署 owner 创建稳定 UCI section，并逐个调用 Nikki 官方 `update_subscription`；缓存下载、metadata 和格式验证仍由 Nikki 负责，Nikki 模式的增强 runtime 不另行下载订阅或更新规则集。payload 必须先解压到 `/tmp` 隔离目录，只能从该目录逐项复制 owner 白名单，任何 tar 都不得直接解压到 `/`。随后原子安装 payload、mixin、`platform.json` 映射的 UCI 和 `0600` policy；锁定 MRS 必须原子安装到 Mihomo home 内的专用 `/etc/nikki/run/rulesets` 目录，使 Nikki 启动前校验、procd runtime、LuCI restart 和系统启动共享同一读取边界。平台值固定为 TCP/UDP TProxy、TUN off、redir-host、fake-IP cache off、LAN 可达 controller、API secret required、LAN listener enabled、sniffer 不改写目标、软/硬 flow offload off，其他值仍由显式 platform 字段决定。controller 监听 IPv4 任意地址以兼容 Nikki 官方 Dashboard 从当前 LuCI 主机名直连 `/ui/` 的实现；`allow_lan` 必须开启，否则 Mihomo 会把 TProxy listener 绑定到 loopback，nft 虽能标记 LAN 包却无法把公网目标包交给 `7892`。OpenWrt LAN zone 允许访问，WAN zone 必须拒绝输入；controller 由 API secret 保护，显式代理认证继续由 target-local Nikki 配置负责。Nikki 继续从 UCI 生成 effective Profile、nft 与策略路由，部署器不手写这些运行面。发生原生输入变化时，完成 Recovery Profile owner/protected-probe readback 后执行 `compile -> staged readback`；只有 qualified `--activate` 才继续 `enable -> owner/status/probe/parity readback`。RPC loader 不属于数据面 owner：readiness 必须同时验证本机 ubus、`luci` 与 `opl-netfleet` 完整方法表，以及使用临时最小权限 session 调用 `luci.getFeatures` 的 HTTP `/ubus` bridge。只有本机 surface 缺失或 timeout 不合格时才允许一次官方 `rpcd restart`；本机 surface 正常而 HTTP bridge 失效时只允许一次 `uhttpd restart`，随后重新验证 HTTP RPC，且两者都不得触碰 Nikki/NetFleet 数据面。snapshot 恢复触发 rpcd reload 后也必须 best-effort 恢复 uhttpd bridge。同一 source/instance/active 身份重放不得刷新订阅或重启数据面。仅 LuCI owner 字节变化时，显式 `--presentation-only` 不要求新的 QEMU receipt；但 bundle 的非 LuCI runtime 摘要、target installed identity、实际 runtime 文件、policy、订阅、mixin、platform、MRS 与 rpcd timeout 必须全部匹配，且 active owner/status/probe 已通过，部署器才可短暂停止 supervisor 并在不 disable/compile/enable 数据面的情况下替换 owner payload。任一前提不满足必须在 snapshot 和 owner 字节写入前拒绝，不能自动降级为普通激活；完成后仍须 validate、status、probe 和 installed parity，失败按原 control-plane snapshot 恢复。

订阅、mixin、Policy Source、Recovery Profile 或 NetFleet 任一步失败，部署器先撤销新 active，再从隔离目录逐项恢复 snapshot 中的 Nikki 配置、mixin、cache、原 Profile 和 NetFleet 字节；原设备没有 Profile 时回到 Nikki 官方 stop/passthrough。原 Profile 的回滚成功必须同时证明 ubus 可用、Nikki running、Profile 身份一致和 Mihomo 存活，不能把字节恢复冒充运行恢复；子动作失败原因必须进入脱敏回执。无法安全撤销 active 时拒绝以旧 bytes 覆盖正在运行的 artifact并精确报告 `needs_local_recovery`，且不得自行重启设备。成功前补齐的签名依赖包可以保持安装，但不能自动启用未验收的数据面。部署器不解释机场逻辑、不生成 policy、不自写 DNS/nft/路由清理；运行期 Fail-Open 仍归 activation/Nikki owner。

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
| 当前地区所有 primary 失败 | 仅在原型证明的拓扑内选择其他 primary 地区 |
| 全部 primary 失败 | 选择 reserve |
| preferred 地区链失败 | Mihomo 原生 fallback 先使用精确列出的 primary provider tier，再使用 reserve provider tier，最后使用 DIRECT；NetFleet 进程和 UI 不参与 |
| preferred 仍通过速度 URL，但 path/guard protected probe 失败 | Mihomo 按 `path_probe_id` 切换 provider；`guard_probe_id` 仍失败时进入 DIRECT；定期重排仍按自己的周期运行，不由这次业务失败创建第二轮 |
| 显式轮次全部候选失败 | 当前保护路径健康则保持实际 fallback；否则按 active guard DIRECT -> Recovery Profile -> 后端 passthrough 恢复 |
| supervisor 或 UI 失败 | 不改变当前数据面；supervisor 由 `procd` 重启，用户仍可调用关闭 owner 恢复原始配置 |
| 运行后端/Mihomo 连续失联，或 LAN TProxy/DNS 接管链失效且劫持可能残留 | supervisor 超过运行 grace 后调用 activation owner；进程/controller 故障先尝试 Recovery Profile，LAN/DNS ingress 故障直接调用所选后端 stop/cleanup；锁忙时下一轮继续尝试，supervisor 不自行清理 DNS/nft/路由 |
| disable/uninstall 原生恢复失败 | 不重新启用 NetFleet；调用所选后端 stop/cleanup。若 `safe && persistent`，关闭/卸载可以成功，即使 `business_ok` 为 `false`/`null`；否则拒绝删除并保留 artifact |

增强算法与 supervisor 不直接修改 nft、DNS、默认路由或防火墙。Nikki 模式交由官方服务清理；原生模式只清理 gateway 持有的接管对象，不修改默认路由或其他防火墙 owner。若 stop 后直连保护域名本身不可达，系统只能如实报告该物理出口限制；这不表示 cleanup 失败，也不能声称“代理耗尽后仍保证这些域名可用”。

运行期闭环由唯一 supervisor 完成：它只在 NetFleet Profile 是当前 owner 时读取所选后端 enabled、Mihomo 进程、controller、LAN TProxy ingress 和 DNS 接管状态；只有整条本地接管链健康才清零内存中的失联起点。连续失联超过 `runtime_grace_seconds` 后，在全局 mutation lock 下调用 `recover`。`recover` 对进程/controller 故障复用 activation owner 的 Recovery Profile 与后端 cleanup 合同；对所有 Profile 共享的 LAN/DNS ingress 故障直接使用后端 cleanup 进入 passthrough。锁忙或恢复失败不重置失联起点，supervisor 在下一次 readback 继续尝试，直至 owner 已恢复或 NetFleet 不再 active。如果用户已切到其他 Profile 或 NetFleet 已 disabled，则返回 unchanged。supervisor 不修改后端 respawn 参数、不捕获每个进程事件、不轮询远端业务 URL，也不保存 crash counter；DNS 查询只使用 `guard_probe_id` 已声明的保护 URL 域名验证现有本地 resolver，不承担远端 HTTP 可用性判断。进程被杀后由 `procd` 重启，数据面不依赖其存活。
