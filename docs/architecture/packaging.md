# 软件包与部署输入

本文是 versioned OpenWrt package、private OPL Instance 和 deployment bundle 之间边界的
权威合同。具体命令和当前可用入口由[根目录 README](../../README.md)负责。
Fleet 安装的前置检查、快照和回滚顺序统一由[部署事务](../operations/deployment.md)维护。

## 软件包组合

`opl-netfleet-kernel` 安装通用入口、服务解析、插件生命周期内核、OpenWrt 宿主适配器及
`opl-netfleet.plugins` 通用管理 RPC，提供 `netfleet-plugin-api-v1`。
`opl-netfleet-plugin-*` 分别安装功能插件的 manifest、实现和
该功能拥有的资源、配置基线或系统入口。`opl-netfleet` 是默认产品聚合包，安装
`system.json` 与构建身份，依赖完整默认功能集合；`luci-app-netfleet` 提供插件页面宿主，
只依赖内核及必要的 LuCI 运行环境。默认产品的七个业务页面归
`opl-netfleet-plugin-product-ui` 所有；独立插件的界面不要求安装默认网络产品。
进程插件与 UCode 服务插件使用相同的 `/usr/libexec/opl-netfleet/plugins/<id>/` 安装空间，
服务组合合同见[微内核与功能插件](microkernel.md)。

默认产品、LuCI、`product-ui`、`maintenance` 及当前 SDK 生成的插件包声明内核最低版本为 `0.8.1`，
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

## 版本化分发

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

## 设备端组件维护

LuCI 的“组件与更新”由设备包管理 owner 提供已安装 NetFleet、LuCI 和 Mihomo 的包版本，
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
包管理器负责依赖解析、签名与架构检查。写入前取得候选和旧版签名包，确认核心原子替换及
解包所需的可用空间；下载前先以签名索引的安装体积检查空间，取得候选包后再按包内元数据
复核，空间不足不得先停止健康核心。随后验证新核心能加载
现有配置；旧版无法取得时不停止正在工作的后端。更新复用当前服务 owner，保持私有输入，
失败恢复旧包和原服务状态，并回读控制接口、DNS/透明代理及保护探针。

包命令非零不能证明文件没有改变。组件回退按已安装版本、原运行代码摘要、私有配置和实际运行状态
分别回读；包安装或 world 恢复报错仍须尝试恢复已验证的旧运行面。无法恢复时再次
尝试基础网络清理，保留各阶段失败记录，不能在首个错误后跳过网络恢复。
恢复只补启缺失的服务；已经运行的核心和监督器继续工作，随后仍须验证配置、选路及网络状态。
该回退只覆盖组件更新入口；外部迁移执行器必须独立通过相同旧包组合与故障注入验证。

软件自升级会重启 rpcd，因此设备通过 procd 执行一个有界、无自动重试的一次性更新进程，
使用全局 mutation lock 和更新前暂存的实现完成事务；浏览器关闭或临时断连不取消更新。
这不是第二个网络 owner，也不拥有持久运行状态；页面通过只读进度接口确认最终结果。
组件更新的事务代码副本、候选与回退包、私有快照和阶段记录保存在 root 私有的
`/etc/opl-netfleet/package-transactions/`。写入前保存并同步恢复材料和 pending 指针，
组件事务 owner 才能停止服务与替换包。普通失败立即回滚；进程中断或重启后，由同一
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
原生路径由 NetFleet 维护订阅与其运行配置，具体边界见[运行与恢复](runtime-and-recovery.md)。
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
退出恢复和卸载验证，之后才允许发布入口创建不可变 Release。发布完成后必须从公开 Release
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

## 插件与内核更新

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
