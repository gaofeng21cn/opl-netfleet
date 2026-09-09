# Fleet 部署事务

本节描述现有面向 Nikki 的 Fleet deployment bundle 安装入口；原生首次设置与后端迁移
使用[运行文档的设备端事务](../architecture/runtime-and-recovery.md#首次设置与迁移)，不能把该四文件 bundle 或 host 部署器作为原生独立安装的前置条件。

## 按设备当前状态选择入口

| 当前状态与目的 | 使用入口 |
| --- | --- |
| 空白设备安装并接入原生 Mihomo | 签名安装器安装产品，再由 LuCI 首次接入事务建立订阅、配置与网络 owner |
| 已使用任一受支持后端，日常更新 NetFleet | LuCI“插件与更新”的设备端签名包事务，保留后端选择和私有输入 |
| 已运行 Nikki，迁移到原生后端 | LuCI“配置 → 基础接入”的显式迁移事务 |
| 按 private Instance 复现 Nikki 环境 | 本文 Fleet 入口，消费生成的四文件 deployment bundle |

软件包身份、候选与旧包获取、失败回滚及中断边界统一见
[设备端组件维护](../architecture/packaging.md#设备端组件维护)。已经运行原生后端的设备
不通过应用 Nikki bundle 或启动 Nikki 完成更新。部署前必须读取所选后端、已安装代码
身份、当前操作和运行状态；请求超时后先回读操作结果与 owner，再决定是否继续。

## 候选与输入

开发、虚拟机资格验证和设备写入是三个独立阶段。开发 worktree 只产生经验证并吸收到远端 canonical `main` 的 source；QEMU 启动官方 OpenWrt 镜像，验证真实 BusyBox、`/var -> /tmp`、ubus/rpcd/procd、隔离安装和失败回滚后，才为该精确 commit/tree 生成一次 qualification receipt；设备部署只接受一个显式 Git ref，解析并冻结其 commit/tree，从 Git object 构建 bundle，不读取 checkout 的 dirty 或未提交字节。bundle 包含逐文件 SHA-256 和 source identity，目标端只用一次性前台进程执行，不增加 daemon、queue 或 operation history。VM receipt 只证明通用 OpenWrt 控制面和回滚合同，不证明机场、真实 DNS/TPROXY、硬件驱动或业务路径。

目标端部署 owner 使用独立短生命周期 `flock`。默认模式只允许 native/inactive target 安装并停在 staged；发现 target 正由 NetFleet 管理时不做 mutation，要求调用者明确选择后续动作。`--leave-disabled` 才授权将已有 active owner 恢复到 Recovery Profile 后安装并停在 staged；`--activate` 才授权完成 data-plane 切换，而且 host 必须验证 qualification receipt 的 `qualified=true`、source commit/tree 与本次 bundle 精确一致。receipt 缺失、过期或不匹配时在 SSH 前失败。不带 deployment bundle 时只升级已有设备安装；提供 bundle 时是完整声明式安装。deployment bundle 目录必须同时包含 `policy.json`、`subscriptions.json`、`nikki-mixin.yaml` 和 `platform.json`，缺一即在传输前失败。当前 CLI 参数名仍为 `--instance`，它只指定这个四文件 bundle，不代表 OPL Instance 的位置或配置 owner。`subscriptions.json` 只声明稳定命名 section、显示名、HTTPS URL 和可选 UA/info URL；Recovery Profile 和 provider 必须引用这些稳定 section，`kind=profile` 的 Policy Source 同样必须引用已声明 section，`kind=bundle` 则必须解析到随包安装且通过摘要校验的稳定 JSON 基线。任何对象都不能引用设备随机生成的 `cfg...` 或 UCI 数组序号。

## 校验与快照

安装器先用当前签名软件源补齐缺失的 Nikki/Mihomo/UCode/`yq` 等依赖；只安装缺失包，不执行 whole-system upgrade 或绕过签名。包管理器、架构或软件源不支持时，在数据面 mutation 前返回结构化不兼容结果。随后校验全部 bundle SHA、policy/platform schema、订阅 section 唯一性、HTTPS 来源、Policy Source、Recovery Profile 引用和 mixin YAML。公共 ruleset lock 固定上游 commit、HTTPS URL、`domain|ipcidr` MRS 格式、大小、SHA-256 与许可证；目标端在任何 device mutation 前下载到 `/tmp` staged 并逐项验真。Nikki runtime 可用时下载必须使用 controller 回读的 loopback mixed proxy 并复用其 UCI 认证，避免把路由器本机 root 流量误当成透明代理流量；没有可用 runtime 时才显式无代理直连。两条路径都不把下载的 MRS 数据提交或打进 source/package，也不追随 mutable `latest`。下载、TLS 或身份不符时零写入失败。之后才保存 `/etc/config/nikki`、`/etc/config/firewall`、mixin、相关 subscription cache、已安装 MRS 及全部 NetFleet state 的单槽 snapshot。已有 active owner 必须先通过 status/probe再 disable；全新设备不虚构旧 owner 门禁。

## 安装与应用

该 Nikki 部署入口的原生配置准备阶段由部署 owner 创建稳定 UCI section，并逐个调用 Nikki 官方 `update_subscription`；缓存下载、metadata 和格式验证仍由 Nikki 负责，Nikki 模式的增强 runtime 不另行下载订阅或更新规则集。payload 必须先解压到 `/tmp` 隔离目录，只能从该目录逐项复制 owner 白名单，任何 tar 都不得直接解压到 `/`。随后原子安装 payload、mixin、`platform.json` 映射的 UCI 和 `0600` policy；锁定 MRS 必须原子安装到 Mihomo home 内的专用 `/etc/nikki/run/rulesets` 目录，使 Nikki 启动前校验、procd runtime、LuCI restart 和系统启动共享同一读取边界。平台值固定为 TCP/UDP TProxy、TUN off、redir-host、fake-IP cache off、LAN 可达 controller、API secret required、LAN listener enabled、sniffer 不改写目标、软/硬 flow offload off，其他值仍由显式 platform 字段决定。controller 监听 IPv4 任意地址以兼容 Nikki 官方 Dashboard 从当前 LuCI 主机名直连 `/ui/` 的实现；`allow_lan` 必须开启，否则 Mihomo 会把 TProxy listener 绑定到 loopback，nft 虽能标记 LAN 包却无法把公网目标包交给 `7892`。OpenWrt LAN zone 允许访问，WAN zone 必须拒绝输入；controller 由 API secret 保护，显式代理认证继续由 target-local Nikki 配置负责。Nikki 继续从 UCI 生成 effective Profile、nft 与策略路由，部署器不手写这些运行面。发生原生输入变化时，完成 Recovery Profile owner/protected-probe readback 后执行 `compile -> staged readback`；只有 qualified `--activate` 才继续 `enable -> owner/status/probe/parity readback`。RPC loader 不属于数据面 owner：readiness 必须同时验证本机 ubus、`luci` 与 `opl-netfleet` 完整方法表，以及使用临时最小权限 session 调用 `luci.getFeatures` 的 HTTP `/ubus` bridge。只有本机 surface 缺失或 timeout 不合格时才允许一次官方 `rpcd restart`；本机 surface 正常而 HTTP bridge 失效时只允许一次 `uhttpd restart`，随后重新验证 HTTP RPC，且两者都不得触碰 Nikki/NetFleet 数据面。snapshot 恢复触发 rpcd reload 后也必须 best-effort 恢复 uhttpd bridge。同一 source/instance/active 身份重放不得刷新订阅或重启数据面。仅 LuCI owner 字节变化时，显式 `--presentation-only` 不要求新的 QEMU receipt；但 bundle 的非 LuCI runtime 摘要、target installed identity、实际 runtime 文件、policy、订阅、mixin、platform、MRS 与 rpcd timeout 必须全部匹配，且 active owner/status/probe 已通过，部署器才可短暂停止 supervisor 并在不 disable/compile/enable 数据面的情况下替换 owner payload。任一前提不满足必须在 snapshot 和 owner 字节写入前拒绝，不能自动降级为普通激活；完成后仍须 validate、status、probe 和 installed parity，失败按原 control-plane snapshot 恢复。

## 失败恢复

订阅、mixin、Policy Source、Recovery Profile 或 NetFleet 任一步失败，部署器先撤销新 active，再从隔离目录逐项恢复 snapshot 中的 Nikki 配置、mixin、cache、原 Profile 和 NetFleet 字节；原设备没有 Profile 时回到 Nikki 官方 stop/passthrough。原 Profile 的回滚成功必须同时证明 ubus 可用、Nikki running、Profile 身份一致和 Mihomo 存活，不能把字节恢复冒充运行恢复；子动作失败原因必须进入脱敏回执。无法安全撤销 active 时拒绝以旧 bytes 覆盖正在运行的 artifact并精确报告 `needs_local_recovery`，且不得自行重启设备。成功前补齐的签名依赖包可以保持安装，但不能自动启用未验收的数据面。部署器不解释机场逻辑、不生成 policy、不自写 DNS/nft/路由清理；运行期 Fail-Open 仍归 activation/Nikki owner。
