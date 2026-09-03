# 运行、激活与故障恢复

本文是 compiler、staged/active 转换、activation、supervisor 和 Fail-Open 恢复顺序的
权威合同。对象身份见[产品对象与 Owner](domain-model.md)，选择规则见
[测量、资格与选择](selection.md)。

## 唯一纵向链

```text
target-local UCI
  + PolicySource
  + Nikki subscription cache
    -> one-shot compiler
       -> staged profile + manifest
          -> enable transaction
             -> Nikki official profile switch/restart
                -> Mihomo current owner state

RecoveryProfileRef
  -> enable precondition / rollback / disable / recover
     -> Nikki official profile switch/restart
        -> Nikki official cleanup / passthrough
```

仓库只在这条链的第一个真实 caller 出现时增加相应文件。不得先建立通用 framework、第二下载器、兼容层或空 facade。

## Compiler

compiler 是无后台状态的一次性转换：

1. 读取 policy、Policy Source、Recovery Profile 身份和 Nikki 已落盘缓存；
2. 保留 Policy Source 的规则顺序和未绑定组；迁移 Profile 中已有的 DNS 逐字保留，bundle 不声明 DNS，设备 DNS 继续由 Nikki/mixin owner 提供。target-local `routing_rules` 在开头连续的管理链路直连规则之后、其他分类规则之前投影为 Mihomo 规则，目标由 capability ID 解析为可见 selector；它们只存在于生成 Profile，不进入 Nikki 全局 mixin 或 Recovery Profile。随后把每个 `entry` 的规则目标及组引用改写到 capability 可见 selector，删除旧入口及仅由该入口可达、现已 caller-zero 的旧 Auto/地区闭包；不依赖 `hidden` 维持用户界面正确性；
3. 每个 capability 生成一个由 `display_name` 命名的可见 selector，成员固定为“本能力自动选优 / 共享地区出口 / DIRECT”。根能力拥有唯一一套可见地区出口；声明 `prefer_region_from` 的跟随能力复用上游能力的地区出口，并按自身允许/排除地区过滤，不再生成只差能力前缀的重复可见地区组。跟随能力仍保留自身 automatic 候选链，以维持独立资格和自动决策。每个 `policy` 业务组保留原名并使用其绑定能力的相同成员，Policy Source 以 `DIRECT` 为首项时只调整默认顺序，不直接暴露机场叶子。这些中文模板以及“主用机场 / 备用机场 / 当前优选 / 代理路径”是当前生成 Profile 的合同，由 compiler 拥有，不是 UI i18n，也不是 policy 字段。地区名称由 policy 的 `flag + display_name` 生成，机场名称来自 Nikki subscription metadata；稳定 ID 只保留在 manifest；
4. Mihomo provider `exclude-filter` 只做通用输入卫生，正则是 compiler 常量 `PSEUDO_PROXY_FILTER`，不是 policy 字段，也不决定 automatic 资格；automatic 模式的 Provider 级 fallback 还必须使用该 Provider 全部已授权 `provider_regions` filter 的并集，未映射节点、未知地区和订阅元数据不得进入 automatic 或机场回退；
5. 校验引用完整性、循环、重复稳定身份和 `mihomo -t`；
6. 原子写入 staged JSON 与同批 manifest，建立并回读 Nikki 根目录稳定入口；入口、内部 artifact 摘要和 `mihomo -t` 必须同时一致。

provider 的唯一路径是直接引用 Nikki cache：每个 enabled provider 必须指向一个稳定命名的 Nikki subscription section，cache 路径由 section 唯一派生；compiler 先确认 section owner 和 cache 同时存在，再生成一个 `type:file` source，并在 Mihomo SAFE_PATHS 内建立指向原 cache 的受控 symlink。inactive compile 可把自己命名空间内、旧新目标都严格位于 Nikki subscription cache 的 symlink 原子改指向当前稳定 section，用于从匿名 `cfg...` 迁移；非 symlink、越界目标或其他 owner 文件必须拒绝。NetFleet 不自行下载、解析、合并或复制订阅；运行时刷新只能在同一个 one-shot mutation owner 和设备锁内逐个调用 Nikki 官方 `update_subscription`，由 Nikki 继续拥有 URL、下载、metadata、格式校验和单机场 cache 原子替换。该路径不能通过设备 gate 时，compile 直接失败，不保留第二种运行时路径。

Mihomo 只允许从 `/etc/nikki/run` 的 SAFE_PATHS 消费 `type: file` provider，因此 adapter 在该目录建立只指向 Nikki subscription cache 的 symlink；文件内容仍只有 Nikki 一份。Provider/地区候选组使用 `checks.latency` 的 Mihomo 原生 `url-test` 负责同目标 delay 和叶子切换；同地区聚合入口先在 primary Provider/地区候选中按同目标 delay 选择，再进入 reserve，最后 DIRECT。Provider tier 组使用 `path_probe_id` 的业务健康合同，不拿测速目标冒充兜底资格。automatic 模式的每个 Provider 组必须同时应用该 Provider 已生成地区组的授权 filter 并集，不能退回未过滤的机场全集；因此 preferred 与 primary/reserve tier 共享同一地区授权边界。compiler 生成 `visible capability selector -> automatic path | shared region aggregate | DIRECT`；automatic path 固定为 `当前优选 -> primary provider tier -> reserve provider tier -> DIRECT`，每个 tier 内由 Mihomo 在该层精确列出的 provider group 中选择健康路径。买断机场是否作为兜底只由其 provider `role=reserve` 表达。策略来源中的 `policy` 业务组会展开为同一 capability 的自动出口、全部合规共享地区和 DIRECT；原始组以 DIRECT 为首项时继续以直连为默认，否则以自动出口为默认，从而允许国内媒体、Steam、Xbox、PlayStation 和 Nintendo Switch 等业务在 Zashboard 临时改路但不改变其重启后的默认策略。Profile 顺序固定为 capability 出口、策略来源顺序中的 `policy` 业务组、其他保留组和 NetFleet 内部组；Mihomo 保留的 `GLOBAL` 只代表全局模式控制面，Policy Source 不得再创建大小写近似的 `Global` 业务组。内部组仍设置 hidden 供支持该字段的客户端使用，但正确拓扑和可见业务组绝不依赖 hidden。生成物不复制节点、订阅、DNS、Policy Source 或 Recovery Profile。`DIRECT` 是明确的终端数据面逃生路径。`fail_open.probes` 是 enable/select 的成功条件；DIRECT、Recovery Profile 恢复和 passthrough 只把同一结果作为独立业务证据。artifact manifest 分别保存 Policy Source 和 Recovery Profile 的 ref/digest，并保存稳定 ID、entry/policy 映射、全部显示组、精确有序的 Fail-Open stages、provider section、runtime source path 和 policy digest。

内置 bundle 的业务分类只引用同一上游 commit 的锁定 MRS，不维护第二份按域名手抄的服务清单。Mihomo 按规则数组首条命中，因此顺序固定为：Tailscale/管理链路直连、target-local `routing_rules`、私网 domain/IP、AI、Netflix、YouTube、Telegram、社交媒体、Steam/Xbox/PlayStation/Nintendo、Microsoft/Apple/Google、国内媒体、CN domain/IP、`geolocation-!cn`、`MATCH`。更具体业务必须在更宽泛的厂商、CN 或非 CN 分类之前；IP 规则使用 `no-resolve`，避免为了匹配规则额外解析。没有当前真实分类规则的“下载”等分组不得存在；需要临时改路的现有业务组统一由 compiler 展开为自动出口、共享地区出口和 DIRECT 的排列组合。

`/etc/opl-netfleet/evidence.json` 是唯一 display evidence owner，并位于 OpenWrt 持久 overlay；不得放在指向 `/tmp` 的 `/var` 下。每次成功的 enable、显式或定期 `select auto` 按 capability 覆盖保存本轮有界候选结果，并分别维护固定空间的机场和地区 delay 聚合；每个机场或地区在一轮内只记其最小有效 delay，全局机场表和地区表都只投影根 automatic capability。聚合身份只绑定实际延迟测量口径（测量模型、URL、期望状态与 timeout），不绑定完整 artifact、Policy Source 或 policy：代码、显示文案、Fail-Open、自动周期、设备重启或其他不改变延迟可比性的更新不得清空历史。机场、地区或 capability 拓扑变化时，当前轮按稳定 ID 保留仍存在对象的聚合、移除已不存在对象并从单样本建立新增对象；测量口径变化才整体重置。旧 identity 在精确匹配当前 artifact/policy 时允许一次无损升级到新口径；部署 owner 首次升级时把仍存在的旧 `/var/lib/opl-netfleet/evidence.json` 原子迁入持久 owner，成功后删除旧路径，失败回滚恢复原字节。该聚合只用于 status/LuCI 展示，selector 永远只读当前轮，不得读取平均值或历史值。evidence 缺失、损坏或写入失败必须被忽略，不能阻断 enable、select、disable 或原生恢复。LuCI 同步 mutation 与 rpcd execution timeout 使用 300 秒有界预算，覆盖启动收敛、测速、owner readback 和必要回滚；成功路径不会等待到上限。package post-install 和 deployment owner 都只在 rpcd 当前上限低于 300 秒时提升到 300，保留更高值并重启、回读 rpcd surface，deployment owner 还必须把 `/etc/config/rpcd` 原字节纳入同一部署回滚。不得通过后台 worker、第二选择器或伪造提前成功规避这个 owner 事务。

`/var/lib/opl-netfleet/events.json` 是固定上限的持久化 owner 事件，不是 operation history 或选择输入。它记录 one-shot owner 已实际完成的 enable、select、disable 和 subscription refresh；refresh 事件只保存执行时间、结果、机场总数/变化数/失败数、是否重载及调用来源，不保存 URL、token、节点、cache 内容或完整配置。写入失败不改变数据面结果。调用来源只允许 owner 已知的 `luci|cli|deployer|supervisor`，未知入口如实记录 `unknown`，不能据进程或时间猜测。Mihomo 自主 health-check/fallback 继续写 Nikki 管理的 core log，NetFleet 日志页只读展示其中与 `NETFLEET-` 相关的最近行，并明确受 Nikki 自身清理策略约束；NetFleet 不为捕捉每次叶子变化增加常驻监听器。

手动和自动模式都生成 Provider 级 URLTest 组；自动模式的 Provider 级组只包含已授权地区映射，作为数据面机场回退，另生成 Provider/地区 URLTest 候选组供一次 `select auto` 比较。编译仍只引用 Nikki cache，不复制订阅，也不允许未映射节点通过机场回退绕过 automatic 资格。

一个全局、隐藏、只含 `DIRECT` 的直连护栏组专门承接 path/guard 健康检查。保护探针的 delay 只写入该内部组历史，最终数据路径仍为 `DIRECT`，但不得污染 Mihomo 内置 `DIRECT` 在 Zashboard 中的节点延迟。用户可见策略的手工直连仍直接选择内置 `DIRECT`。

## Activation

公开 mutation 只允许 `onboarding_apply|compile|enable|disable|select|refresh`。这些动作由 `main.uc` 这一个前台进程执行；`core/activation.uc` 只提供纯函数判定。supervisor 只通过同一个锁调用内部 `maintain|refresh|recover`，不得直接写 UCI、subscription cache、selector、DNS、nft 或路由。

- onboarding preview 完全只读；apply 在同一锁内重新绑定 Nikki 当前 Profile、subscription cache
  和生成 policy revision。package 安装不触发 apply；只有用户在 LuCI 明确确认才进入事务；
- onboarding apply 使用当前原生 Profile 同时作为初始 Policy Source 和 Recovery Profile，
  因此不需要 host 生成 policy、复制订阅或下载内置 ruleset。成功前 Nikki 当前 Profile 不得变化；
- onboarding apply 失败时先使用仍在场的新 policy/manifest 调用同一 disable owner 恢复原生
  Profile，再删除本次生成的 policy/artifact/provider link，并恢复 supervisor 原状态；恢复无法
  证明时返回真实 recovery blocker，不得继续覆盖或报告完成；

- compile 仅在 NetFleet Profile 非 active 时执行；
- enable 要求 Nikki 当前 Profile 仍是 RecoveryProfileRef，且 staged 中 Policy Source、Recovery Profile、policy 和 artifact 身份均未变化；`kind=profile` 还回读原入口 selector 供事件解释，`kind=bundle` 不要求 Recovery Profile 存在同名组，失败恢复始终切回完整 Recovery Profile；
- enable 先安装完整 artifact，再调用 Nikki 官方 Profile 切换与 restart；
- enable 后先给 Nikki/Mihomo 一个有界的 owner-readiness grace，确认 capability group 已发布且包含目标成员后只写一次 selector，再等待所选 provider/地区组出现真实叶子并回读 owner 状态和所有 target-local protected probes；所有 `automatic` capability 的可见 selector 必须最终精确回读为其“自动选优”成员，实际数据路径必须是优选或自动 fallback，不能把 `manual DIRECT` 当作启用成功；两层 fallback health-check 只作 best-effort 初始化，备用分支没有在同一 timeout 返回结果、或祖先组在重启收敛期暂时报告 `alive=false`，都不能推翻已绑定真实叶子、实际链和事务探针的成功 readback；grace 内只等待启动和 provider 收敛，不重试 selector 或扩大探测轮次；超时仍恢复原 Profile；
- enable、select 或其异常处理在 active artifact 上失败时，先把全部 active capability guard 切到 DIRECT 并逐一回读，再只执行一次保护探针，随后恢复 Recovery Profile。原生 owner/runtime 恢复成功就停止 mutation，并把保护探针结果独立返回，不能因为远端业务探针失败而关闭一个健康的原生 owner；runtime 恢复失败时才调用 Nikki 官方 stop/cleanup 进入 passthrough，绝不重新启用已失败的 NetFleet Profile；
- disable 先恢复 RecoveryProfileRef 并验证原生 owner/runtime；恢复成功即完成关闭，`business_ok` 单独返回。只有原生 runtime 无法恢复时才调用 Nikki 官方 stop/cleanup；`safe && persistent` 即可完成 passthrough，两项前提任一无法证明时拒绝卸载；
- refresh 枚举 policy 中 enabled provider 的稳定 Nikki section，逐个调用 Nikki 官方 updater。每个调用前保存该 section 的 LKG cache，下载或校验失败时立即恢复该机场旧 cache 并继续其他机场；全部摘要不变时不 compile、不 restart、不触碰 selector。cache 有变化且 NetFleet active 时，owner 保存旧 artifact/manifest 和全部可见 selector，重新 compile、restart、恢复用户模式并立即执行同一个 automatic 轮次和 protected probes；任何 compile、owner readback、选择或探针失败都恢复全部更新前 cache、artifact/manifest 与 NetFleet runtime。NetFleet inactive 时只更新 Nikki cache，不擅自 restart 或接管原生数据面；
- 用户已在 Nikki 手工切到其他原始 Profile 时，NetFleet 只撤销自身 mutation 权限，不改 Nikki；
- uninstall 先执行同一 disable 合同并停止 supervisor，再通过精确 symlink target
  所有权检查删除 NetFleet 生成的 Profile、manifest 和 provider links；恢复失败或
  生成物所有权不匹配时拒绝卸载，不删除运行文件或第三方 Profile。
- supervisor 每次只做轻量 owner readback。当前可见 capability selector 选择“自动选优”时，按 `selection_interval_seconds` 调用同一个 `select auto`；任何 capability 处于手动地区或 DIRECT 时暂停这组依赖能力的定期选择。`subscription_refresh_enabled` 默认开启，按 `subscription_refresh_interval_seconds`（默认 `43200`，12 小时）调用同一个 `refresh`；锁忙时不把失败尝试当作已执行。Mihomo/controller、LAN TProxy ingress 或 DNS 接管连续失联超过 `runtime_grace_seconds` 时调用同一个 `recover`；锁忙或恢复失败不重置失联起点，下一轮继续尝试。LAN ingress 以 effective `allow_lan`、TCP/UDP `7892` wildcard listener 和 Nikki nft TProxy rule 为准；DNS 接管以 effective `dns_enabled`、TCP/UDP DNS listener、Nikki LAN DNS redirect rule，以及保护探针域名经路由器 resolver 的真实解析为准。进程/controller 失联优先恢复 Recovery Profile；LAN/DNS ingress 属于所有 Profile 共享的平台故障，切换 Recovery Profile 不能修复，因此直接调用 Nikki 官方 stop/cleanup 并持久进入 passthrough。恢复成功后 NetFleet 不再拥有数据面，失败后等待下一次 owner readback，不在同一轮反复重启。

网络 mutation 必须使用 fresh precondition digest。是否需要分离的 `plan -> apply` 公开接口由第一条真实远程 caller 决定；不得为了没有 caller 的协议预先维护 worker、Host、schema 或 operation history。

### Canonical 部署事务

开发、虚拟机资格验证和设备写入是三个独立阶段。开发 worktree 只产生经验证并吸收到远端 canonical `main` 的 source；QEMU 启动官方 OpenWrt 镜像，验证真实 BusyBox、`/var -> /tmp`、ubus/rpcd/procd、隔离安装和失败回滚后，才为该精确 commit/tree 生成一次 qualification receipt；设备部署只接受一个显式 Git ref，解析并冻结其 commit/tree，从 Git object 构建 bundle，不读取 checkout 的 dirty 或未提交字节。bundle 包含逐文件 SHA-256 和 source identity，目标端只用一次性前台进程执行，不增加 daemon、queue 或 operation history。VM receipt 只证明通用 OpenWrt 控制面和回滚合同，不证明机场、真实 DNS/TPROXY、硬件驱动或业务路径。

目标端部署 owner 使用独立短生命周期 `flock`。默认模式只允许 native/inactive target 安装并停在 staged；发现 target 正由 NetFleet 管理时不做 mutation，要求调用者明确选择后续动作。`--leave-disabled` 才授权将已有 active owner 恢复到 Recovery Profile 后安装并停在 staged；`--activate` 才授权完成 data-plane 切换，而且 host 必须验证 qualification receipt 的 `qualified=true`、source commit/tree 与本次 bundle 精确一致。receipt 缺失、过期或不匹配时在 SSH 前失败。不带 deployment bundle 时只升级已有设备安装；提供 bundle 时是完整声明式安装。deployment bundle 目录必须同时包含 `policy.json`、`subscriptions.json`、`nikki-mixin.yaml` 和 `platform.json`，缺一即在传输前失败。当前 CLI 参数名仍为 `--instance`，它只指定这个四文件 bundle，不代表 OPL Instance 的位置或配置 owner。`subscriptions.json` 只声明稳定命名 section、显示名、HTTPS URL 和可选 UA/info URL；Recovery Profile 和 provider 必须引用这些稳定 section，`kind=profile` 的 Policy Source 同样必须引用已声明 section，`kind=bundle` 则必须解析到随包安装且通过摘要校验的稳定 JSON 基线。任何对象都不能引用设备随机生成的 `cfg...` 或 UCI 数组序号。

安装器先用当前签名软件源补齐缺失的 Nikki/Mihomo/UCode/`yq` 等依赖；只安装缺失包，不执行 whole-system upgrade 或绕过签名。包管理器、架构或软件源不支持时，在数据面 mutation 前返回结构化不兼容结果。随后校验全部 bundle SHA、policy/platform schema、订阅 section 唯一性、HTTPS 来源、Policy Source、Recovery Profile 引用和 mixin YAML。公共 ruleset lock 固定上游 commit、HTTPS URL、`domain|ipcidr` MRS 格式、大小、SHA-256 与许可证；目标端在任何 device mutation 前下载到 `/tmp` staged 并逐项验真。Nikki runtime 可用时下载必须使用 controller 回读的 loopback mixed proxy 并复用其 UCI 认证，避免把路由器本机 root 流量误当成透明代理流量；没有可用 runtime 时才显式无代理直连。两条路径都不把 GPL 数据提交或打进 Apache-2.0 source/package，也不追随 mutable `latest`。下载、TLS 或身份不符时零写入失败。之后才保存 `/etc/config/nikki`、`/etc/config/firewall`、mixin、相关 subscription cache、已安装 MRS 及全部 NetFleet state 的单槽 snapshot。已有 active owner 必须先通过 status/probe再 disable；全新设备不虚构旧 owner 门禁。

原生准备阶段只由部署 owner 创建稳定 UCI section，并逐个调用 Nikki 官方 `update_subscription`；缓存下载、metadata 和格式验证仍由 Nikki 负责，NetFleet runtime 从不下载订阅或更新规则集。payload 必须先解压到 `/tmp` 隔离目录，只能从该目录逐项复制 owner 白名单，任何 tar 都不得直接解压到 `/`。随后原子安装 payload、mixin、`platform.json` 映射的 UCI 和 `0600` policy；锁定 MRS 必须原子安装到 Mihomo home 内的专用 `/etc/nikki/run/rulesets` 目录，使 Nikki 启动前校验、procd runtime、LuCI restart 和系统启动共享同一读取边界。平台值固定为 TCP/UDP TProxy、TUN off、redir-host、fake-IP cache off、LAN 可达 controller、API secret required、LAN listener enabled、sniffer 不改写目标、软/硬 flow offload off，其他值仍由显式 platform 字段决定。controller 监听 IPv4 任意地址以兼容 Nikki 官方 Dashboard 从当前 LuCI 主机名直连 `/ui/` 的实现；`allow_lan` 必须开启，否则 Mihomo 会把 TProxy listener 绑定到 loopback，nft 虽能标记 LAN 包却无法把公网目标包交给 `7892`。OpenWrt LAN zone 允许访问，WAN zone 必须拒绝输入；controller 由 API secret 保护，显式代理认证继续由 target-local Nikki 配置负责。Nikki 继续从 UCI 生成 effective Profile、nft 与策略路由，部署器不手写这些运行面。发生原生输入变化时，完成 Recovery Profile owner/protected-probe readback 后执行 `compile -> staged readback`；只有 qualified `--activate` 才继续 `enable -> owner/status/probe/parity readback`。RPC loader 不属于数据面 owner：readiness 必须同时验证本机 ubus、`luci` 与 `opl-netfleet` 完整方法表，以及使用临时最小权限 session 调用 `luci.getFeatures` 的 HTTP `/ubus` bridge。只有本机 surface 缺失或 timeout 不合格时才允许一次官方 `rpcd restart`；本机 surface 正常而 HTTP bridge 失效时只允许一次 `uhttpd restart`，随后重新验证 HTTP RPC，且两者都不得触碰 Nikki/NetFleet 数据面。snapshot 恢复触发 rpcd reload 后也必须 best-effort 恢复 uhttpd bridge。同一 source/instance/active 身份重放不得刷新订阅或重启数据面。仅 LuCI owner 字节变化时，显式 `--presentation-only` 不要求新的 QEMU receipt；但 bundle 的非 LuCI runtime 摘要、target installed identity、实际 runtime 文件、policy、订阅、mixin、platform、MRS 与 rpcd timeout 必须全部匹配，且 active owner/status/probe 已通过，部署器才可短暂停止 supervisor 并在不 disable/compile/enable 数据面的情况下替换 owner payload。任一前提不满足必须在 snapshot 和 owner 字节写入前拒绝，不能自动降级为普通激活；完成后仍须 validate、status、probe 和 installed parity，失败按原 control-plane snapshot 恢复。

订阅、mixin、Policy Source、Recovery Profile 或 NetFleet 任一步失败，部署器先撤销新 active，再从隔离目录逐项恢复 snapshot 中的 Nikki 配置、mixin、cache、原 Profile 和 NetFleet 字节；原设备没有 Profile 时回到 Nikki 官方 stop/passthrough。原 Profile 的回滚成功必须同时证明 ubus 可用、Nikki running、Profile 身份一致和 Mihomo 存活，不能把字节恢复冒充运行恢复；子动作失败原因必须进入脱敏回执。无法安全撤销 active 时拒绝以旧 bytes 覆盖正在运行的 artifact并精确报告 `needs_local_recovery`，且不得自行重启设备。成功前补齐的签名依赖包可以保持安装，但不能自动启用未验收的数据面。部署器不解释机场逻辑、不生成 policy、不自写 DNS/nft/路由清理；运行期 Fail-Open 仍归 activation/Nikki owner。

## Fail-Open

Fail-Open 的终点是数据面可脱离代理，而不是“所有业务探针都必须成功”。active guard、原生恢复和 passthrough 都把数据面/readback 与 `business_ok` 分开：`DIRECT` guard 以 selector/runtime readback 为安全条件；原生恢复以 `runtime_ok` 为安全条件；passthrough 以 `safe && persistent` 为安全条件。`safe` 表示 Nikki 官方 cleanup 已清除 Mihomo、DNS、nft、策略路由和 dummy 设备；`persistent` 表示下次 Nikki 启动不会再次选择失败的 NetFleet artifact；`business_ok` 表示保护探针结果，可为 `true`、`false` 或 `null`（未执行/无法判定）。远端业务失败不能推翻已经成立的数据面安全终点，也不得触发重启、重新启用或伪造业务成功。

数据面退路顺序固定为：

```text
preferred -> primary provider tier -> reserve provider tier -> DIRECT
```

Mihomo 仍运行时，代理组自行沿该链路选择，`DIRECT` 是明确的终端出口。内层 path probe 失败后先在全部主用机场中按同一健康目标选择，主用层全部失效后进入备用机场；外层 guard probe 失败后进入 DIRECT。两层都由 Mihomo 按 policy 的 interval 和失败次数运行。NetFleet supervisor 只调度跨地区轮次和进程失联 grace，不轮询业务 URL，也不介入 Mihomo 数据面 fallback。Fallback 不会重放已经失败的同一个连接：故障瞬间允许一个请求失败，后续连接才使用新的成员。Recovery Profile 不在 active Profile 内复制；它只在事务失败、disable、supervisor recovery 或用户从 Nikki 手工切回时恢复整个 owner。Mihomo/Nikki 本身异常，或事务回退无法证明 Recovery Profile 可用时，NetFleet 只调用 Nikki 官方 `stop`/cleanup 进入 passthrough；NetFleet 不自行删除 DNS、nft、路由或进程。业务探针结果不是 cleanup 或持久化的门槛，也不允许伪造成功。

| 故障 | Owner 动作 |
| --- | --- |
| 安装/compile/staged 校验失败或 WAN 上游不可用 | Nikki 当前 Profile、DNS、nft、路由和服务完全不变 |
| enable、owner readback 或 protected probe 失败 | active guard 先切 DIRECT 建立即时安全护栏，再恢复 Recovery Profile owner/runtime；runtime 失败才调用 Nikki 官方 stop/cleanup。保护探针失败单独报告，绝不重新启用失败的 NetFleet Profile |
| 手动 select 后 protected probe 失败 | 恢复原 selector；selector 回退失败则先切 active guard 到 DIRECT，再恢复 Recovery Profile，原生 runtime 失败才进入 Nikki 官方 passthrough |
| 单节点或同地区单 provider 失败 | connection refused 立即、其他错误按 `max_failed_times`/timeout 窗口触发原生 health-check；当前叶子失活后下一次选路换叶子，健康叶子只有替代项严格快超过 `leaf_switch_margin_ms` 才换 |
| 当前地区仍可用但替代地区 proxy-path delay 优势小于 `selection.region_switch_margin_ms`（默认 150） | 保持当前地区 |
| 当前地区无合格叶子，或替代地区 proxy-path delay 至少快该门槛 | 选择最快合格地区 |
| Provider 明确 quota exhausted | 下一次 enable、显式或定期 automatic 轮次中排除；不建立独立 quota 轮询。若耗尽造成当前优选链实际失败，Mihomo fallback 先用其余合格 primary，全部失败后才进入 reserve，最后进入 DIRECT |
| 当前地区所有 primary 失败 | 仅在原型证明的拓扑内选择其他 primary 地区 |
| 全部 primary 失败 | 选择 reserve |
| preferred 地区链失败 | Mihomo 原生 fallback 先使用精确列出的 primary provider tier，再使用 reserve provider tier，最后使用 DIRECT；NetFleet 进程和 UI 不参与 |
| preferred 仍通过速度 URL，但 path/guard protected probe 失败 | Mihomo 按 `path_probe_id` 切换 provider；`guard_probe_id` 仍失败时进入 DIRECT；定期重排仍按自己的周期运行，不由这次业务失败创建第二轮 |
| 显式轮次全部候选失败 | 当前保护路径健康则保持实际 fallback；否则按 active guard DIRECT -> Recovery Profile -> Nikki 官方 passthrough 恢复 |
| supervisor 或 UI 失败 | 不改变当前数据面；supervisor 由 `procd` 重启，用户仍可从 Nikki 切回原始 Profile |
| Nikki/Mihomo 连续失联，或 LAN TProxy/DNS 接管链失效且劫持可能残留 | supervisor 超过运行 grace 后调用 activation owner；进程/controller 故障先尝试 Recovery Profile，LAN/DNS ingress 故障直接调用 Nikki 官方 stop/cleanup；锁忙时下一轮继续尝试，NetFleet 不自写 DNS/nft/路由清理 |
| disable/uninstall 原生恢复失败 | 不重新启用 NetFleet；调用 Nikki 官方 stop/cleanup。若 `safe && persistent`，关闭/卸载可以成功，即使 `business_ok` 为 `false`/`null`；否则拒绝删除并保留 artifact |

NetFleet 不直接修改 nft、DNS、默认路由或防火墙。若 stop 后直连保护域名本身不可达，系统只能如实报告该物理出口限制；这不表示 cleanup 失败，也不能声称“代理耗尽后仍保证这些域名可用”。

运行期闭环由唯一 supervisor 完成：它只在 NetFleet Profile 是当前 owner 时读取 Nikki enabled、Mihomo 进程、controller、LAN TProxy ingress 和 DNS 接管状态；只有整条本地接管链健康才清零内存中的失联起点。连续失联超过 `runtime_grace_seconds` 后，在全局 mutation lock 下调用 `recover`。`recover` 对进程/controller 故障复用 activation owner 的 Recovery Profile 与官方 cleanup 合同；对所有 Profile 共享的 LAN/DNS ingress 故障直接使用官方 cleanup 进入 passthrough。锁忙或恢复失败不重置失联起点，supervisor 在下一次 readback 继续尝试，直至 owner 已恢复或 NetFleet 不再 active。如果用户已切到其他 Profile 或 NetFleet 已 disabled，则返回 unchanged。supervisor 不修改 Nikki respawn 参数、不捕获每个进程事件、不轮询远端业务 URL，也不保存 crash counter；DNS 查询只使用 `guard_probe_id` 已声明的保护 URL 域名验证现有本地 resolver，不承担远端 HTTP 可用性判断。进程被杀后由 `procd` 重启，数据面不依赖其存活。
