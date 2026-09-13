# OpenWrt 平台实现

本文拥有 OpenWrt 的运行宿主、网关与接管、配置和私有存储、管理传输、页面资源、软件包
及系统集成机制。共享对象、业务算法和恢复顺序归[当前架构](../architecture/overview.md)，
共同交互归[界面设计](../design/ui.md)，能力适用性归[能力表](../product/capabilities.md)。

## 平台组合

共享业务源码位于 `openwrt/files/usr/libexec/opl-netfleet`；OpenWrt 通过
`openwrt/files/usr/share/opl-netfleet/system.json` 组合，macOS 消费同一份业务源码并显式
替换平台服务。源码路径不是业务归属；模型与选择服务不能依赖 UCI、procd 或网关实现。
OpenWrt 默认绑定在 `/usr/share/opl-netfleet/system.json`，私有覆盖在
`/etc/opl-netfleet/system.json`，evidence 只写 `/etc/opl-netfleet/evidence.json`。订阅更新记录独立保存到
`/etc/opl-netfleet/subscription-history.json`，使用私有权限和同目录原子替换，保留跨服务重启、设备重启和软件包升级的时间基准。

## 软件包、更新与部署输入

### 软件包组合

`opl-netfleet-kernel` 安装通用入口、服务解析、插件生命周期内核、OpenWrt 宿主适配器及
`opl-netfleet.plugins` 通用管理 RPC，提供 `netfleet-plugin-api-v1`。
`opl-netfleet-plugin-*` 分别安装功能插件的 manifest、实现和
该功能拥有的资源、配置基线或系统入口。`opl-netfleet` 是默认产品聚合包，安装
`system.json` 与构建身份，依赖完整默认功能集合；`luci-app-netfleet` 提供插件页面宿主，
只依赖内核及必要的 LuCI 运行环境。默认产品的七个业务页面归
`opl-netfleet-plugin-product-ui` 所有；独立插件的界面不要求安装默认网络产品。
进程插件与 UCode 服务插件使用相同的 `/usr/libexec/opl-netfleet/plugins/<id>/` 安装空间，
服务组合合同见[微内核与功能插件](../architecture/microkernel.md)。

默认产品、`maintenance` 及当前 SDK 生成的插件包声明内核最低版本为 `0.8.1`；
当前 `product-ui` 与 LuCI 要求内核至少 `0.8.8`，`product-ui` 还要求 LuCI 至少 `0.8.4`，
由软件包管理器解析版本依赖，确保安装后具备通用插件 RPC、贡献与作用域接口。

包列表、服务绑定与插件依赖从源码 manifest 生成。每个服务的 `requires` 解析为提供者包，
`package_dependencies` 声明功能实际使用的 OpenWrt 系统包；构建前检查缺失服务、接口版本和
包依赖环。内核不依赖 Mihomo、订阅、选路或其他业务组件。默认系统配置的
`product_packages` 列出产品维护集合，管理员独立安装的第三方插件不加入该集合。

算法包 `opl-netfleet-plugin-selection-algorithm` 与选择控制器分开，独立安装算法不会
拉入控制器与后端依赖。`platform-storage`、`platform-openwrt` 与 `platform` 分别承载
存储文档、OpenWrt 配置和运行管理能力；安装依赖沿实际服务调用关系解析。

声明 UI 的插件把公开资源安装到
`/www/luci-static/resources/netfleet/plugins/<id>/<revision>/resources/`。revision 从
完整安装 payload 计算，与内核清单一致；包生成器和外部 SDK 共用同一计算与资源投影入口。
页面入口、静态 import 子模块、样式与其他相对资源处在同一版本目录，不依赖仅给入口
追加查询参数实现更新。资源源码同时保留在插件私有安装目录，以便身份校验；运行时配置
和凭据不放进公开资源。软件包管理器随该版本拥有和删除其公开投影。

### 版本化分发

NetFleet 自有包的 `PKG_VERSION` 使用[插件版本合同](../architecture/packaging.md#插件版本)中的
三段数字；`PKG_RELEASE` 留空，功能插件的 `VERSION` 直接消费 manifest 版本。
OpenWrt 原生支持无打包后缀的 APK/IPK；发布清单的 artifact `version` 是完整安装版本，
不再生成 `release` 或 `package_release` 字段。读取既有回退清单时仍识别其旧修订字段。


版本化 OpenWrt package 是 NetFleet 代码的可校验分发载体，绑定精确 source
commit/tree、package 架构、SDK 构建目标和 artifact checksum，只包含内核、功能插件、
系统入口和 LuCI 页面。package 不包含 target-local policy、订阅、Nikki mixin、URL/token、
节点或 secrets；package 安装/升级不绕过 staged/activate 合同，也不自动替换当前
数据面或设备私有生成 Profile。默认产品聚合包安装只读
`/usr/share/opl-netfleet/build.json`，以当前 package 的版本、source commit/tree 作为代码身份；
声明式部署的 `/etc/opl-netfleet/installed.json` 继续绑定 deployment bundle 和实例输入，但不能覆盖
较新的 package 身份。manifest v2 还绑定 package format、运行时文件摘要、
完整产品 package 集合和 APK 公钥（仅 APK）；每个插件 artifact 同时记录自身版本，
不要求插件版本与内核同步。`dependency_artifacts` 单独绑定核心包的
架构、版本、摘要和上游来源，不把核心字节混入 NetFleet runtime 摘要。APK 逐包签名必须使用本机私钥，私钥不进入
Git、发布目录或设备。没有真实 OpenWrt SDK 时，构建入口必须明确失败，不能伪造
package 或 manifest。APK 发布还包含同一私钥签名的 `packages.adb` feed index，并在
manifest v2 的 `feed_index` 字段绑定其 SHA-256。Release 同时包含 `install-netfleet.sh`，由
`feed_bootstrap` 字段绑定脚本名称与 SHA-256；该脚本下载公钥、原子写入公钥和
`/etc/apk/repositories.d/opl-netfleet.list`；仓库声明直接指向 `$feed_base/packages.adb`，使
`apk` 以 `ndx` 模式从同目录解析 package，而不是按目录型仓库扩展架构子目录。随后脚本在缺少
默认产品或 LuCI 时使用不带 `--upgrade` 的 `apk add` 补齐产品及依赖。脚本从签名 Feed
读取聚合包声明的内核和功能插件依赖，与聚合包、LuCI 一起定向升级；重复运行同样覆盖
完整产品集合。已有系统依赖满足约束时不得主动升级，不固定版本到 world，也不执行全系统升级。
它不得写入 policy、订阅或 Nikki mixin，也不得启用 NetFleet 或切换数据面。
已安装旧单体而没有内核包时，bootstrap 在写入软件源或执行包事务前拒绝升级。
跨包布局迁移须使用经过相同旧包组合与失败恢复验证的执行器，不能借普通安装命令绕过。
OpenWrt 默认 package lifecycle 会启动新安装或升级后的 init script；默认产品聚合包必须在
首次安装后显式停止并禁用服务。插件包在代码替换期间阻止默认 init 启动，恢复由
经进程身份校验的生命周期协调者执行。产品升级记录并恢复升级前的 enabled/running 状态，不能把
“文件升级”变成隐式接管或停用。
内核、默认插件与 LuCI 均只包含脚本、配置和静态
资源，因此 OpenWrt package 声明为 `PKGARCH:=all`：APK 元数据中的实际架构必须是
`noarch`，而 `build_target_arch` 单独保留生成该 Release 的 SDK 目标，例如
`aarch64_generic`。部署器允许 `noarch` 安装到任意目标架构；旧 Release 的原生架构兼容
规则只用于读取既有产物，不能用于生成新 Release。Release 的
`latest/download/packages.adb` 可作为稳定仓库索引，目标机只需安装一次公钥并写入
`/etc/apk/repositories.d/opl-netfleet.list`，之后即可使用 `apk update`、`apk policy`
和 `apk upgrade`。feed 只拥有代码包，不拥有订阅、policy、Nikki mixin 或运行时数据。

空白设备所需的 `mihomo` 由同一签名 feed 中的 `mihomo-meta` 提供；包名、虚拟依赖和
`/usr/bin/mihomo` alternatives 复用 Nikki 的约定。核心来自官方固定版本预编译资产，
`openwrt/mihomo-meta/source.json` 是版本、架构、下载摘要和对应 GPL 源码的唯一来源，
VM 与 SDK 都消费它。SDK 只校验、解压和封装，不编译 Go。核心包安装来源记录，
发布 manifest 同时提供固定源码入口和包装实现入口；不把 Nikki 服务作为依赖安装。
当前核心资产只覆盖 `aarch64_generic`，构建其他目标必须先增加对应经验证资产，不能
把 ARM64 核心标为 `noarch`。NetFleet 代码包可用于其他已具备兼容核心的架构，
但完整 feed 的空白设备安装能力受核心架构限制。已安装的 `mihomo` 提供者满足依赖时，
NetFleet 定向升级不升级或替换它；核心更新是独立显式操作。

### 设备端组件维护

LuCI 的“插件与更新”由设备包管理 owner 提供已安装 NetFleet、LuCI 和 Mihomo 的包版本，
Mihomo 实际运行版本另从控制接口读取，不把磁盘文件版本当作运行版本。关键依赖来自 APK
安装数据库；版本检查不混入常规网络状态读取。显式“检查更新”刷新签名 Feed，结果只表示
该 Feed 当前可用版本，不声称它是 Mihomo 上游最新版本。

更新只接受固定组件和用户刚确认的候选版本：NetFleet 默认产品集合在同一事务更新，
Mihomo 本体单独确认。已安装的可选 HTTPS 引擎有独立版本，Feed 提供候选时纳入一致升级；
未安装时不因主程序更新而增加该引擎。旧引擎依赖已移除的入口，默认产品组合通过版本冲突阻止
留下不兼容组合；内核不反向声明可选引擎依赖或冲突。APK 排序会遍历冲突关系，
而旧引擎又依赖产品，将冲突放在内核会使插件先于内核安装，破坏生命周期工具的可用性。
独立更新后高于产品 Feed 的插件版本继续保留；其已验证签名和包身份的
回滚归档同时用作未变版本的候选，不要求产品 Feed 重复提供独立插件仓库的版本。
包事务保留管理员的显式安装集合：默认依赖不会因为暂存 APK 更新而变成独立安装的包，
原本未固定版本的显式安装项也不会被临时归档的内容摘要固定；独立安装的插件继续保留。
候选漂移须重新检查；不执行全系统升级、不替换已有其他核心提供者，不默认启用定时升级。
Feed 安装器对软件源索引读取做有界重试，索引持续不可用时停止；安装、升级和服务切换不自动重放。
包管理器负责依赖解析、签名与架构检查。候选包及 NetFleet 自有回退包必须独立验签；既有 Mihomo 上游包若依赖仓库签名索引认证，回退归档同时保留原始签名索引和原包。APK 离线读取索引并校验包内容，按精确包名与版本恢复，不跳过信任检查、不重签上游包。索引与包共同绑定事务摘要，中断恢复沿用同一路径。写入前取得候选和可信旧版包，确认核心原子替换及
解包所需的可用空间；下载前先以签名索引的安装体积检查空间，取得候选包后再按包内元数据
复核，空间不足不得先停止健康核心。随后验证新核心能加载
现有配置；旧版无法取得时不停止正在工作的后端。更新复用当前服务 owner，保持私有输入，
失败恢复旧包和原服务状态，并回读控制接口、DNS/透明代理及保护探针。

包命令非零不能证明文件没有改变。组件回退按已安装版本、原运行代码摘要、私有配置和实际运行状态
分别回读；回退安装之后恢复事务保存的原运行文件，保留更新前已经存在的运行文件与包记录差异，并校验逐文件身份。包安装或 world 恢复报错仍须尝试恢复已验证的旧运行面。无法恢复时再次
尝试基础网络清理，保留各阶段失败记录，不能在首个错误后跳过网络恢复。
恢复只补启缺失的服务；已经运行的核心和监督器继续工作，随后仍须验证配置、选路及网络状态。
该回退只覆盖组件更新入口；外部迁移执行器必须独立通过相同旧包组合与故障注入验证。

有限插件更新通过同一组件事务的 `components-install <private-stage>` 入口提交精确包集合。
暂存描述只接受默认产品中已安装的功能插件及 LuCI 宿主包，逐包绑定候选与旧版的名称、版本和 SHA-256；
候选和回退目录必须恰好包含声明的归档，目标端再验证签名、架构和当前安装版本。
它不更新内核、产品聚合包、Mihomo 二进制或可选 HTTPS 引擎，也不修改软件源。
这里的 Mihomo 二进制与可纳入更新集合的 `mihomo` 功能插件是不同软件包。
更新器不自动扩展显式插件集合；APK 模拟检查已声明的包依赖，不检查服务参数和返回语义。
操作者须按[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)核对
真实调用关系与配套版本。入口将材料复制到
现有持久事务目录后交由同一 procd worker 执行；客户端断连后读取事务结果，不重新安装。
插件包钩子按依赖关闭准入并交接资源，事务不预先停止全部服务。失败继续使用同一快照与
回退 owner；正常结束仍验证原私有输入、选择、运行状态和业务探针。
APK world 中的版本及仓库约束必须保留并验证；旧本地归档的摘要固定项在成功更新时解除，
回退时恢复原摘要。已有摘要与已安装数据库不一致时，事务保留原记录供诊断，恢复目标
归一为该包的显式安装项，不重新施加一个实际未安装的摘要。此核对只针对显式更新集合，
不得将旧摘要原样复制到已更新的软件包数据库。

软件自升级会重启 rpcd，因此设备通过 procd 执行一个有界、无自动重试的一次性更新进程，
使用全局 mutation lock 和更新前暂存的实现完成事务；浏览器关闭或临时断连不取消更新。
这不是第二个网络 owner，也不拥有持久运行状态；页面通过只读进度接口确认最终结果。
组件更新的事务代码副本、候选与回退包、私有快照和阶段记录保存在 root 私有的
`/etc/opl-netfleet/package-transactions/`。写入前保存并同步恢复材料和 pending 指针，
组件事务 owner 才能停止服务与替换包。安装和回退 APK 的进程显式携带 `NETFLEET_PACKAGE_RESTORE=1`，并通过 `--preserve-env` 将该标志传入包钩子，
允许已排空依赖的包生命周期恢复核心；该标志仅作用于事务子进程，普通启动仍受 pending 保护。
普通失败立即回滚；进程中断或重启后，由同一
事务代码副本执行 `components-recover`，核对快照、包签名、安装数据库和私有输入后
恢复旧版与原运行意图。原生后端恢复先由事务副本中的网关清理接管并停止 procd 服务，
确认核心退出后恢复旧运行文件，再由 APK 恢复软件包数据库与生命周期。新的更新在 pending 未消除时拒绝；恢复失败保留全部材料，
不反复自动尝试；组件页可显式重试恢复。启动入口只触发一次恢复，完整运行与网络回读成功后才清除 pending。
终态记录也持久保存：若终态写入后、清除指针前中断，恢复核对对应版本与运行状态，
不把已经成功的更新降回旧版，也不重复启动仍在运行的服务；只补启缺失服务并验证运行状态。
恢复检查与失败写入操作进度。临时操作进度丢失不阻止清理已完成事务或后续更新。
暂存目录独立于用户备份，不把候选代码或回退包打进普通配置备份。

独立插件模式不要求开发机生成 deployment bundle。已有 Nikki 的设备可以复用当前原生
Profile 和有效 subscription cache；空白设备则由原生后端维护订阅和配置。安装 package
后由 LuCI 首次设置完成设备端发现和用户确认。package post-install 只刷新 LuCI/rpcd，并在
rpcd 或 uhttpd 当前执行上限低于 300 秒时提升到 300 秒、保留更高值并重启对应控制面；它不自动改变网络，用户确认后才由
target-local owner 创建 `/etc/opl-netfleet/policy.json` 并启用。
复用 Nikki 的路径沿用当前原生 Profile 的规则、DNS 与策略组，不下载第二份订阅；
原生路径由 NetFleet 维护订阅与其运行配置，具体边界见[运行与恢复](../architecture/runtime-and-recovery.md)。
`policy.example.json`、内置 Policy Source 和 ruleset lock 是 package 拥有的只读基线；APK
升级若为它们生成 `.apk-new`，拥有这些基线的 configuration 插件 post-install 必须原子采用新字节。用户
policy、订阅、mixin、生成 Profile 和证据不在该名单中，package 不得借此覆盖。

原生核心使用 NetFleet 自有 init/procd 服务，首次安装停止并禁用。卸载前置脚本先停止并回读本包注册的 procd 核心；
存在不匹配的服务身份或无法确认停止时拒绝卸载。没有 Nikki 配置或服务的设备不调用
Nikki 退出事务；有 Nikki 时仍执行原有恢复与卸载检查。`/etc/opl-netfleet/native/` 的
来源、缓存与 stage 属于用户私有输入，不进入 package，卸载不删除这些数据。

官方 SDK 解压后尚未生成 `.config`。发布准备入口只执行 `defconfig` 并回读目标 package
架构，不下载或扫描 feeds。LuCI package 仅包含插件宿主、传输适配、菜单和 ACL，
使用标准 OpenWrt `package.mk` 显式安装这些文件，不依赖 `luci.mk` 或 LuCI host build
dependencies。准备完成的 SDK 才能交给 package builder，因此首次发布不承担无关 feed
clone 和 package index 成本。
这些 package 只有脚本、静态资源与官方预编译核心，定向构建使用 SDK 的 `NO_DEPS=1`，
不重建整套内核模块；APK 的运行依赖仍完整保留，由设备包管理器从签名 feed 解析安装。

GitHub candidate workflow 必须先把用户选择的 `source_ref` checkout 为一个精确提交，再以
该 checkout 的 `HEAD` commit/tree 构建；workflow event 自身的 `GITHUB_SHA` 不能冒充
package source。workflow 只产生短期候选，不直接创建 Release。候选必须在同一 commit/tree
的干净 ARM64 OpenWrt VM 中通过候选目录提供的临时 feed 和同一 bootstrap 完成签名安装及
重复升级事务，再完成数据库回读、installed bytes、LuCI/RPC、首次设置、
退出恢复和卸载验证，之后才允许发布入口创建不可变 Release。发布入口重新读取远端主线，
只接受已被该主线包含的候选提交；后续无关提交不要求重建已经通过资格验收的同一候选。发布完成后必须从公开 Release
重新下载全部文件，校验文件集合、逐文件摘要以及 manifest 中的 source commit/tree，才可
报告发布成功；已有 Release 不允许覆盖资产。VM 的 HTTP feed 覆盖只允许用于本机受控资格
验证，公开安装入口默认只接受 HTTPS。NetFleet 的 `noarch` 代码包可跨 CPU 架构复用，
核心依赖仍按其真实架构匹配，发布验收以 manifest 中记录的 SDK 构建目标为准。

术语固定：OPL Instance 是用户私有 desired-configuration 权威；deployment bundle
只是从该权威生成、供部署器消费的四文件产物，不是第二个 Instance，也不得手工维护。
当前 CLI 的 `--instance <dir>` 是既有参数名，只读取 deployment bundle。

deployment bundle 只服务于多设备 Fleet、精确复现或需要预先声明平台参数的运维场景，由本机私有 renderer 准备：公共 provider/subscription/platform 声明与
命名 target overlay 合并，并在本机秘密边界内生成部署器现有的
`policy.json`、`subscriptions.json`、`nikki-mixin.yaml`、`platform.json` 四文件。公开仓库
不定义实际 target 名称、数量、地址或拓扑；共享机场、policy、能力和地区与 target-local
身份、网络和上游 DNS 差异由 private Instance 分别拥有。Nikki 后端仍由 Nikki 拥有订阅
URL/token、下载、缓存和 metadata，NetFleet 调度官方 refresh；原生后端使用 NetFleet
自有订阅路径，两者不同时维护同一份运行输入。渲染结果仍交给 canonical deploy
owner 完成校验、snapshot、compile、activate、rollback 和 target-local
readback。部署器可从已校验的 package 目录或 GitHub Release 本机缓存读取同一代码
载体；目标端按 `apk/opkg` 安装，声明式路径仍由同一部署事务负责 snapshot、compile、activate、
rollback 和 owner readback。代码包与 deployment bundle 相同重放时不得刷新订阅或切换数据面；
跨目标只复用 package，不复用设备状态。

部署性能合同：package 模式必须在一次包管理器事务中安装完整 NetFleet 产品集合，
避免重复进程、锁和依赖解析；host 部署器必须输出准备、传输加目标事务和总耗时，
这些指标只用于运维观测，不参与选择或激活决策。重复部署在身份和文件校验通过后
直接返回 `already_installed`，不得重新安装 package。

### 插件与内核更新

独立插件更新只替换该包。包钩子先关闭调用准入、排空使用该代代码的在途调用，再允许
包管理器写入；持有资源的插件通过自己的 drain/resume 接口完成交接。多个包共同影响
同一资源 owner 时，只保存一次恢复状态，待全部相关包替换完成再恢复。普通诊断、页面、
编译或选路插件更新不执行全产品升级事务；涉及常驻网络 owner 的代码则按真实依赖完成
退出、恢复与回读。插件私有配置和数据不由包管理器代写。

内核自身更新先保存已安装插件名单并批量排空，再取得内核代码独占租约。替换标记
阻止新调用读取半套文件；新内核安装后恢复插件，supervisor 下一次调度加载新的内核。
从单体包迁移时，内核 pre-install 在旧实现完整时停止旧服务并确认清理，再由默认产品
聚合包恢复原运行意图。旧目录随原包更新删除，不提供退役模块的运行别名。

源码部署采用同样的代码准入和资源交接。默认组合拥有的插件随源码集合替换，另外安装的
插件目录保留；写入失败先恢复旧代码，再使用旧 owner 恢复状态。代码升级不要求重新生成
deployment bundle 或刷新订阅。实际耗时以目标机包管理器与 owner 回读为准，完整 VM
qualification 时间不是设备升级耗时。

## 运行后端、网关与迁移

后端选择和 namespace 见[产品对象](../architecture/domain-model.md#后端与订阅归属)。两种后端
共用下文的 compiler、activation 和选择合同；`mihomo.backend` 是 Profile、
服务启停和运行回读边界。Nikki 模式调用官方服务；原生模式由
`mihomo.gateway` 与 `opl-netfleet-core` 管理，不增加第二控制器。生命周期命令通过
`main.uc native-gateway-*` 进入内核，再路由到 gateway 服务。

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

`mihomo.interception` 为可选协议插件提供受限 TCP 接管服务。插件提交固定服务实例与
低权限账户声明，以及来源地址、目标网络和端口；接口拒绝脚本、路径、路由或 nft 命令。
当前后端只有一个透明 TCP 槽位，监听 18443、回环验证端口 18445，第二个 owner 请求
同一槽位时拒绝，不能替换已有 owner。接管限定于实际 LAN 接口，最多 4096 个双栈
地址/目标/端口组合；来源必须是单一非回环、非组播、非链路本地地址。

网关独立验证原生选路等价性、真实 procd PID、监听 socket 所属进程和低权限 UID，
并将核心配置、UCI、ownership 与进程启动身份绑定为 epoch。申请和续期需要持有真实
全局网络锁，旧 epoch 不能续期。nft 生成和写入属于该网关服务，最长十秒的内核许可
只选择新连接；已有连接由 conntrack 保持归属。接管准入与 nft 原子事务由 ucode 网关服务
执行，不依赖 Python；基础网关启动、观察与清理也不依赖协议插件的存活或响应。
基础清理直接撤销该槽位接管并继续清理自身 DNS/TPROXY；插件自己的健康循环负责是否
请求许可，不获准修改基础 Profile、DNS、默认路由或核心生命周期。

`mihomo.lifecycle` 持有该插件的更新交接：先保存原运行状态、Profile、可见选择和
supervisor 状态，再退出核心及生命周期实例并回读清理；恢复时验证同一配置身份，
恢复原运行状态与选择。交接失败保留恢复所需状态，由[微内核维护流程](../architecture/microkernel.md#热替换与资源)
控制后续代码替换，不能在 owner 尚未退出时删除其实现。
Nikki 已运行独立原生 Profile 时，交接只暂停 NetFleet supervisor 并回读 Nikki 身份，
不停止或重启 Nikki；永久卸载在退出完成后删除本插件的临时交接记录。

网络表单、配置备份恢复和显式核心维护同样进入上述运行 owner，不直接写生成的
nft/路由对象。network owner 先校验候选配置，再保存旧声明和运行选择，调用原生服务
应用并回读；maintenance owner 的重启、重载及备份恢复也保留用户选择并验证网络，
失败恢复原文件和运行状态，无法证明恢复时停止核心并执行正式清理。Zashboard 资源
更新只交换经校验的静态目录，不重启核心或修改连接凭据。各事务的输入与持久化范围见
[设备独立管理](../architecture/management.md)，不得由 UI 另建恢复路径。

### 首次设置与迁移

`setup.native` 为空白设备提供 `native-setup-get`，只读检查依赖、现有 owner、私有配置和可达上游 DNS。
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

## OpenWrt 运行模式

`activation` 的 `set-mode` 使用 `openwrt`、`mihomo`、`netfleet` 三个值，分别映射共享运行合同的直连、原生代理与增强代理。请求绑定当前模式、代码 revision、写权限和网络锁；重复选择已确认模式不重启核心。两个原生模式先排空 HTTPS 引擎、禁用其自启动；失败不得报告模式切换成功，规则和证书保留。增强模式不自动重启该增强插件。
候选组缓存重置通过 Mihomo 官方 DELETE 接口执行。瞬时连接失败或服务暂不可用允许一次幂等重试；认证、缺失组及不支持的请求直接失败，不跳过失败组继续激活。失败详情保留候选组、HTTP 状态、传输错误码和尝试次数，禁止仅以通用重置错误丢弃断点证据。

## 故障清理与就绪检查

- 基础 gateway 清理必须尝试撤销全部自身接管。可选 HTTPS 表删除失败要独立报告，
  不能提前返回而跳过基础 DNS、TPROXY 和策略路由清理；基础清理成功也不能伪报
  尚未确认的 HTTPS 清理成功。

LAN ingress 以 effective `allow_lan`、TCP/UDP `7892` wildcard listener 和所选后端 nft TProxy rule 为准；DNS 接管以 effective `dns_enabled`、TCP/UDP DNS listener 与所选后端要求的 DNS redirect chains 为准。原生后端还通过进程内 UDP socket 在一秒内查询自身 DNS 端口：gateway 在生成配置中为保留命名空间 `health.opl-netfleet.invalid` 添加 `+.health.opl-netfleet.invalid: rcode://name_error` nameserver policy；该高级规则不进入用户可编辑的精确域名列表，TXT 查询经过正常 DNS resolver 并在本地返回 NXDOMAIN，不访问上游。探针校验响应 ID、问题与完整报文，只把该预期应答当作本地处理链健康；它不代表外部域名解析或业务成功。Nikki 后端仍使用保护探针域名经路由器 resolver 的解析证据。一次 backend 回读共享 `/proc/net` 监听快照和 nft table 快照，并直接调用既有 gateway service，不启动第二个宿主进程，也不复用跨轮缓存。

原生健康读取从 procd 回读核心命令身份，并复用本次 nft 表快照核验 DNS/TProxy；状态页不为就绪判断重复计算完整配置摘要。显式 gateway 状态仍提供配置摘要，观察之间不缓存健康结果。

## 平台服务绑定与宿主

首次设置由 `setup.native` 持有，后端迁移由 `setup.migration` 持有；两者只负责本平台输入、运行基线与交接，成功后调用共享 onboarding、编译与激活服务，失败恢复原状态。

默认安装组合按能力划分包边界。`selection-algorithm` 独立提供选择算法，仅依赖纯模型；
`selection` 提供控制流程和选路轮次。`platform` 提供运行描述、路径、进程调用和服务管理；
`platform-storage` 提供文件、JSON/YAML 存储与产品文档，拥有 yq 依赖；`platform-openwrt`
提供 UCI Profile、凭据、订阅事实和设备状态，拥有 UCI、ip-full 及默认 UCI 配置。
安装算法和模型不会拉入 Mihomo、UCI 或平台包。

`mihomo.profile-storage` 共享 Profile 引用解析、生成文件和 provider link 生命周期；
OpenWrt 与 macOS 后端组合该服务，各自只持有平台核心启停与网络回读。
订阅来源配置快照的位置由 `platform.runtime.SUBSCRIPTION_CONFIG_PATH` 提供；
OpenWrt 对应实际 UCI 文件，其他平台的存储机制见对应平台文档。

上述能力涉及的 UCI 字段、WAN/路由探测和 CLI 路径封装在对应提供者中。共享选择控制器依赖
profile、credentials、documents 和 paths；调度器通过 process 调用业务动作，不直接拼接
OpenWrt 安装路径。文件工具不会因读取 JSON 而加载凭据、订阅或 UCI 实现。

## 内核宿主适配

宿主通过 `options.adapter` 注入路径、信任身份、进程调用、包查询、文件摘要、mutation 锁
和协调者身份方法。共享内核不读取 `/proc` 或调用包管理器；OpenWrt 的 main/supervisor
入口加载 `adapters/openwrt.uc`，适配器保留实际祖先进程锁验证。平台适配器承接进程执行，
统一进程插件模块校验响应信封、输出大小与生命周期回读。

平台能力解耦与完整宿主移植分别验证。Linux 代码租约、进程身份、APK/procd 生命周期
及 DNS/TProxy 接管属于 OpenWrt 宿主实现。[macOS MVP](macos.md)通过独立适配器提供
当前用户的真实文件锁、进程身份、核心和网络生命周期；不加载 OpenWrt 平台服务。
订阅持久管理、后端设置及维护等 OpenWrt 专用服务仍包含 UCI 和本机操作。
跨平台产品方向见[设计白皮书](../product/whitepaper.md)，插件开发使用同一服务声明与绑定合同。

## 管理接口与浏览器宿主

### 原生接入与管理

功能服务插件和进程插件统一使用内核自带 `opl-netfleet.plugins` ubus 对象的
`plugins_list`、`plugin_read`、`plugin_call`。清单只发现安装文件，读取和写入分别授权；
请求为 `{request:{id,action,instance?,revision?,confirm?,params?}}`，写入必须携带当前
revision 和明确确认。组件页管理已安装插件的加载、重载、退出及声明的自定义动作。
服务插件的 `actions` 将业务动作绑定到本插件服务方法，进程插件由 `control` 执行动作。
`configuration` 引用自身配置动作，`ui` 贡献页面；清单按已配置实例投影这些声明，
浏览器不能提交模块路径或即时绑定。默认产品既有业务 RPC 继续由功能插件在
`opl-netfleet` 对象提供，通用插件管理不依赖该业务对象。
内核包和状态插件包在文件替换与插件恢复完成后刷新 `rpcd` 注册，使实际 ubus 方法与已安装接口一致；该刷新不重启代理数据面。执行插件的请求签名使用 JSON 对象占位 `"request":{}`，由 rpcd 按值类型注册为 ubus Table，保留嵌套请求内容。
状态与私有配置由插件持有；进程插件回读 loaded/ready，服务插件回读启用状态与绑定依赖是否可用。
包管理器专用 `plugin-drain` 与 `plugin-package-*` 不暴露给 RPC。
同一管理对象提供 `system_get`、`system_validate`、`system_apply`，均要求写权限，避免
向只读会话泄露可能含凭据的实例配置。后两者接受 `{request:{revision,config,confirm?}}`；
apply 必须明确确认。组件页的“服务组合”先读取私有覆盖、校验依赖并预览影响，再应用。
输入限制为 64 KiB；编辑后的配置不能沿用旧预览，过期 revision 必须重新读取。
服务组合编辑器按默认与具名实例展示插件开关和服务提供者选择；默认值、有效绑定与
可选提供者由同一管理 owner 返回。表单和高级 JSON 编辑同一份待提交私有覆盖，
实例继承通过删除局部覆盖表达；界面不自行解析依赖或保存另一份组合。
接口及安装切换合同见[模块与扩展](../architecture/extensions.md)和[微内核合同](../architecture/microkernel.md)。

原生后端的可选 [HTTPS 兼容模块](../architecture/https-compatibility.md) 使用上述通用插件接口。
自身 manifest 声明配置、启停、探测、公开 CA 和独立管理页面，内核将请求交给
`https-compat.control` 服务，再调用组件 controller；该 controller 复用现有 mutation lock，不运行全局配置应用。
返回值区分用户意图、实际接管、旁路原因、配置 revision 和验证结果。组件缺失时读取
返回未安装，基础管理页仍然可用。公开 CA 下载需要 LuCI 读取权限，信任记录与接管
变更需要写权限；浏览器不能下载 CA 私钥。
组件页按插件的 `configuration` 和 `ui` 声明提供配置跳转，不硬编码插件 ID。

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

### 独立设备管理接口

管理对象与恢复边界由[设备独立管理](../architecture/management.md)负责。
`network_get` 按需返回当前
原生网络配置、revision 和已有接口资源；`network_validate / network_apply` 接受
`{revision,settings}`，其中 `settings` 分为 `dns / lan / router / listeners / advanced`。DNS 包括
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

### 当前运行接口

`product-pages.js` 负责页面生命周期、读取和写入交互；`product-views.js` 负责状态渲染，`management.js` 与 `advanced.js` 负责配置表单。它们属于同一个产品 UI 插件，不独立保存业务状态。
LuCI 服务菜单直接打开宿主视图，只显示一条产品主导航；已有 overview 深链接打开同一视图，不另生成同名导航标签。宿主不重复显示 NetFleet 品牌标题，页内标题与刷新、选优及 Zashboard 共用紧凑工具栏，版本详情归基础组件页。
默认产品页面按插件 revision 共享资源工厂的下载和编译结果；切页重新创建页面绑定、
权限守卫与作用域。加载失败允许重试，取消一个页面不取消其他页面共用的资源请求。
私有配置与 API 响应不进入这个工厂缓存。

`status.runtime.backend` 返回当前后端的 `id/display_name`，`backend_enabled` 表示其服务
启用状态；配置投影的 `backend` 来自同一 owner。UI 不保留 Nikki 专用状态字段别名，
恢复文案使用实际后端名称，不能把“NetFleet 原生后端运行”描述成 Nikki 运行。

`status.operating_mode` 是[用户运行模式](../architecture/runtime-and-recovery.md#用户运行模式)的只读投影，
未知或不一致时为 `null`。概览使用三项单选与切换按钮；`activation` 插件的 `get-mode`
返回同一运行判定，`set-mode` 接受 `{mode, expected_mode}`。写请求通过 `plugin_call`
绑定 default 实例、插件 revision 和确认；模式过期时拒绝写入。成功或失败后都重新读取
设备状态，超时不自动重试。服务自启动与实际运行均须满足所选模式，缓存不授权切换。

root CLI 的管理动作与 RPC 经内核路由到相同功能服务：`subscriptions-get/set/refresh`、
`native-setup-get/apply`、`migration-get/apply`、`network-get/validate/apply`、
`maintenance-get`、`profile-get/save/delete`、`backup-export/restore`、`core-action`、
`diagnostics-get` 和 `dashboard-get/check/update`。涉及私有结构化输入
的 CLI 读取设备私有文件，不通过命令行参数传递订阅地址。核心启停和网关配置由
[正式运行 owner](openwrt.md#运行后端网关与迁移)负责，浏览器不直接调用
gateway 的准备、附加或清理动作，不建立第二条核心生命周期。原生 init 与首次设置使用
内部 `subscriptions-update-result` 命令更新尚未进入运行应用事务的来源；运行中被引用的
订阅仍须经 `refresh.control`，不能借内部入口绕过刷新恢复合同。

LuCI 的默认产品界面插件是这些业务接口的公开 caller，除上述接入与管理接口外提供：

- `status`：一次读取 policy、manifest、最近一次 evidence、服务状态、package 自有 build identity（source 部署时回退部署器原子持久化身份），以及 Mihomo `/proxies` 和 `/providers/proxies` 各一次；安装身份只投影经过格式校验的 NetFleet 版本、source commit 和 source tree，供用户确认当前设备字节并用于静态资源缓存失效，不参与运行决策；`apk upgrade` 后 package identity 必须优先于可能仍属于上一次声明式部署的 `installed.json`，避免状态页继续报告旧代码；当前已承载流量的 capability 以健康的生成 URLTest 组、组内当前成员和 manifest 绑定 source 中唯一的真实代理身份投影当前叶子，下一轮候选使用指定测速 URL 的独立健康记录，`/providers/proxies` 的节点全局 `alive` 只用于机场/地区库存健康显示，不能用可能滞后的单节点健康位推翻当前组和独立 protected probes 已证明的实际路径；机场节点库存按 manifest 绑定的 source 从 `/providers/proxies` 读取、按节点名去重并独立投影 `available_node_count/node_count/node_count_known`，不能把跨 capability 的地区候选组 `available_count/candidate_count` 标成节点；同一读取还经 SubscriptionOwner 投影顶层 `subscriptions`：每个已启用订阅只返回 `section`/`ref`、`display_name`、`cache_present`、`cache_sha256`、原始 `node_count`、`quota`、`last_attempt`、`last_success` 和 `last_result`，用于解释订阅条目与 Mihomo 已加载节点的差异；`last_success` 优先取最近一次 NetFleet 成功刷新事件，尚无事件时回退到设备上当前后端订阅缓存的实际修改时间，不使用测量时间或摘要推断；机场投影通过 `subscription_section` 明确引用对应条目，UI 不按显示名猜测绑定；不得返回 URL、token、节点名称或订阅正文；本轮候选的测量和排除结果以 [measurement](../architecture/evidence.md) 投影，历史延迟不能冒充本轮结果；该读取不测速、不探测、不修改 selector；
- `events`：读取有界 NetFleet 决策事件和当前后端 core log 中最近的 `NETFLEET-` 行，字段为 `core_lines/core_lines_persistent`；不轮询、不修改 owner；
- `probe`：执行与设备 owner CLI 相同的一轮有界保护探测并返回真实结果；只读网络状态，不刷新订阅、不测速选优、不修改 selector、Profile 或服务；
- `enable`：在同一个 target-local mutation lock 内依次调用现有 `compile -> enable` owner；原生核心完全停止时由 activation 复用恢复 owner 建立已验证基线，再启用候选。实时状态仍提供启动入口；不接受浏览器上传的 policy、Profile 或候选；
- `select_auto`：只接受 status 已公开且当前可执行的 automatic 根 capability ID，调用现有 `select <capability> auto` owner 执行一次有界轮次，并把可见 selector 恢复到“自动选优”；
- `refresh`：不接受 URL、section 或订阅内容，只调用同一个 policy-driven refresh owner；来源凭据修改由独立 subscriptions_set 完成，浏览器不解析订阅内容；
- `disable`：调用与 CLI 相同的 native Profile owner/runtime 恢复并独立返回 `business_ok`；只有 runtime 无法恢复时才转入官方 cleanup passthrough，并返回 `safe`、`persistent`、`business_ok`。

### 浏览器宿主与读取边界

LuCI 入口是插件页面壳，通过共享 `plugin-host.js` 从安装清单组合导航，加载插件的
`mount(context)`，并在切页、更新和卸载时关闭旧作用域。React/Vite 的
`PluginApplication` 使用同一宿主模块；注入具备插件 API 的 client 时按清单加载页面。
`ui/` 同时保留本机实时只读和脱敏 fixture 参考开发入口，这些参考组件不作为设备部署产物。

默认设备的概览、出口、机场、地区、配置、插件与更新、诊断由 `product-ui` 插件
贡献，页面源码和静态资源随该插件分发。其实现复用原生 LuCI 组件，生产宿主不强制第三方
采用某个界面框架。Zashboard 在产品工具区提供独立外链；配置页把网络接入和配置文件
与备份作为独立管理分区，不混入 policy 草稿的应用按钮。首次设置向导复用适用字段组件。
视觉语言、主题与组件规则由[UI 设计合同](../design/ui.md)负责。

LuCI 壳与 React 插件宿主每五秒读取插件清单，以发现安装、启停和 revision 变化；离开
宿主时撤销该读取。清单发现只读安装元数据，不执行业务状态读取、网络探测或插件代码。
插件页面的业务请求仍由各页面管理，清单刷新不触发默认产品的 status 轮询。

实时只读桥接的目标只从本机环境变量取得，只允许固定读取 `status`、`events`、`config_get`、`connections`、`components_get`、`operation_get`、`network_get`、`maintenance_get` 和 `diagnostics_get`，浏览器不持有 SSH 凭据，也不能通过该桥接调用任何 mutation；桥接结果必须显示目标、连接状态、最后读取时间和读取耗时。组件、网络配置、文件清单和核心日志按需独立读取，不并入常规网络快照。网络投影隐藏解析 URL 的凭据和私有路径，不返回认证密码；文件清单不包含正文或备份。`connections` 只在用户打开或刷新“诊断 → 网站诊断”时从 Mihomo 当前 `/connections` 读取最多 50 条活动连接，投影目标 host/IP、目标端口、网络、命中规则、规则载荷和实际代理链；不得返回 source IP、进程、连接 ID、流量计数或其他不必要字段，也不得写入事件 owner、fixture 或浏览器展示缓存。该诊断使用 Mihomo 已执行的真实首条命中结果，不在 NetFleet 或浏览器中重做规则匹配。事件页以 NetFleet 持久化选路事件为主，活动连接只在网站诊断分栏的辅助区显示；瞬时连接快照不能累计或外推为规则组触发频数，除非未来真实 owner 提供可去重、可定义生命周期的持久计数。fixture 仅用于离线、异常和边界场景，可在内存中模拟命令后的投影变化；它必须遵守当前接口形状且不得包含订阅、完整节点清单、设备地址或其他私有 target 数据，不是运行事实，也不能被生产 LuCI 页面读取。

#### Dashboard 打开与资源版本

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
清理缓存。文件布局与版本归属见[软件包合同](openwrt.md#软件包组合)。

NetFleet 沿用 Nikki/Zashboard 的带凭据新标签页连接方式，controller secret 只用于本次
URL 构造，不得进入 NetFleet status、日志、展示缓存或文档。Zashboard 保留上游完整功能；
其中 selector 切换、连接关闭属于 Mihomo 当前运行态，不替代 NetFleet 的持久配置、订阅
编排、启停和恢复 owner。两种后端都保持独立完整页面，不嵌入或复制控制器。长期定位见
[设计白皮书](../product/whitepaper.md)和 [Zashboard 决策](../decisions/0005-zashboard-observation-surface.md)。

#### 展示缓存与操作授权

已配置的默认业务页面首次挂载各读取一次 `status` 和 `events`，后续按页面进入、用户
刷新和操作完成读取，不建立全局 status 定时轮询。插件清单的五秒发现周期、运行中操作
的进度读取与业务状态读取分别管理；supervisor 周期不触发浏览器业务请求。
`connections` 不随页面首次加载或展示缓存刷新读取。

LuCI 的启用、单次选优、立即更新订阅、关闭和配置应用都必须二次确认，mutation 完成后重新读取 owner 投影。这些网络操作由 rpcd 调用 one-shot UCode owner；软件包更新由下述一次性后台事务执行。React 的实时设备桥接始终只读；React 配置页、向导、保存、校验和应用按钮只能改变浏览器内的本地预览草稿，必须持续标明“不会写入设备”，不得转发任何配置或 mutation 到 SSH bridge。浏览器不解析订阅、不实现编译、排序、候选资格、回滚或探测逻辑；生产按钮是否可用来自实时 owner 投影，浏览器缓存只能延续显示，不能延续操作授权。事件 owner 仍返回有界事件窗口，LuCI 的“选路事件”在这个窗口内按最新优先每 20 条一页展示，刷新后回到最新一页；分页不触发额外设备读取。所有涉及网络的 LuCI mutation、supervisor 网络动作和设备部署使用同一个短生命周期 lock，不能形成并行网络 writer。仅访问插件私有数据的服务动作可使用插件锁，与组合及备份事务的数据租约配合；锁与实例合同由[微内核](../architecture/microkernel.md#作用域与实例)统一定义。

### 组件与操作进度

`components_get.extensions` 由 `components.control` 使用内核清单投影插件安装版本、
代码 revision、服务与页面声明、实例、启用状态、接口 major 和依赖；`runtime` 区分 `service` 与 `process`。
它不表示运行健康，不触发网络检查或启动引擎；Zashboard 的资源状态
仍复用同一 `dashboard` 读取，避免重复探测。HTTPS `get` 额外投影 `managed` 和
`management_reason`，不兼容时禁止新接管和编辑，保留关闭与排空。

RPC 是调用设备 owner 的薄适配器，不维护第二份网络状态。`components_get` 只读已安装组件、
实际运行核心版本、关键依赖、最近一次 Feed 检查及独立的 `dashboard` 资源状态；`components_check` 与 `components_update`
分别启动显式版本检查及固定组件、固定版本的后台更新。`components_recover` 显式启动已有中断事务的恢复，复用开机恢复入口和同一全局锁，不创建新更新。更新流程见[软件包合同](../architecture/packaging.md)。
`dashboard` 不作为 APK 包：`installed_version` 来自有效安装记录或本地资源识别，两者均
无可靠证据时才返回 `null`；识别规则见[设备独立管理](#规则与运行面)。
`dashboard_check` 显式查询官方
Release 并缓存候选，`dashboard_update` 接受用户确认的版本，绑定该候选的官方 HTTPS
资产与摘要执行有界资源事务。两者都不随组件页读取自动执行，也不重启核心；资源事务
和恢复合同见[设备独立管理](#规则与运行面)。
`operation_get` 返回运行模式切换（`mode`）、配置应用（`configuration`）、订阅、选优和组件操作的最新进度：标识、状态、阶段、开始/更新时间、已处理数、
总数、当前对象显示名、脱敏错误码及恢复结果 `recovery`；选优子操作的 `parent_id`
由订阅更新执行者传入并绑定本次订阅操作标识，独立选优为 `null`。UI 只合并身份匹配的
父子操作，以“机场订阅更新”显示下载、测速选优、运行确认及最终结果；测速阶段在该条
反馈内显示子阶段和出口进度，不再重复显示独立测速框。独立选优保持自己的反馈；父操作
仍运行时不得以子操作完成冒充整个更新完成。
模式切换复用同一操作 owner，记录 `requested_mode` 和经运行回读确认的 `actual_mode`；实际模式不可确认时为 `null`。执行者按检查、暂停周期任务、准备配置、重载核心、清理候选状态、测速、逐出口选优、网络验证和恢复的真实步骤更新进度。失败终态保留原始错误及恢复结果（`native`、`direct`、`failed` 或 `unchanged`）；页面收起不取消执行，连接中断后先读取同一操作与当前模式，不重复提交。
恢复结果区分已恢复、恢复失败和网络直通，未发生恢复时为 `null`，不能把恢复成功当作原操作成功。不返回 URL、凭据、命令
输出或无限增长的操作历史。
订阅下载、校验、编译、重载、选优、探测和回滚阶段由实际执行者写入；没有内容变化时直接
返回真实结果，不伪造后续阶段或百分比。执行进程消失但没有终态时显示中断未确认，不冒充成功。
初次加载与进入机场、组件页时读取一次当前操作；只在存在运行中操作时每秒读取独立进度，
结束后停止轮询并刷新受影响的数据。操作标识绑定执行结果，旧操作终态不能确认新请求完成。
成功结果仅在会话跟踪过该操作时短暂显示，通知生命周期见[界面设计](../design/ui.md)。
终态结果可在浏览器会话内关闭；此显示偏好不修改 operation owner，不取消执行或隐藏当前
运行故障。完成时间使用设备 `finished_at`，缺失时不得把当前读取时间当作完成时间。

### 首次设置与策略配置接口

未配置设备额外暴露 `onboarding_get / onboarding_apply`。`onboarding_get` 只读当前后端
Profile、稳定 subscription cache 和节点地区，返回脱敏预览、阻断原因及绑定发现 revision；
不得返回订阅 URL、token 或节点正文。`onboarding_apply` 必须携带同一 revision 和显式确认，
在全局 mutation lock 内重新发现并拒绝漂移，然后由 `configuration.onboarding` 写入初始
policy，复用编译和激活服务、启动 supervisor 并回读。已有有效 policy 时 onboarding 接口只返回
`required=false`，不能覆盖现有配置；失败时必须恢复原生 Profile、服务状态和本次创建的文件。

设备端配置由 `config_get / config_validate / config_save / config_apply` 四个结构化 RPC 暴露。浏览器每次配置操作先读取 fresh `config_get`，并携带 policy SHA-256 revision；陈旧 revision 必须拒绝，展示缓存不得授权配置 mutation。唯一 target-local 配置 owner 发现当前后端已有稳定命名订阅、订阅 cache 中可识别的地区、当前 Policy Source 策略组和内置 Policy Source，把白名单结构化选择 merge 到现有 canonical policy、校验全部引用，并用同目录临时文件原子替换。`config_save` 只允许在 NetFleet 未接管时更新 policy，不改变数据面；active 配置必须使用 `config_apply`，后者先返回可解释变更供 LuCI 二次确认，再在全局 mutation lock 内快照旧 policy/artifact/manifest，复用 `disable -> compile -> enable` activation owner 切换，失败恢复旧字节和旧 active owner。

policy 配置 owner 不接受 raw policy、订阅 URL/token、节点正文、DNS/nft 命令、浏览器生成的 Profile、自定义 provider cache 路径、自定义地区正则或 quota metadata 映射。订阅凭据单独提交给 subscriptions owner，不混入 policy；原生 DNS、代理范围和监听设置通过独立 network owner 的受限结构编辑。配置文件通过 maintenance owner 校验，不能借文件导入建立另一条配置应用链。OpenWrt flow-offload、WAN/LAN 地址和任意防火墙参数不属于这些管理表单。

### 请求时限与显示分工

配置应用复用同一同步事务，依次记录校验、快照、退出旧配置、写入、编译、启用与运行检查、
最终回读及必要回滚阶段；进度记录不包含配置正文。收起弹窗或切换页不取消已提交请求，
新页从同一 `operation_get` 恢复跟踪；浏览器断开后以设备执行者身份与终态为准。

LuCI 同步 mutation 与 rpcd/uhttpd execution timeout 使用 300 秒有界预算，覆盖启动收敛、测速、owner readback 和必要回滚；成功路径不会等待到上限。package post-install 和 deployment owner 都只在 rpcd 或 uhttpd 当前上限低于 300 秒时提升到 300，保留更高值并重启、回读 RPC surface，deployment owner 还必须把 `/etc/config/rpcd` 和 `/etc/config/uhttpd` 原字节纳入同一部署回滚。不得通过后台 worker、第二选择器或伪造提前成功规避这个 owner 事务。

事件与显示聚合见[显示证据](../architecture/evidence.md)，生成拓扑见[编译合同](../architecture/runtime-and-recovery.md#compiler)。

字段的用户解释、库存计数、空态和展示排序由[状态呈现](../architecture/ui-state.md)维护；
历史聚合由[显示证据](../architecture/evidence.md)维护。

#### 手动地区操作

## 设备地址来源机制

本地来源接受指定接口上可确认到达的直连邻居，并从本机 IPv6 连接跟踪表发现候选
地址。候选 IP 不授予接入权限：插件在指定局域网接口发送有界的 IPv6 邻居请求，
使用有界原生 C helper 的 Linux 二层套接字收发与解析报文，核对目标地址、跳数 255、请求响应标志、校验和以及
以太网来源与目标链路地址一致。只有确认到已绑定 MAC 的地址才交给消费者。
同一地址出现不同 MAC 时撤销该地址；不得把中间网关 MAC 当成客户端身份。
每次最多验证 64 个候选，各接口最多等待 350 毫秒，不扫描地址空间，不读取业务正文。
候选轮换不延长旧证据寿命；重新验证失败的地址立即撤销。

跨路由部署需要让 NetFleet 的观察接口接到客户端局域网。虚拟机可使用已有局域网
网桥上的独立虚拟网卡；观察接口不承担转发，不配置默认路由、DNS、DHCP 或 RA。
插件不自行修改接口和拓扑，不依赖客户端任务或控制器账号。没有二层可达接口时，
不能从前缀、主机名或流量相似性推断单台设备身份，未确认的地址继续原路径。

## 网络配置与维护机制

### 网络接入

`network_get`、`network_validate`、`network_apply` 由独立设备网络配置 owner 提供，
不是 policy 的附加任意字段。LuCI 的配置页增加“网络接入”，管理 DNS 上游及精确域名
覆盖、LAN/本机代理范围、设备访问规则，以及必要的代理监听和认证。实际字段只投影
当前 gateway 消费的 UCI/mixin，不接受 shell、nft、路由表或 WAN/LAN 地址写入。

读取结果绑定当前私有配置 revision；校验和应用拒绝旧 revision。应用前保存原始配置及
当前运行选择，验证候选配置，再复用原生服务的重载或重启和 owner 回读；失败恢复原配置
与运行状态。已有未公开的 UCI/mixin 字段必须保留，不将少量表单值覆盖成整份默认配置。
尚无原生后端的设备显示不可用原因，不暗中修改 Nikki。

### 高级核心配置与生效解释

网络配置 owner 同时管理常用网络设置与高级 Mihomo 参数。高级设置覆盖 DNS 行为、
嗅探、连接与 GeoData；每项可显式覆盖或继承 Profile/核心默认值。读取返回参数定义、
配置值、来源以及实际运行配置中的值；核心默认值未知时明确标注，不猜测内置默认。
专家编辑使用同一组已声明参数的 JSON 对象，与表单共享草稿和同一校验、应用事务。
未知参数和网关持有的接管、监听、控制接口、生成出口及路由对象不能通过该入口写入。

参数修改在私有 mixin 中保存，同时移除该参数对应的旧 UCI 覆写，避免保存后被再次覆盖；
未修改参数和未表示的私有字段保持原样。恢复继承时删除本地覆写，由当前 Profile 或核心
默认提供结果。候选校验返回逐项配置差异和核心重启影响；应用后比较实际渲染结果，
不一致进入原有失败恢复事务。配置值与运行值分别展示，停止状态不宣称运行生效。
旧私有嗅探协议表继续按原有深合并语义处理；高级编辑器明确保存完整协议表时，在私有
mixin 中记录 `netfleet-replace-sniff`，网关据此替换该表并在输出核心配置前移除标记。

### 配置文件与维护

配置维护面负责本地 Profile 的导入、下载、删除与受控编辑；Profile 标识绑定原生私有目录，
不能接受任意设备文件路径。导入 JSON/YAML 必须经现有结构化转换及核心配置验证，
生成内容采用同目录临时文件后原子替换，使用中的文件必须经过完整应用事务或拒绝覆盖。

NetFleet 备份只包含自身声明配置、订阅来源、必要缓存、本地 Profile 与私有覆写；不包含
固件、整个系统配置、日志或进程状态。备份含凭据，只有经认证的显式导出才能获得，浏览器
不保存至 localStorage 或展示缓存。恢复必须验证格式、白名单路径、大小、对象引用与
当前运行身份，失败保留原配置；不能借恢复改写其他服务或系统网络。

组合备份同时保存私有 `system.json`、已安装插件的接口身份，以及
`/etc/opl-netfleet/plugin-data/` 下的私有持久文件。恢复前验证所需插件和所有实例的依赖图，
缺失或不兼容的插件会在写入前拒绝；不会从备份执行插件代码或自动安装包。插件代码由
签名软件包交付，插件持久数据使用上述统一目录，目录外的外部服务数据不由此文件备份。
网络备份旧格式仍可导入，导入时保留当前插件组合与数据。新格式恢复插件组合时纳入同一
原子写入、资源排空和失败回滚事务。

核心重启/重载仅调用已选择的 runtime owner。日志入口提供有界、脱敏的核心启动和运行
诊断，在 controller 不可用时仍可读取，不能依赖 Zashboard 才能排查启动故障。

### 规则与运行面

policy 的本地业务规则支持域名后缀和 IPv4/IPv6 CIDR，目标明确为 capability 或直连，
由同一个 validator/compiler 生成有序 Mihomo 规则。浏览器不解释规则匹配、不生成运行
配置。复杂上游格式留给受控 Profile/覆写，不新增通用规则语言。

Zashboard 继续为独立完整页面；“插件与更新”显示实际资源版本，优先使用与当前入口摘要
一致的安装记录；没有有效记录时，从入口引用的本地脚本识别 Zashboard 自身更新检查所用
的编译版本，不把依赖库版本或上游最新版本当成安装版本。识别过程有界、只读、不联网，
也不补写安装事务记录；不能识别的定制资源才返回未知。支持显式检查上游版本与确认更新。
资源事务由原生 owner 执行，保留旧资源用于失败恢复，
不重启代理核心、不修改其连接凭据，也不在每次打开概览时查询上游。

### UI 与验证

网络接入、配置文件与备份入口归配置页；核心维护和启动日志归诊断；Zashboard
发行管理归插件与更新。不增加并行后台循环，也不把七页导航扩展成每个操作一个页面。
React 本机参考面消费真实脱敏状态并允许本地草稿，秘密输入和所有设备写入只由经认证
的 LuCI 完成。新增 RPC 必须同步声明、ACL、包内容和真实调用测试。

修改配置、恢复或运行服务的候选必须先经完整 OpenWrt VM 验收，再在单独授权的真实设备
验证。VM 覆盖合法应用、旧 revision、非法输入、失败回滚、私有字段保留和停止后清理；
真实设备回读网络 owner、控制接口、DNS、透明代理及业务探针。


## 界面渲染与主题

生产界面使用原生 LuCI `view.extend`、`E()` 和 scoped CSS，不加载 React、组件库、远程字体
或额外运行时。React/Vite 是 OpenWrt 的只读参考面，两者按共享界面合同对齐语义与视觉，
不共享组件代码，也不要求逐像素一致。DOM children 必须平铺，测试不得递归展开数组
掩盖原生 E() 的字符串化行为。卡片标题清除 LuCI 主题额外 padding。

LuCI 壳与 CSS 使用同一界面包版本目录，插件业务资源按完整 payload revision 组织，
不能使用设备 runtime 版本代替界面版本，也不要求手工清浏览器缓存。

### 颜色与主题

设备端颜色从 LuCI 主题变量投影到 NetFleet token。优先级如下：

| 用途 | NetFleet token | LuCI 来源或默认值 |
| --- | --- | --- |
| 选择、焦点、主操作 | `--nf-accent` | `--primary` -> `--primary-color-high` -> `#5e72e4` |
| 浅强调背景 | `--nf-accent-soft` | `--primary-color-low` -> `rgba(94, 114, 228, 0.10)` |
| 正文 | `--nf-text` | `--text-color-high` -> `#202124` |
| 辅助文字 | `--nf-muted` | `--text-color-medium` -> `#5f6368` |
| 页面与容器背景 | `--nf-page` / `--nf-surface` | LuCI background token -> 中性灰 / 白 |
| 边界 | `--nf-border` | `--border-color-medium` -> 中性灰 |


### 面板入口条件

入口可用性来自同一次 status 的 Mihomo 运行、controller 可读和 `dashboard_lan_ready`；任一条件不满足时使用原生 disabled 状态，并在标题中给出最深可解释原因。Zashboard 保留上游完整功能，页面内临时选择、连接管理和其他 controller 操作按 Mihomo 当前运行态处理；NetFleet 自有页面继续独占持久 policy、订阅编排、服务启停和故障恢复。OpenWrt 的 React 参考面只预览入口的位置、状态和反馈，不持有设备 controller 地址或密钥，也不伪造可用的 Zashboard 页面。

Nikki 后端使用 Nikki 已安装的资源和 controller；原生后端由 NetFleet 管理资源和 controller。URL 由同一个 NetFleet 入口按当前后端返回的连接信息构造，两种后端保持相同入口和独立完整页面，不建立第二 controller。


### 原生管理控件

- 订阅管理：原生后端在认证后的编辑弹窗显示设备当前订阅地址、用量地址和 User-Agent；User-Agent 使用 LuCI 可自定义下拉框，提供 `clash / clash.meta / mihomo` 预设并保留自定义值。弹窗有独立样式作用域和可收缩控件列，不复用配置页的宽列最小尺寸；地址只在页面内存中使用，不写入浏览器持久展示缓存。Nikki 后端仍跳转其订阅管理页；
- 网络接入：原生后端显示 DNS 上游与域名覆盖、LAN/本机代理范围、设备规则、监听端口和认证。TProxy 为当前适配模式，不提供未经接管与恢复验证的模式切换；不把 WAN/LAN 地址、任意路由或 nft 编辑放入该表单。已保存的密码只显示配置状态，修改凭据使用明确输入；


### 首次接入交互

未配置设备不显示伪造的概览零值，也不因 `status` 缺少 policy 而整页报错。页面先调用只读
onboarding preview，显示识别到的原生恢复配置、机场数量、真实可用地区和将接管的入口组。
预检通过时主操作为“按推荐配置开始接管”，旁边提供“检查详细配置”；主操作必须二次确认，
明确说明会由所选后端应用运行配置并接管网络。预检不通过时逐项显示可行动阻断原因且不出现可用的接管按钮。
浏览器不解析节点或生成 policy，所有发现、revision 和事务结果来自设备 RPC。


## 后端与订阅命名空间


`/etc/opl-netfleet/backend.json` 是唯一后端选择，值为 `nikki-mihomo` 或
`native-mihomo`；缺省使用前者。选择器是 root 私有 JSON，不能通过普通配置保存
静默切换。安装软件包不启动数据面；切换必须进入显式迁移或首次设置事务。

| 运行边界 | nikki-mihomo | native-mihomo |
| --- | --- | --- |
| UCI namespace | `nikki` | `netfleet` |
| Profile、订阅与运行目录根 | `/etc/nikki` | `/etc/opl-netfleet/native` |
| Mihomo 生命周期 | Nikki 官方 init | `opl-netfleet-core` procd 服务 |
| mixin 与网络接管 | Nikki 官方实现 | 固定版本的 Nikki mixin/nft 模块，由 NetFleet gateway 编排 |
| 订阅编辑与下载 | Nikki；NetFleet 只投影并编排官方更新 | `subscriptions.store`，共用现有设备 mutation lock |

原生订阅使用稳定的 UCI `subscription` section，保留 `name/url/user_agent/info_url/prefer`
和额度、到期、更新元数据语义；policy 只引用 section ID，不保存凭据。缓存路径为
`/etc/opl-netfleet/native/subscriptions/<section>.yaml`，正文保存完整订阅的 JSON 对象，可供同一份编译输入、
恢复 Profile 和 Mihomo file provider 使用。目录 `0700`、私有文件与 UCI 配置 `0600`；
URL、凭据和响应头只经过私有输入文件，不进入命令行、公共状态、日志或 Git；经过认证的
订阅编辑界面可以读取当前来源地址，具体传输与缓存边界见[公开接口](#管理接口与浏览器宿主)。

编辑与运行应用分开：保存 URL/UA 不下载、不停服务、不替换当前有效缓存。来源身份改变后
投影为 `pending_update`；仍在使用旧有效缓存时标明 `using_previous_cache`，不能把它
标为当前新来源已接受。旧额度和最近成功时间属于该有效版本；失败更新保留这些事实。
删除必须同时检查 policy、当前 Profile 和 live file-provider 引用，任何真实引用仍存在
都拒绝删除。显示名变化不改变来源或内容身份。

下载支持 HTTP/HTTPS 与独立 info URL，使用系统 CA、私有 curl 配置、有界时间和大小。
完整响应经只读 YAML 转换和真实 `mihomo -t` 后才原子替换；相同内容不重写缓存正文或
mtime，成功时间与额度可以更新。缓存正文摘要与已接受来源身份共同决定
`cache_current`，不能仅凭文件存在声称新来源就绪。更新、重编译、恢复用户模式和失败
回滚由 `refresh.control` 负责，详见[运行事务](../architecture/runtime-and-recovery.md#activation)。

月重置日的语义归[订阅对象](../architecture/domain-model.md#后端与订阅归属)，OpenWrt 以订阅 UCI 字段保存。
