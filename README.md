# OPL NetFleet

NetFleet 是 OpenWrt + Nikki + Mihomo 的可选增强层。当前产品边界和架构导航见[当前架构](docs/architecture/overview.md)。

## 当前状态

当前仓库提供最小 UCode runtime、OpenWrt package source、脱敏 policy 示例、薄 rpcd 适配器、本机 React 参考开发面、设备端原生 LuCI 页面，以及一个由 `procd` 监督的前台 supervisor；没有 worker、第二选择器、后台投影、CLI facade 或 Host。运行期 supervisor 不只看进程：它同时回读 controller、LAN TProxy listener/nft 和 DNS listener/redirect/真实解析，连续失联超过运行保护窗口后通过同一个 owner 恢复；启动事务使用独立且更长的收敛等待。锁被部署占用时不丢失故障起点，下一轮继续恢复。

当前 package 不内置 Zashboard，也没有把 Mihomo controller 通过 LuCI 登录态代理给浏览器；现有 `connections` 只是事件与诊断页的有限只读投影。Zashboard 作为高级实时观察面的长期定位见[设计白皮书](docs/product/whitepaper.md)，在同源 ACL、只读 mutation 边界和秘密保护实现前不作为当前功能宣传。

旧控制面已经退出 source。当前 MVP 已包含多 provider file-provider、伪节点过滤、Mihomo URLTest、protected-probe Fail-Open，以及配置驱动的多 capability 自动选择。Schema v2 将正常编译输入 `policy_source` 与退出/故障恢复目标 `recovery_profile` 分开；`policy_source` 优先使用随包安装的机场无关 `bundle:base-v1`，迁移期也支持只读 Nikki Profile。两种输入共用一个 compiler、manifest、activation 和 status 路径，`recovery_profile` 始终是独立的原生恢复 owner。`standard` 可作为唯一根 automatic capability；`ai-compatible` 可通过 `prefer_region_from` 自动跟随海外加速，同时用 `excluded_regions` 排除香港。跟随能力保留独立自动选优链，但手工地区选择复用根能力的同名地区出口，不再生成重复的 AI 前缀地区组。每个启用 capability 恰有一个 `entry` binding；需要保留名称的业务组由实例显式声明为 `policy` binding，compiler 将其标准化为同一套“自动选优 / 共享地区出口 / DIRECT”，不按名称猜测，也不暴露 Policy Source 的原始机场叶子。运行期机场顺序只由 provider `primary|reserve` role 决定，固定为当前优选、主用机场层、备用机场层、DIRECT。生成 Profile 不复制原组作为 native fallback，完整事务恢复只使用 Recovery Profile。

因此：

- 没有 target-local `/etc/opl-netfleet/policy.json` 时，LuCI 只执行首次设置预检，不启动 NetFleet runtime；
- 不要把历史 task branch 当作当前产品；
- `compile` 不切换 Nikki Profile，只有用户确认 `enable` 才会产生 data-plane mutation；
- replica 只能复制已在 canary 证明的 canonical package、policy、artifact 和动作合同；每台设备的当前 effective/runtime 状态仍须分别从 target-local owner surface 回读。

## 独立安装

普通 OpenWrt 用户不需要开发机生成 deployment bundle。前提是目标设备已经安装并配置好
Nikki/Mihomo，已在 Nikki 中选择一个可用的原生 Profile，并且至少一个稳定命名的机场订阅
已有有效本地缓存。安装同一 Release 中的 `opl-netfleet` 和 `luci-app-netfleet` 两个 package
后，打开 LuCI 的“服务 -> NetFleet”：

1. 页面只读发现当前原生 Profile、机场缓存、真实地区和 `MATCH` 主入口组；
2. 预检会明确列出无法接管的原因，package 安装本身不修改网络；
3. 用户确认“按推荐配置开始接管”后，设备端一次完成 policy 生成、compile、enable、
   supervisor enable/start 和 owner readback；
4. 任一步失败会恢复原生 Profile 和原 supervisor 状态，并删除本次生成的 policy/artifact。

首次设置不会读取或返回订阅 URL/token，不复制节点，不下载第二份订阅，也不会把买断属性、
命名或列表顺序猜成备用机场。所有识别到的机场默认进入主用层；接管后可在配置页显式调整
机场角色、地区范围、自动周期和保护探针。

## Fleet 声明式部署

### 版本化发布包与 deployment bundle

NetFleet 的代码分发和 target deployment bundle 分开维护。版本化发布包只包含
UCode runtime、rpcd、supervisor、init 脚本和原生 LuCI 页面；它不包含
`policy.json`、`subscriptions.json`、`nikki-mixin.yaml`、`platform.json`、订阅 URL/token、
节点或任何目标设备秘密。官方 OpenWrt SDK 解压后只需生成目标构建配置；原生 LuCI
静态文件由标准 OpenWrt `package.mk` 显式安装，不下载或扫描 feeds。再使用打包入口
构建两个 package 及其带 source commit/tree、目标架构和 SHA-256 的
manifest；没有 SDK 时脚本会失败，不会生成伪包。25.12/APK SDK 必须提供本机
APK 私钥，构建器会启用逐包签名并只把公钥放入发布目录；私钥不会进入输出：

```bash
scripts/prepare-openwrt-sdk.sh --sdk /path/to/openwrt-sdk
scripts/netfleet-package-build.sh --sdk /path/to/openwrt-sdk \
  --ref origin/main --apk-private-key /private/path/netfleet-apk-private.pem \
  --output /private/path/netfleet-packages
```

包更新只更新代码载体，不自动编译、启用或替换当前数据面，也不得覆盖设备私有策略、
订阅缓存或生成 Profile。独立安装模式的初始 policy 由目标设备首次设置生成；只有 Fleet、
多设备精确复现或预先声明平台参数时，才需要下面的 deployment bundle。

### 后续升级：直接覆盖或 APK feed

安装后的升级不再需要开发机生成 deployment bundle。一次性升级可在设备上把新
Release 的两个 APK 作为一次事务覆盖安装：

```sh
apk add --upgrade ./opl-netfleet-0.3.1-r1.apk ./luci-app-netfleet-0.3.1-r1.apk
```

APK Release 同时提供签名的 `packages.adb`。将稳定的 latest feed 写入设备一次后，
后续由 OpenWrt 内置 `apk`/LuCI 软件包管理器检查和升级：

```sh
mkdir -p /etc/apk/keys /etc/apk/repositories.d
wget -O /etc/apk/keys/opl-netfleet-apk.pem \
  https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/opl-netfleet-apk.pem
printf '%s\n' \
  https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/packages.adb \
  >/etc/apk/repositories.d/opl-netfleet.list
apk update
apk policy opl-netfleet luci-app-netfleet
apk upgrade
```

feed 只负责代码包来源，不会刷新 Nikki 订阅、切换 Profile、重编译策略或改变当前
数据面；升级后的 post-install 只刷新 LuCI/rpcd。默认不启用无人值守 `apk upgrade`：
先检查更新、再由用户确认，是当前最小且可回滚的运维路径。若升级失败，可重新安装
上一版本 APK；无人值守更新需另行增加版本回滚和 canary 合同。

private OPL Instance 是 owner-specific desired configuration 的唯一权威；本机
deployment bundle 只是 renderer 生成、供部署器消费的四个最终输入，不是 Instance、
SSOT 或手工编辑位置。共享声明与每个目标的网络、上游 DNS 等 target-local overlay
在私有边界内合并；
秘密只存在于本机私有目录。Nikki 仍是订阅下载、缓存、解析和 metadata 的唯一 owner。

开发 worktree 不直接写设备。首次安装和后续声明式更新使用同一个 host-side 入口。
已构建的版本化发布目录可直接作为代码来源，避免每次从 Git 重新打包：

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref origin/main \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

也可以让入口从当前仓库的 GitHub Release 下载一次并缓存到本机，再复用到多个目标：

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref v0.3.0 --release v0.3.0 \
  --instance /private/path/deployment-bundle
```

`--packages` 与 `--release` 互斥；发布目录必须包含 manifest、两个同一架构的
`.apk`/`.ipk` 和 `FILES.sha256`。入口会校验 source commit/tree、包摘要、运行时
摘要和 APK 公钥；APK 目标还会回读 `apk --print-arch`，架构不匹配时在触碰 Nikki
数据面前拒绝。发布包路径只传两个包、manifest、公钥和 deployment bundle，不再传重复的
runtime tar；旧的 Git bundle 路径继续作为兼容回退。

部署器会在 stderr 输出 `prepare_elapsed_ms`、
`transfer_and_target_elapsed_ms` 和 `total_elapsed_ms`，用于比较不同目标的真实
更新耗时。目标端将两个 NetFleet package 合并为一次 `apk/opkg` 事务，避免重复进程、
锁和依赖解析；同一版本重放在身份和文件校验通过后直接返回 `already_installed`。

仓库提供手动触发的 `.github/workflows/netfleet-release.yml`。触发时必须显式
提供已校验的 OpenWrt SDK URL/SHA-256；25.12/APK 构建还需要仓库 secret
`NETFLEET_APK_PRIVATE_KEY`。workflow 只构建并上传短期保留的签名候选，不创建
Release，也不会部署设备。候选通过同一 commit/tree 的 ARM64 OpenWrt VM 安装、接管、
恢复和卸载验证后，才允许由发布入口创建不可变 Release；发布后还会重新下载公开资产，
核对文件集合、摘要和 manifest source commit/tree。Release 资产的 `manifest.json` 是
部署器选择和校验代码包的唯一入口；同一 Release 只对应一个目标架构，其他架构使用
独立 tag/Release，避免把不同设备包混在同一缓存目录。

下面的 host-side 入口只用于 Fleet、精确复现或预先声明平台参数，因此始终接受一个由
private OPL Instance 生成的完整 deployment bundle。普通独立首次安装不调用该入口，
也不需要 bundle。`--instance` 是既有 CLI 参数名，只指定该 bundle，不定义 OPL Instance
的位置：

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref origin/main --instance /private/path/deployment-bundle
scripts/deploy-openwrt.sh <ssh-target> --ref origin/main --instance /private/path/deployment-bundle --activate
scripts/deploy-openwrt.sh <ssh-target> --ref origin/main --instance /private/path/deployment-bundle --presentation-only
```

deployment bundle 应放在持久且不受 Git 管理的生成目录，例如
`~/.config/opl-netfleet/deployment-bundles/example-target`，不能把 `/tmp` 或 `/private/tmp` 当作唯一来源，
也不能在该目录反向维护 desired configuration。
`--activate` 会按精确 commit/tree 在 `$XDG_CACHE_HOME/opl-netfleet/vm-qualifications/`
（未设置时为 `~/.cache/opl-netfleet/vm-qualifications/`）
复用已通过的 QEMU receipt；缓存不存在或不匹配时，入口先自动运行同一个
`openwrt-vm.sh`，通过后才连接设备。策略只变化而 source 未变化时不再重复运行数分钟的
QEMU 资格验证。需要审计或外部保存 receipt 时仍可显式传入
`--qualification /private/path/receipt.json`。入口在联系设备前只输出 Policy Source、Recovery Profile、provider
role 和 capability ID 的脱敏摘要，不输出订阅 URL、token 或节点。

deployment bundle 目录固定包含四项，不接受部署时临时拼参数：

- `policy.json`：NetFleet capability/provider/region/binding 与 Fail-Open 配置；
- `subscriptions.json`：私有订阅凭据及稳定命名 section，格式为 `{"schema_version":1,"subscriptions":[{"section":"provider_id","name":"显示名","url":"https://...","user_agent":"mihomo"}]}`；
- `nikki-mixin.yaml`：由用户维护的原生 Nikki mixin，包括目标网络所需 DNS 兼容和关键域名规则。
- `platform.json`：目标 Nikki/OpenWrt 平台声明；API secret 只要求设备已有，不写入该文件。锁定 MRS 安装到 Mihomo home 内的专用目录，保证 Nikki 启动前校验、procd runtime 和手工 restart 使用同一文件边界。

“全新兼容 OpenWrt”不要求预装 NetFleet、Nikki、订阅或 cache。安装器先确认 root、OpenWrt 身份、默认路由和包管理器；通用依赖只从 OpenWrt 官方签名源安装。APK 目标缺少 Nikki/Mihomo 时，安装器根据固件版本和 `DISTRIB_ARCH` 注册 Nikki 官方签名 feed，校验固定公钥后再安装；不执行系统升级、不使用 `--allow-untrusted`。若固件版本、架构或签名软件源不受支持，则在触碰 Nikki 数据面前返回 `unsupported_target`/`dependency_bootstrap_failed`；不能诚实地把任意 OpenWrt 版本和架构都宣称为兼容。

入口 fresh fetch `origin/main`（发布模式用 `--ref` 绑定 release manifest），冻结精确 commit/tree，只从 Git object 或已校验 package 构建代码输入，并把四份私有输入及公共 ruleset lock 的 SHA-256 绑定到同一安装身份。锁文件引用固定上游 commit 的 20 个本地 MRS file-provider；目标先在 `/tmp` 下载并核对大小/摘要，失败时不写设备。已有 Nikki runtime 可用时下载复用 controller 回读的 loopback mixed proxy 和 UCI 认证，否则显式无代理直连；两条路径都严格校验 TLS。MRS 二进制不进入 Git 或发布包，也不使用 Mihomo 自动更新。默认部署只允许 native/inactive target，目标端用一次性 `flock` 执行兼容性与完整性预检、单槽 snapshot、隔离安装、Recovery Profile readback 和 `compile -> staged readback`；active target 默认无 mutation 返回。`--leave-disabled` 明确授权先恢复 Recovery Profile 再 staged；只有 `--activate` 搭配同 commit/tree 的 QEMU qualification receipt，才继续 `enable -> owner/status/probe/parity readback`。发布包模式由 OpenWrt `apk/opkg` 安装代码，包安装不会自动启停服务；启用、状态回读和回滚仍由同一部署事务 owner 控制。LuCI 同步 mutation 与 rpcd execution timeout 使用 300 秒有界预算，覆盖启动收敛、测速、owner readback 和必要回滚；成功路径不会等待到上限。package post-install 和部署器都仅在 rpcd 当前 execution timeout 更低时提升到 300 秒并保留更高值，部署器还把 `/etc/config/rpcd` 纳入同一 snapshot/rollback；控制面需要 restart 后必须回读 ubus、完整方法表和 LuCI HTTP `/ubus`。已有完整本机 RPC surface、HTTP bridge 且 timeout 已满足时不重载任何服务；只有 HTTP bridge 失效时只重启 `uhttpd`，不触碰 Nikki/NetFleet 数据面。inactive compile 会把 NetFleet 自有 symlink 从旧匿名 cache 安全改指向声明的稳定 section，不要求人工清理设备；非 symlink和越界目标仍拒绝。匿名 `cfg...`/`@subscription[n]` 不再是跨设备合同；不同目标只通过相同稳定 section 复用同一 policy 模型。`--dry-run` 只构建校验 bundle。

同一代码和 deployment bundle 重放不会刷新订阅、重启 Nikki 或切换数据面。仅原生 LuCI 页面变化时使用显式 `--presentation-only`：它不运行 QEMU，但要求运行时 payload、实际 runtime 文件、policy、订阅、mixin、platform、MRS、rpcd timeout 和 active owner 健康状态全部一致；policy 与 mixin 按解析后的 JSON/YAML 结构比较，允许不改变语义的格式和键顺序差异。通过后只短暂停止 supervisor 并替换相同 runtime 加 LuCI owner 字节，完成 validate、status、probe 和 installed parity 回读；不执行 disable、compile、enable 或 Nikki restart。任一实际配置、身份或健康条件不满足均在 owner 字节写入前拒绝，不自动降级为普通事务。payload 与 snapshot 都先进入 `/tmp` 隔离目录，再按 owner 白名单逐项安装或恢复；tar 永远不直接解压到 `/`。依赖安装失败不写 Nikki；订阅、mixin、platform、MRS、Policy Source、Recovery Profile 或 NetFleet 任一步失败，部署器撤销新 active 并恢复安装前 `/etc/config/nikki`、`/etc/config/firewall`、mixin、相关 cache、MRS、Profile 和 NetFleet 字节。全新设备回到 Nikki 官方 stop/passthrough；已有设备只有在 ubus、Nikki、原 Profile 和 Mihomo 均回读正常时才报告恢复成功。为后续重试而安装的签名软件包可以保留，但不能自动启用一个未通过验收的 Nikki/NetFleet 数据面。部署器不会重启、关机、刷机或调用系统升级；软件恢复无法证明管理面时返回 `needs_local_recovery`。deployment bundle 只存在于本机生成目录、传输临时目录和目标 Nikki 私有 state，不进入 Git 或回执。

若 Nikki 留有未被 deployment bundle 声明、未被引用、从未成功且没有 cache 的初始 `subscription/default/clash` 占位，部署器只删除该精确 UCI section，不重启 Nikki；其他用户订阅不在清理范围。

QEMU qualification 只支持 Apple Silicon macOS，开发机先通过 `brew install qemu` 安装原生 QEMU，再由 `qemu-system-aarch64 -accel hvf` 使用 Hypervisor.framework 启动官方 OpenWrt `armsr/armv8` EFI 镜像和 ARM64 Mihomo/yq。它验证 BusyBox、`/var -> /tmp`、ubus/rpcd/procd、失败回滚及失败后 SSH 可管理性，并输出绑定 source commit/tree、runner/guest 架构、QEMU 版本、accelerator 和阶段耗时的无秘密 JSON receipt；不再构建 Docker runner，也没有 TCG 回退。已校验的显式 receipt 会原子保存到标准 exact commit/tree cache，后续相同 source 直接复用。它不连接真实设备、不使用真实订阅，也不把开发机浏览器或代理路径当成设备证据。真实机场、DNS、透明代理、硬件驱动和业务探针仍必须先在可本地恢复的 canary 验收；canary 不可用时不得改用远程 replica 试错。

设备只能通过本地控制台恢复时，`scripts/recover-openwrt-local.sh --check` 只读回报 `/var`、ubus、Nikki Profile 和 Mihomo；仅在确认 `/var` 被错误替换成普通目录后，才使用 `--repair-var-link`。修复会把原目录完整移动到 `/root/opl-netfleet-recovery/` 后恢复相对链接，不删除备份、不停止 Nikki、不重启设备。其他故障返回 `needs_local_recovery`，由现场 owner 决定后续动作。

## 仓库内容

- [docs/README.md](docs/README.md)：文档地图与语义 owner；
- [docs/architecture/overview.md](docs/architecture/overview.md)：当前架构总览、产品合同导航和机制准入；
- [docs/design/ui.md](docs/design/ui.md)：双宿主视觉语言、LuCI 主题映射、页面布局和组件规范；
- [docs/product/whitepaper.md](docs/product/whitepaper.md)：产品理念、五类增强和机场无关策略基线的理想形态；
- [AGENTS.md](AGENTS.md)：开发、设备写入和文档生命周期约束；
- [LICENSE](LICENSE)：许可证；
- `scripts/deploy-openwrt.sh`：从精确 canonical Git object 构建并部署，不读取开发 worktree 的未提交内容。

运行时代码位于 `openwrt/files/usr/libexec/opl-netfleet/`：`core/` 只处理 policy、编译、选择、证据、事件和激活判定；`adapters/` 是 UCI、Nikki、Mihomo、服务和文件 I/O 的唯一边界，其中 `uci.uc` 覆盖 JSON/YAML 只读转换、quota metadata 和 evidence 落盘；`main.uc` 是唯一激活事务进程，每次动作只启动一个前台进程。`core/activation.uc` 不持有 I/O。唯一 `supervisor.uc` 按 policy 周期调用 `main.uc maintain` 与 `main.uc refresh`，或在 active runtime 连续失联超过 grace 后调用 `main.uc recover`；它不实现算法、不直接写 selector，也不清理 DNS/nft/路由。生成 Profile 的“自动选优 / 主用机场 / 备用机场 / 当前优选 / 代理路径”组名由 compiler 固定拼接，不是 UI 文案表。共享 UI 的延迟着色读取 `status.selection.region_switch_margin_ms`，不在前端写死 150，也不按 capability id 猜测图标。设备私有 policy 位于 `/etc/opl-netfleet/policy.json`，最近一次 automatic 轮次的覆盖式候选结果及固定空间地区/机场 delay 聚合持久保存于 `/etc/opl-netfleet/evidence.json`，成功的 enable/select/disable、订阅刷新和周期选择事件位于固定上限的易失 `/var/lib/opl-netfleet/events.json`；二者都不参与下一轮选择。唯一生成配置为 `/etc/nikki/profiles/opl-netfleet/mvp.json`，manifest 与它同批保存在内部目录；Nikki 根目录的 `OPL-NetFleet.json` 只是指向该文件的受控相对软链接，不复制配置。UCI `nikki.config.profile` 正式指向 `file:OPL-NetFleet.json`，因此 Nikki 的“选择配置文件”会显示 `OPL-NetFleet.json`。每个地区/机场只保存最近最优、累计最优、样本数和采样时间；平均最优由累计值计算。历史只绑定实际延迟测量口径，代码、UI、自动周期、设备重启和其他无关策略更新不会清空；拓扑变化按稳定机场/地区 ID 保留仍存在对象、裁剪移除对象并为新增对象建立单样本，只有测量 URL、期望状态、timeout 或模型变化才整体重置。部署器首次升级会把仍存在的旧 `/var/lib/opl-netfleet/evidence.json` 原子迁入持久路径并纳入回滚。所有历史值只用于展示、从不参与选路。共享 UI 调用 `status`、`events`、`connections`、`enable`、`select_auto`、`refresh` 和 `disable`；四个公开 mutation 都只是同一 one-shot UCode owner 的薄入口，并与 supervisor、部署器共用同一个设备锁。应用空闲时不轮询、不测速、不解析订阅；事件视图按需读取 Mihomo 当前活动连接的脱敏规则命中链，并只读 Nikki core log 中最近的 `NETFLEET-` 行，不缓存连接、不增加监听进程。编译顺序固定为“海外加速 / AI 出口”、基础顺序中的显式业务策略组、其他保留组和 NetFleet 内部组；业务组成员只包含自动、整合地区和 DIRECT，并保留 Policy Source 声明的直连优先默认。Mihomo 最后暴露的保留组只叫 `GLOBAL`，基础策略不再创建近同名 `Global`。`hidden` 仅优化支持它的客户端，不能承担拓扑正确性。状态投影中的机场名称、订阅制机场到期时间和基础原生配置显示名读取 Nikki metadata，地区名称读取 policy 的 `flag + display_name`，共享 UI 将成对 regional-indicator 通用转换为 ASCII 两位地区代码；机场/地区/节点统计由同一 `status` 请求各读取一次 Mihomo `/proxies` 和 `/providers/proxies`。机场表和地区表都显示最近最优、平均最优、样本数和最后测量；平均值在至少两个有效样本后才显示，单样本明确标为“样本不足”。界面排序只影响展示，不参与运行时选路。

`adapters/policy_source.uc` 是 Policy Source 的唯一平台边界：`bundle` 读取 NetFleet 自有 JSON，迁移用 `profile` 才经过 Nikki YAML 的只读转换；core/compiler 不关心文件来源。

保护探针通过隐藏的单成员直连护栏组执行；最终数据路径仍为 `DIRECT`，但探针 delay 不写入内置 `DIRECT` 的 Zashboard 历史。用户主动对 `DIRECT` 执行测速仍会产生该次测量值。

## UI 开发与部署

UI 交付固定分为两个阶段，避免每次视觉调整都编译并部署设备：

1. `ui/` 作为本机快速参考开发面，使用尽量贴近 LuCI 原生信息密度和组件结构的 React/Vite 页面，通过实时只读桥接或 fixture 快速确认信息层级、分页、文案和交互；此阶段不修改设备页面。
2. React 参考效果确认后，一次性把已确定的信息与交互翻译到 `openwrt/luci-app-netfleet/` 的原生 LuCI `view.extend`/`E()` 页面，并走 package、设备部署和运行验收；开发过程不反复向设备部署未定稿页面。

两端共享运行状态 schema、概览/出口/机场/地区/事件与诊断五页观察结构和展示语义，不共享 React 组件或 bundle，也不要求像素一致。React 另外提供配置页和首次设置向导，用本地草稿模拟未来设备端结构化配置交互；React 只负责快速确认参考效果，LuCI 原生 source 是唯一设备页面 owner。

本机实时预览不编译 OpenWrt package、不安装设备文件，也不开放真实启用、选优、配置写入或关闭等 mutation。目标 SSH alias 和可见名称只从本机环境变量取得，不进入 bundle 或 Git：

```bash
cd ui
bun install
NETFLEET_UI_TARGET=<ssh-alias> \
NETFLEET_UI_TARGET_LABEL="Canary" \
bun run dev
```

配置目标时，页面优先使用实时只读数据，并显示数据来源、连接状态、最后读取时间和耗时；浏览器只请求本机 Vite bridge，设备凭据始终由本机 SSH 管理。配置页以同一次真实 status 中的机场、地区和出口名称初始化本地草稿，保存、校验、应用和首次设置都只模拟浏览器状态并明确显示“不会写入设备”。未配置目标时，页面提供“健康运行 / 机场回退 / 原生配置”三个脱敏合同情景。需要离线复现私有投影时，可在 Git 外准备 `{"status": {...}, "events": {...}}`，通过 `NETFLEET_UI_FIXTURE=/private/path/ui-fixture.json bun run dev` 加载；文件不得包含订阅、设备地址、完整节点清单或凭据，也不得提交到仓库。

本机参考 UI 使用 `bun run test`、`bun run typecheck` 和 `bun run build` 验证。当前设备端已经具备唯一配置 owner、结构化 RPC、原子 policy 保存与 staged/apply/rollback；后续配置交互变化必须先更新同一产品合同，再同步 React 参考面和原生 LuCI source。只有生产纵向链落地后才走 canonical package、QEMU、目标 owner readback、业务探针和浏览器验收。React 构建产物不得复制进 LuCI package。

YAML 只存在于 Nikki/Mihomo 的外部 Profile 边界。设备上的 `yq` 只允许将不可控的 Nikki YAML 只读转换为 UCode 使用的 JSON；禁止 `yq -i`、复杂表达式或直接改写订阅、active Profile 和 runtime 配置。NetFleet 的 Policy Bundle、policy、evidence、manifest 和 artifact 使用 JSON；内置基线位于 `/etc/opl-netfleet/policy-sources/base-v1.json`，artifact 先写同目录临时文件，经 `mihomo -t` 和身份校验后原子替换。

多个 provider 只通过 target-local policy 引用 Nikki 的稳定命名 subscription section，cache 路径由该 section 唯一派生；匿名 `@subscription[n]` 和独立 `cache` override 会因 UCI 排序产生错绑，必须在 compile 前拒绝。全局 `main.enabled=false` 时允许所有 capability 关闭并保留配置；全局允许启用时至少开启一个 capability。compiler 为每个 enabled provider 生成一个 `type:file` source、受控 SAFE_PATHS symlink、Mihomo Provider 级 URLTest 和 Provider/地区 URLTest；automatic 模式的机场组只接收该机场 `provider_regions` 已授权 filter 覆盖的节点，未映射节点和订阅元数据不能进入 automatic/fallback。NetFleet 不自行下载、解析、合并或复制订阅；安装器与 runtime refresh 都只调用 Nikki 官方 updater，由 Nikki 维护下载、metadata、格式校验和单机场 cache。runtime 默认每 12 小时调度一次，失败保留旧 cache，摘要变化且 NetFleet active 时才重编译、重载、重新选优和执行 protected probes。enable/select 必须通过 policy 中的 protected probes；disable 以 Nikki 原生 owner/runtime 恢复或已验证的 cleanup passthrough 为成功条件，并单独返回业务探针结果。远端业务探针失败不会关闭一个已经健康恢复的原生 Profile；只有原生 runtime 无法恢复才进入 Nikki 官方 stop/cleanup。其他文件只有在当前 MVP 的真实 caller、运行 owner 或验收需要时才增加。生产代码、配置、协议、UI 和测试必须同批出现；删除 caller 时同批删除实现、配置、测试和文档。

NetFleet active 期间的机场故障层只由 `providers.<id>.role=primary|reserve` 决定：当前优选失败后先使用 primary tier，全部失败后才进入 reserve，最终 DIRECT。`policy_source` 决定 compiler 从机场无关 bundle 或迁移 Profile 读取规则与策略组；`recovery_profile` 决定 NetFleet 关闭或事务恢复后 Nikki 使用哪个完整原生 Profile。manifest 独立校验两者，任何一个变化都会使 staged 失效。若要更换恢复目标，必须先独立验证该 Profile 的规则、DNS 和保护业务；compiler 不会从 provider 自动合成恢复 Profile。

## 自动选优的测量边界

enable、显式 `select <root-capability> auto` 和 supervisor 的定期调度执行同一个有界轮次：先记录各 Provider/地区 URLTest 的现有历史尾部，再按独立的 `checks.provider_healthcheck_timeout_ms` 总预算对每个 enabled provider 并发触发一次 Mihomo 原生 health-check，并按 automatic capability 的无环依赖顺序，以统一 `checks.latency` URL/expected status 和单节点 timeout 比较候选。整机场批量检查不会再被单节点 delay 的较短预算提前终止。根能力先选地区；跟随能力若该地区满足自身限制就直接复用，否则选择自身同轮最快的合格地区。例如海外加速可选香港，而 `ai-compatible.excluded_regions=["hong_kong"]` 时 AI 会自动选择非香港地区。capability group delay 直接返回的结果优先；对未返回的组，只补入本轮后历史时间戳确实变化、delay 大于 0 且组和叶子仍健康的结果。候选叶子还必须同时属于该组成员列表和 manifest 绑定的 provider source；另一机场的同名节点或只有全局 `/proxies` 记录的节点不能冒充该候选。旧历史不能补位，也不发起第二轮候选测速。`fail_open.probes` 验证变更前后关键业务，并由 `fail_open.healthcheck.path_probe_id`/`guard_probe_id` 显式引用为两层 Mihomo fallback 的运行期健康目标；它们不参与速度排序。quota 只取 Nikki metadata 的 `available/exhausted/unknown`。跨地区与地区内叶子分别使用显式 `region_switch_margin_ms`、`leaf_switch_margin_ms`（默认都为 150）；没有可比较 delay 时不伪造“最佳”。

Provider 和 Provider/地区 URLTest 本身不创建独立任务；唯一 supervisor 只在到期时触发上述同一轮次。地区内 connection refused 会立即、其他拨号/握手错误会按 `max_failed_times` 和 timeout 窗口触发 Mihomo URLTest；当前叶子被标为失活后，下一次选路使用最快存活叶子。仍可用时，Mihomo 只有在 `current_delay > fastest_delay + tolerance` 时切换，因此默认 `leaf_switch_margin_ms: 150` 表示替代叶子严格快超过 `150 ms`。Provider/地区候选组只用统一 `checks.latency` 排序；Provider tier 组改用 `path_probe_id` 判断业务可用性。生成 Profile 复用两层 Mihomo 原生 lazy fallback：内层依次使用 preferred、primary provider tier、reserve provider tier；外层按 `guard_probe_id` 在 proxy path 和明确的 `DIRECT` 终点之间兜底。两层共用显式 `timeout_ms`、`interval_seconds` 和 `max_failed_times`。Mihomo 不会重放已经失败的同一个连接，后续连接才使用新路径。quota 不独立轮询；下一次 enable/显式/定期 auto 排除明确耗尽机场，运行中实际断流则走同一 fallback。显式事务恢复先使用 active guard 的 DIRECT 建立即时安全护栏，随后恢复整个 Recovery Profile；原生 runtime 仍无法恢复时才调用 Nikki 官方 stop/cleanup 进入 passthrough。NetFleet 不自写 DNS/nft/路由清理。enable 的 fallback 初始化只作 best-effort；只要所选叶子、实际 preferred 链和全部事务探针已回读成功，备用分支缺项或祖先组重启期的瞬时 `alive=false` 不构成 activation 失败。运行期 protected probe 只改变 Mihomo fallback 数据路径，不写排序 evidence，也不能推翻已成立的 cleanup/persistence readback。

全部代理路径失败后，`DIRECT` 表示后续连接改走无代理直连，不等于“所有海外流量都断开”；具体海外站点是否可达取决于直连出口。

supervisor、LuCI rpcd 和部署器共用一个短生命周期 mutation lock；持锁调用者在启动 UCode owner 时关闭子进程的锁 fd，Mihomo 不会继承并长期占用部署锁。

## Canary -> replica 推广

先在可本地恢复的 canary 完成 `compile -> staged -> enable -> owner readback -> disable`，
再冻结 artifact、配置和命令并原样推广到单独授权的 replica。完整基线、验收和恢复顺序见
[Canary 推广与复原](docs/operations/canary-promotion.md)。

最短复原是直接在 Nikki 切回 `recovery_profile.ref`；若 Mihomo/Nikki 已失效，则执行 Nikki 官方 stop 进入 passthrough。只 compile/staged 不需要恢复；active 时执行 `disable`，恢复失败也不会重新启用 NetFleet，artifact 保留供后续修复。NetFleet 不拥有 DNS、nft、路由或 Mihomo cleanup，因此手工复原不依赖 NetFleet supervisor；直连保护域名若被上游限制，系统会报告真实结果而不伪造成功。source 中的唯一 supervisor 会在 active runtime 连续失联超过 grace 后调用同一个恢复 owner，优先恢复 Recovery Profile，失败才请求 Nikki 官方 stop/cleanup；这一能力是否已在某台设备生效仍以该 target 的 installed/effective/runtime readback 为准。

## 当前验证

日常快速验证：

```bash
scripts/check-fast.sh
```

`check-fast.sh` 只运行源码结构、VM/脚本契约和发布工具测试；本机没有 `ucode` 时明确把 UCode 合同交给 OpenWrt/QEMU，不把缺少可选运行时误报成产品失败。

完整 fake-device 部署矩阵仍然保留全部 51 个独立场景，但通过独立临时设备并行执行：

```bash
scripts/check-full.sh
```

默认最多 8 路并行，或用 `scripts/check-full.sh --workers 4` 限制并发。它不删除安装、权限、回滚、控制面恢复等安全场景，只消除串行调度和每个场景互相等待；QEMU qualification 仍按精确 commit/tree receipt 单独执行并缓存，不在每次源码回归中重复启动虚拟机。

当前环境是否具备 OpenWrt SDK 由 `scripts/netfleet-package-build.sh` 在执行时判断；没有 SDK 时只报告不可构建，不伪造 package。每个行为变化仍必须先运行覆盖真实 caller 的最小路径，再按 blast radius 扩展；source 测试不能替代设备验收。
