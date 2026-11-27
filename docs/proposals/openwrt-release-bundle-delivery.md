# Proposal：OpenWrt 薄系统包壳与不可变 Release Bundle 统一交付（路径 B）

- **状态**：Draft Proposal（未进入当前实现；不改变[交付物与配置输入](../architecture/packaging.md)或[OpenWrt 平台实现](../platform/openwrt.md)定义的当前合同）
- **目标读者**：NetFleet 架构维护者与 OpenWrt / macOS 交付工程负责人
- **拥有唯一问题**：如何用一套与包管理器（`apk` / `opkg`）解耦、无需为各 OpenWrt 分支维护独立 SDK 的交付模型，同时支持 OpenWrt 24.10（`opkg` 及兼容衍生版）与 OpenWrt 25.12+（`apk`），并把默认产品更新与回滚收敛为原子符号链接切换？
- **前置边界**：本方案不含任何私有目标名称、局域网地址、SSH 入口、订阅或凭据；所有现有[跨主题硬下限](../architecture/overview.md#跨主题硬下限)、配置与代码分离约束（[ADR 0004](../decisions/0004-package-and-deployment-bundle.md)）及 DIRECT-first 安全下限保持不变。

---

## 一、现状与三大结构性瓶颈

当前 OpenWrt 交付链在跨版本扩展和实体设备升级中暴露了三项耦合：

1. **构建期 `ucode/host` 字节码预编译把纯脚本绑定到固件 ABI**
   - `openwrt/Makefile` 与 `openwrt/compile-plugins.py` 在构建期调用宿主 SDK 的 `ucode -c` 将服务模块编译为字节码。
   - 字节码格式强绑定目标固件的 UCode 解释器版本（例如 OpenWrt 24.10 常见 `ucode 2025.07` 与 25.12 不同），导致支持一个新分支或衍生固件就必须拉取并维护整套数百 MB 的 OpenWrt SDK。然而 NetFleet 默认产品本体（微内核、功能插件、LuCI 视图、init/rpcd）全部由 `.uc`、`.js`、Shell 与 JSON 构成，不含 C/Go 二进制。
2. **纯脚本产品拆分为 27+ 个系统微包，把应用热更新重度压到系统包管理器上**
   - 每个插件一个 `.apk` 并伴随多条 `EXTRA_DEPENDS` 与 `CONFIG_USE_APK` 专属冲突声明，使一次日常更新变成几十个系统包校验、逐包 `preinst/postinst` 钩子排空与 `/etc/apk/world` 状态操作。
   - 当新版本新增文件而候选钩子失败回滚时，旧包还原层不得不额外跟踪“新版独有文件”、核对 `adbdump` 摘要和还原 `world` 摘要锁定，事务脆弱且耗时冗长。
3. **组件自更新器深度绑定 `apk` 原语，无法自然覆盖 `opkg` 设备**
   - `plugins/components/lib/control.uc` 依赖 `apk --format json`、`/etc/apk/world`、`/lib/apk/db/installed` 及原生签名索引验证。
   - 若为 `opkg` 复制一套同等复杂度的多微包事务回滚引擎，不仅在 `opkg` 缺少 `world` 声明与 JSON 查询接口的前提下极易出错，还会让后续维护成本永久翻倍。

---

## 二、目标架构：三层分离（路径 B）

核心原则：**系统包只拥有“系统依赖、固定宿主入口和二进制原语”；NetFleet 纯脚本产品代码回归不可变的签名 Release Bundle，通过 POSIX 原子符号链接统一在 `apk` 与 `opkg` 设备上完成安装、热更新与秒级回退。**

### 1. 第一层：薄系统包壳（Thin System Package Shell）

- **包粒度收敛为 2 个架构无关包（`.apk` 标 `noarch`，`.ipk` 标 `all`）**：
  - `opl-netfleet`：声明全部系统运行时依赖（`ucode`、`ucode-mod-fs`、`ucode-mod-uci`、`ucode-mod-ubus`、`ucode-mod-uloop`、`ucode-mod-socket`、`ucode-mod-digest`、`yq`、`curl`、`ca-bundle`、`flock`、`coreutils-timeout`、`ip-full`、`nftables-json`、`kmod-nft-socket`、`kmod-nft-tproxy`）；安装稳定的系统胶水入口（`/etc/init.d/opl-netfleet`、`/etc/init.d/opl-netfleet-core`、`/etc/init.d/opl-netfleet-update-recovery`、`/usr/libexec/rpcd/opl-netfleet*`、内置默认策略基线）以及受信任的 Release Bundle 验证公钥，并在首次安装时置入初始基线 Bundle、保持服务默认停止且禁用。
  - `luci-app-netfleet`：声明 `+luci-base` 与 `+opl-netfleet`，安装 LuCI 菜单/ACL/视图入口，通过固定路由映射访问当前活动 Release Bundle 的静态资源（`current` 符号链接）。
- **零 SDK 确定性 `.ipk` 构建器**：
  - 由于薄壳包与 Release Bundle 均不含待编译的 C/Go 代码，提供纯 Python 确定性构建脚本直接封装符合 Debian/OPKG 规范的 `.ipk`（`debian-binary` + `control.tar.gz` + `data.tar.gz`），生成标准 `Packages` / `Packages.gz` 及 `usign` 签名索引。
  - OpenWrt 25.12+（`apk`）与 24.10 / iStoreOS（`opkg`）共用同一份仓库源码直接出包，彻底消除维护多套 OpenWrt SDK 的需求。

### 2. 第二层：不可变签名 Release Bundle（Pure-Source Atomic Payload）

- **产物组成**：每次发布产出单一紧凑归档（例如 `opl-netfleet-bundle-<version>.tar.gz`，数百 KB）、对应分离签名文件以及绑定 `source_commit`、`source_tree`、文件清单摘要和最低系统壳版本要求（`min_shell_version`）的 `release-manifest.json`。
- **纯源码分发与可选本机按解释器缓存**：
  - Bundle 内全部 `.uc` 文件保持纯源码，延续现有[微内核与功能插件](../architecture/microkernel.md)服务目录结构（`kernel/`、`adapters/`、`plugins/<id>/manifest.json` 与 `resources/`），不改变插件清单、服务绑定与访问控制契约。
  - 彻底取消跨平台构建期字节码注入。若未来在低性能硬件上确需字节码加速，仅由设备端在 `releases/<version>/` 旁以**本机 `ucode -c`** 生成只读派生缓存并绑定本机 `ucode` 版本指纹；解释器升级或缓存失效时无缝回退源码执行，绝不跨设备传播字节码。
- **设备端只读目录布局**（全部属主 `root:root`，权限收敛，严格隔离在 `/etc/opl-netfleet/` 用户私有状态之外）：
  - `/usr/share/opl-netfleet/releases/<version>/`：解压并验签后的不可变版本目录（只包含内核、适配器、默认服务插件及版本化静态 UI 资源）。
  - `/usr/share/opl-netfleet/current -> releases/<version>`：唯一生效的运行期符号链接入口；`/usr/libexec/opl-netfleet` 与 `/www/luci-static/resources/netfleet/bundle` 指向 `current` 对应子目录，与浏览器缓存隔离的版本路径（含 `payload_revision` 或 `<version>`）共同生效。
  - `/usr/share/opl-netfleet/previous -> releases/<prev>`：保留的上一已验收版本（最多保留最近 2 个完整 generation，避免叠加占用闪存）。

### 3. 第三层：原生二进制、内核模块与外部插件边界

仍需要原生编译或内核 ABI 绑定的组件继续完全由系统包管理器（`.apk` / `.ipk`）拥有，不混入 Release Bundle：

- `mihomo-meta`（按 CPU 架构封装上游静态核心的 `.apk` / `.ipk`；在已运行兼容 `mihomo` / Nikki 的设备上不强制替换已有核心）。
- `opl-netfleet-https-compat`（含 C/HAProxy 引擎与 `kmod-nf-conntrack-netlink` 依赖）。
- `opl-netfleet-device-identity`（含本地邻居探针二进制）。
- 第三方或独立安装的扩展插件：安装并持久化在独立扩展空间（如 `/etc/opl-netfleet/extensions/` 或独立插件包目录），微内核合并发现时保留管理员独立启用的扩展，不被产品 Release Bundle 的切换覆盖。

---

## 三、统一原子更新与即时回滚事务

在路径 B 下，**`apk` 与 `opkg` 设备在 LuCI「组件与更新」及后台调度中运行 100% 同一套 UCode 事务引擎**，更新耗时与风险从“几十个系统包的链式钩子”收敛为“单归档验签 + 原子目录切换”：

1. **`check`（检查与版本门控）**：从受信任的 HTTPS Feed 获取签名清单与 `release-manifest.json`，校验签名并核对 `min_shell_version <= installed_shell_version` 与系统依赖满足度；若上游要求新的系统依赖或壳版本，拒绝直接应用 Bundle 并提示先执行系统壳升级。
2. **`stage`（隔离下载与验签）**：下载单个 Release Bundle 归档，验证归档 SHA-256 与签名公钥；在 `/usr/share/opl-netfleet/releases/.staging-<version>/` 解压并逐文件校验 manifest 摘要与权限。此时不触碰 `current`、服务或网络锁。
3. **`pre-validate`（离线微内核契约校验）**：在 staging 目录内直接拉起只读一次性 `ucode` 校验脚本，结合设备当前 `/etc/opl-netfleet/system.json` 与已启用第三方插件执行 `composition_report`（校验所有服务依赖、命令、schema 与接口版本），失败直接清理 staging，不暂停任何运行中服务。
4. **`handoff`（受控排空或保活交接）**：持全局更新锁与短期网络写锁，将旧 `current` 目标及当前核心/supervisor 状态写入 `/etc/opl-netfleet/package-transactions/pending.json`；若候选与当前版本的 `opl-netfleet-core` 启动脚本及网关服务契约未变化，复用现有 `retained` 交接逻辑保持 Mihomo 核心与数据面持续转发，仅暂停观察/管理实例与代码租约。
5. **`switch`（POSIX 原子切换）**：执行 `mv -T` / `ln -sfn` 同目录临时符号链接原子替换 `current.next -> current`（以及 LuCI 静态资源映射），同步刷新 `rpcd` / 恢复管理观察实例，再执行 `sync`。不存在“新旧文件混杂”或“孤儿新文件残留”的中间态。
6. **`verify`（有界运行与业务验收）**：等待控制面就绪，校验新 `current` 的构建身份、Mikrokernel 服务图、DNS/TProxy 接管状态与受保护业务探针。
7. **`commit` 或 `instant-rollback`（即时回退）**：
   - 验证全部通过：记录 `previous`，清理旧 generation（仅保留最近 2 版）并清除 `pending.json`。
   - 任一环节失败或断电重启后由 `opl-netfleet-update-recovery` 启动恢复：只需将 `current` 原子切回 `previous`（单条符号链接切换）、恢复原服务运行意图并复核探针，即可在亚秒级回到升级前确定一致的字节集合；`opl-netfleet-core` 若被停止且恢复仍失败，仍兜底执行既有 DIRECT-first 清理边界。

---

## 四、跨平台与安全边界对齐

- **信任根与零信任输入**：公钥随系统壳安装包锚定在 root 只读目录，Bundle 与 manifest 必须由同一离线私钥签名；HTTP 非加密源仅允许用于受控本地 VM 资格测试；所有解压、校验和目录切换严格拒绝符号链接越界与非 root 可写路径。
- **用户状态与配置隔离**：`/etc/opl-netfleet/`（`policy.json`、`subscriptions/`、`native/`、`system.json`、`evidence.json`）永远不进入 Release Bundle，也不受版本目录切换影响。
- **Attended Sysupgrade (ASU) 能力分级**：`luci-app-netfleet-firmware` 的 ASU 系统升级扩展继续按能力探测启用（在 OpenWrt 25.12+ `apk` 固件且安装 `luci-app-attendedsysupgrade` 时挂载；在 OpenWrt 24.10 / `opkg` / iStoreOS 上由薄壳省略或保持不可用，不阻塞核心代理、订阅与组件更新功能）。
- **macOS 桌面端对齐**：macOS 端已经使用嵌入式纯 `.uc` 源码树消费同一业务插件目录（参见[平台能力表](../product/capabilities.md)与[macOS 实现](../platform/macos.md)）；OpenWrt 取消构建期字节码预编译后，双平台共享业务代码的验证与分发语义将实现完全对齐。

---

## 五、分阶段实施计划与准出条件

为保持主线每一步都可独立测试、无破坏性断档，按 4 个阶段推进；**上一阶段未取得对应平台实测回执，不推进下一阶段**：

### Phase 0：当前稳定性基线（先止血）
- **范围**：Lab 选优测量去重、耗尽机场过滤、Top-K 顺延激活、订阅刷新指数退避，以及现有 `apk` 回滚孤儿文件与 MMDB 隔离校验修复。
- **准出门禁**：全量 `scripts/check-fast.sh`（含 `test_fail_open_mihomo` 与全部 UCode 契约）通过；在当前 `apk` 发布链完成 VM 资格与目标设备回读验收。

### Phase 1：零 SDK IPK 构建器与 24.10/`opkg` 首次安装落地
- **范围**：
  1. 新增零 SDK Python 打包工具，基于同一源码直接产出 2 个 `all.ipk`（`opl-netfleet`、`luci-app-netfleet`）与按架构封装的 `mihomo-meta_<ver>_<arch>.ipk`，生成带 `usign` 签名的 `Packages.gz`（不启用构建期 `ucode -c` 预编译）。
  2. 扩展 `scripts/install-netfleet.sh` 自动识别 `apk` 与 `opkg` 分支（并确保 `components` 组件页在 `opkg` 环境下明确展示只读版本与外部升级说明，不调用 `apk` 报错）。
  3. 完善独立 OpenWrt 24.10 ARM64 QEMU 资格轨道（涵盖安装、首次设置 / Nikki 复用、DNS/TProxy 接管、Fail-Open 恢复与完整卸载清理）。
- **准出门禁**：24.10 QEMU 资格测试全绿，并在一台 `opkg` 兼容真实设备完成只读发现、受控安装与无残留回退验证。

### Phase 2：Release Bundle 交付与 `current` 原子切换引擎
- **范围**：
  1. 新增签名 Release Bundle 打包与发布清单生成脚本，并接入发布工作流（与现有产物并存验证）。
  2. 调整 `/etc/init.d/`、`/usr/libexec/rpcd/` 与 `luci-app-netfleet` 通过 `current` 符号链接解析微内核与静态资源。
  3. 在 `plugins/components` 中实现统一且包管理器无关的 Bundle 7 步更新、即时回退与启动恢复器；在 24.10（`opkg`）与 25.12（`apk`）两套 QEMU 环境下同场验证“升级成功（含核心保活）”“坏候选/坏视图即时回退”和“写期断电恢复”。
- **准出门禁**：两套 VM 资格轨道在同一次 Release Bundle 更新与回滚故障注入下全部通过，且升级窗口耗时显著下降、零残留文件问题。

### Phase 3：存量设备迁移、旧链退役与文档收口
- **范围**：
  1. 提供并验证从“28 包 `apk` 旧安装”平滑升级到“薄系统包壳 + Release Bundle”的单次迁移事务（保持全部 `/etc/opl-netfleet/` 策略、订阅与运行态不丢失，且迁移失败可回退）。
  2. 在独立授权的 `apk` 与 `opkg` Canary 设备上分别完成在线更新与故障回滚验收。
  3. 确认旧 28 包拆分及 `apk world` 逐包摘要修复路径已达 caller-zero 后，在同一批次删除遗留的逐插件 `.apk` 生成、`compile-plugins.py` 跨平台字节码逻辑和旧 `apk` 专属自更新代码。
  4. 将已成立的合同吸收回[交付物与配置输入](../architecture/packaging.md)与[OpenWrt 平台实现](../platform/openwrt.md)，更新[ADR 0004](../decisions/0004-package-and-deployment-bundle.md)的交付载体描述与重审边界，最后删除本 proposal。
