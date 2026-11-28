# 交付物与配置输入

本文定义代码交付物、用户私有配置和生成部署输入之间的共同边界。平台包格式、安装布局、
更新机制与命令见 [OpenWrt](../platform/openwrt.md#软件包更新与部署输入)和
[macOS](../platform/macos.md#打包与签名)；操作入口见[README](../../README.md)。

## 代码与私有状态

代码交付物绑定可回读的源码身份和依赖，不能包含用户 policy、订阅地址、节点、凭据、
运行快照或设备日志。安装代码与启用网络是不同操作；安装不得隐式接管网络或覆盖私有输入。
磁盘上的版本、正在执行的版本和已验证行为分别报告，不能用其中一项代替另一项。

## 平台交付与版本身份

两个平台共享主线、产品版本与 annotated `vX.Y.Z` 源码 tag。`product-version.json`
同时维护产品版本 `version` 与最低薄壳要求 `min_shell_version`（仅在薄壳宿主、init、rpcd 或系统依赖合同发生不兼容变更时递增，使常规 Release Bundle 更新保持核心转发无扰保活）；发布准备同步 OpenWrt 产品包和 macOS Info.plist。插件按实际内容
独立版本化，macOS 内部构建序号递增。各平台分别验收自己的制品，未通过的平台
保持待验收；已经发布的制品通过同一 tag 追溯。发布不触发安装或网络接管。

交付身份由平台版本、构建修订、完整 `source_commit` 和 `source_tree` 共同确定。
安装产品通过唯一 `build` 投影向界面提供版本、修订、渠道、提交与 tree；读取位置由各平台
提供（设备读包内构建记录与部署器写入的已安装身份，macOS 读应用包内 `build.json`），
字段名允许包格式差异，缺少任一必需字段时投影为未记录而不是猜测。
版本号只在对应平台或插件内比较，不以版本号相同推断代码相同，也不为保持数字一致而
发布未变更的平台。源码提交表示来源，产物身份及安装回读表示实际交付；三者分别记录。
正式交付源码必须已被最新远端主线包含；主线后续前进不改变已冻结候选的身份，
也不使其同源码、同产物验收失效。正式交付不得把未提交字节标成干净提交的产物。允许开发快照，但必须显式标注，不能充当
已交付版本的验收证据。平台版本的权威位置和产物记录归对应平台文档，操作流程归
[平台交付](../development/delivery.md)。

## 插件版本

NetFleet 自有插件采用三段数字 `主版本.次版本.修订号`（`X.Y.Z`），沿用
[语义化版本](https://semver.org/lang/zh-CN/)：不兼容变更递增主版本，兼容功能递增次版本，
修复与发布包装变更递增修订号。插件独立递增，不要求所有插件具有相同数字。
插件 manifest、安装包及产品页面使用同一个版本，不再设置第二条 `rN` 打包修订序列。
相同版本不得重新发布不同内容；源码提交和产物摘要继续识别精确字节。

迁移已有安装时，新数字版本必须高于旧包的完整版本，不能直接把已安装的 `X.Y.Z-r1`
改名为 `X.Y.Z`。更新器继续按包管理器原始身份校验旧包和回退包；历史包可读，
新包只生成三段数字版本。页面对历史包展示其产品版本，完整旧身份留在技术详情，
不为历史 `rN` 新增另一套用户可见命名。第三方软件保留上游版本与包身份。

默认 OpenWrt 产品（微内核、宿主适配器、内置服务插件与版本号化前端资源）采用“薄系统包壳（`opl-netfleet`、`luci-app-netfleet`）+ 签名纯源码 Release Bundle”交付：所有 `.uc` 与静态资源保持纯源码并绑定完整 `source_commit`、`source_tree`、文件清单摘要和最低系统壳版本 `min_shell_version`，在设备 `/usr/share/opl-netfleet/releases/<version>/` 下验签展开后，通过 `current` / `previous` 原子符号链接生效与即时回退。因此不再对内置产品执行构建期跨分支 `ucode -c` 字节码预编译；需要原生二进制或内核 ABI 绑定的组件（如 `mihomo-meta`）及第三方扩展插件继续由系统包（`.apk` / `.ipk`）独立交付与维护。针对独立插件包来源的合并分发，`scripts/netfleet-feed-build.sh --merge-feed <base-feed-dir>` 可将新签名插件包叠加到既有已验签 Feed 并重新生成签名索引。

## 配置权威与部署投影

private OPL Instance 是用户私有 desired configuration 的权威。deployment bundle 是
从该权威生成并供部署器消费的投影，不是第二个 Instance，不手工维护；具体文件和平台
输入见平台文档。跨目标可以复用代码交付物，不能复用运行状态、秘密或验收授权。
相同输入的重复安装不得隐式刷新订阅或切换数据面。

## 更新与恢复

默认 OpenWrt 产品的日常软件更新在 `apk` 与 `opkg` 设备上共用同一 Release Bundle 原子更新引擎，分为 `check -> stage -> prevalidate -> handoff -> switch -> verify -> commit`（失败执行 `instant-rollback`）七步：

1. **只读检查与壳门控**：读取签名 `release-manifest.json` 及其分离签名，核对 `min_shell_version` 与系统壳 `/usr/share/opl-netfleet/shell.json` 及系统包依赖满足度；若新 Release Bundle 要求更高版本系统包壳或新增系统依赖，拒绝直接套用 Bundle 并提示管理员先经系统包管理器升级系统包壳。
2. **隔离暂存与预检**：下载并验签 `opl-netfleet-bundle-<version>.tar.gz` 到 `releases/.staging-<version>/` 并逐文件校验摘要，随后在不停止运行服务和未持有网络锁的前提下运行一次性 `loadfile()` 编译检查与完整微内核 `composition_report`（合并设备 `/etc/opl-netfleet/system.json` 与 `/etc/opl-netfleet/extensions/` 扩展），任何错误直接清理 staging 目录。
3. **保活交接与原子切换**：持全局更新锁将旧 `current` 与运行意图写入持久 `pending` 事务指针；若候选的启动脚本与网关接口契约未发生变化，沿用保留核心交接，仅暂停持代码读锁的管理/观察进程而不中断运行中的 Mihomo 核心与数据面。确认后以同目录临时符号链接原子替换 `current`（及 `previous`）与静态资源投影并同步 `rpcd`。
4. **有界验收与即时回退**：等待控制面就绪后核对新 `current` 身份、微内核图、网关状态与保护探针；通过后淘汰超出保留上限（最近 2 个 generation）的旧版本目录并清除 `pending` 指针。任一校验失败或写期断电后由 `opl-netfleet-update-recovery` 触发启动恢复，仅需将 `current` 原子切回 `previous`、恢复原服务运行意图并复核探针即可秒级回到上一确定一致版本；原生核心若已停止且恢复仍失败，仍兜底执行既有 DIRECT-first 清理边界。

独立签名插件包更新仍由对应平台包管理器事务执行：准入前验证既有服务/资源/启动脚本契约，并通过内核代码租约与 `drain`/`resume` 有界排空恢复；更新独立插件或核心程序继续分别确认，仍拒绝在组件自更新入口中未经授权替换核心程序或系统库，legacy 28 包安装则通过专用单事务引导完成向薄系统包壳的平滑迁移。

安全自动更新由 `policy.automation.plugin_auto_update_enabled`（默认关闭）与 `plugin_auto_update_interval_seconds`（默认 86400，允许 3600–2592000）控制，仅在网络健康、已配置签名源且无在途事务时由 `scheduler` 触发：优先检查受信任的 Release Bundle 候选并在 `min_shell_version` 及依赖满足时执行可自动回退的升级，同一候选失败或回退后记录失败指纹与指数退避截止时间。需要升级系统包壳（shell）或 Mihomo 核心等系统包时延后交由管理员显式维护。

可恢复更新必须在停止健康服务前取得候选及回退材料；失败恢复代码、私有输入与运行意图，逐项回读，不能将包工具或符号链接切换返回成功当作网络恢复。任何状态下均不得把代码载体、回退 staging 或临时事务文件混入 `/etc/opl-netfleet/` 用户配置目录。

## 验证边界

共享源码检查、平台构建、安装运行和真实网络验收分别成立。发布身份绑定实际构建源码，
不以调度事件身份替代；公开分发还需从真实分发入口回读交付物。
各平台的构建和验收入口归[开发验证](../development/validation.md)，不能把一端通过
扩展为另一端通过，也不能把开发构建解释为已签名公证的公开版本。

各渠道的具体构建、验收与发布命令见[双平台交付](../development/delivery.md)。
