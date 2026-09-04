# 软件包与部署输入

本文是 versioned OpenWrt package、private OPL Instance 和 deployment bundle 之间边界的
权威合同。具体命令和当前可用入口由[根目录 README](../../README.md)负责。

## Versioned package and deployment-bundle inputs

版本化 OpenWrt package 是 NetFleet 代码的可校验分发载体，绑定精确 source
commit/tree、package 架构、SDK 构建目标和 artifact checksum，只包含 runtime、supervisor、rpcd、
init 和 LuCI 页面。package 不包含 target-local policy、订阅、Nikki mixin、URL/token、
节点或 secrets；package 安装/升级不绕过 staged/activate 合同，也不自动替换当前
数据面或设备私有生成 Profile。runtime package 同时安装只读
`/usr/share/opl-netfleet/build.json`，以当前 package 的版本、source commit/tree 作为代码身份；
声明式部署的 `/etc/opl-netfleet/installed.json` 继续绑定 deployment bundle 和实例输入，但不能覆盖
较新的 package 身份。manifest v2 还绑定 package format、运行时文件摘要、
两个 package 文件和 APK 公钥（仅 APK）；APK 逐包签名必须使用本机私钥，私钥不进入
Git、发布目录或设备。没有真实 OpenWrt SDK 时，构建入口必须明确失败，不能伪造
package 或 manifest。APK 发布还包含同一私钥签名的 `packages.adb` feed index，并在
manifest v2 的 `feed_index` 字段绑定其 SHA-256。Release 同时包含 `install-netfleet.sh`，由
`feed_bootstrap` 字段绑定脚本名称与 SHA-256；该脚本下载公钥、原子写入公钥和
`/etc/apk/repositories.d/opl-netfleet.list`；仓库声明直接指向 `$feed_base/packages.adb`，使
`apk` 以 `ndx` 模式从同目录解析 package，而不是按目录型仓库扩展架构子目录。随后脚本在一次
`apk add --upgrade` 事务中安装两个
package。它不得写入 policy、订阅或 Nikki mixin，也不得启用 NetFleet 或切换数据面。
runtime 与 LuCI 均只包含脚本、配置和静态
资源，因此 OpenWrt package 声明为 `PKGARCH:=all`：APK 元数据中的实际架构必须是
`noarch`，而 `build_target_arch` 单独保留生成该 Release 的 SDK 目标，例如
`aarch64_generic`。部署器允许 `noarch` 安装到任意目标架构；旧 Release 的原生架构兼容
规则只用于读取既有产物，不能用于生成新 Release。Release 的
`latest/download/packages.adb` 可作为稳定仓库索引，目标机只需安装一次公钥并写入
`/etc/apk/repositories.d/opl-netfleet.list`，之后即可使用 `apk update`、`apk policy`
和 `apk upgrade`。feed 只拥有代码包，不拥有订阅、policy、Nikki mixin 或运行时数据。

独立插件模式不要求开发机生成 deployment bundle。目标 OpenWrt 已安装并配置好 Nikki、
当前原生 Profile 可用且至少一个稳定命名 subscription 已有有效 cache 时，安装两个 package
后由 LuCI 首次设置完成设备端发现和一键接管。package post-install 只刷新 LuCI/rpcd，并在
rpcd 当前执行上限低于 300 秒时提升到 300 秒、保留更高值；它不自动改变网络，用户确认后才由
target-local owner 创建 `/etc/opl-netfleet/policy.json` 并启用。
该模式复用当前原生 Profile 的规则、DNS 与策略组，不下载第二份订阅，也不需要内置 MRS。
`policy.example.json`、内置 Policy Source 和 ruleset lock 是 package 拥有的只读基线；APK
升级若为它们生成 `.apk-new`，runtime package 的 post-install 必须原子采用新字节。用户
policy、订阅、mixin、生成 Profile 和证据不在该名单中，package 不得借此覆盖。

官方 SDK 解压后尚未生成 `.config`。发布准备入口只执行 `defconfig` 并回读目标 package
架构，不下载或扫描 feeds。原生 LuCI package 仅包含仓库内固定的静态页面、菜单和 ACL，
使用标准 OpenWrt `package.mk` 显式安装这些文件，不依赖 `luci.mk` 或 LuCI host build
dependencies。准备完成的 SDK 才能交给 package builder，因此首次发布不承担无关 feed
clone 和 package index 成本。

GitHub candidate workflow 必须先把用户选择的 `source_ref` checkout 为一个精确提交，再以
该 checkout 的 `HEAD` commit/tree 构建；workflow event 自身的 `GITHUB_SHA` 不能冒充
package source。workflow 只产生短期候选，不直接创建 Release。候选必须在同一 commit/tree
的干净 ARM64 OpenWrt VM 中通过候选目录提供的临时 feed 和同一 bootstrap 完成签名安装及
重复升级事务，再完成数据库回读、installed bytes、LuCI/RPC、首次设置、
退出恢复和卸载验证，之后才允许发布入口创建不可变 Release。发布完成后必须从公开 Release
重新下载全部文件，校验文件集合、逐文件摘要以及 manifest 中的 source commit/tree，才可
报告发布成功；已有 Release 不允许覆盖资产。VM 的 HTTP feed 覆盖只允许用于本机受控资格
验证，公开安装入口默认只接受 HTTPS。当前 `noarch` Release 可跨 CPU 架构复用，
但仍只由 manifest 中记录的一个 SDK 构建目标生成和验证。

术语固定：OPL Instance 是用户私有 desired-configuration 权威；deployment bundle
只是从该权威生成、供部署器消费的四文件产物，不是第二个 Instance，也不得手工维护。
当前 CLI 的 `--instance <dir>` 是既有参数名，只读取 deployment bundle。

deployment bundle 只服务于多设备 Fleet、精确复现或需要预先声明平台参数的运维场景，由本机私有 renderer 准备：公共 provider/subscription/platform 声明与
命名 target overlay 合并，并在本机秘密边界内生成部署器现有的
`policy.json`、`subscriptions.json`、`nikki-mixin.yaml`、`platform.json` 四文件。公开仓库
不定义实际 target 名称、数量、地址或拓扑；共享机场、policy、能力和地区与 target-local
身份、网络和上游 DNS 差异由 private Instance 分别拥有。Nikki 继续拥有订阅 URL/token、下载、
缓存字节、解析和 metadata；第一阶段 SubscriptionOwner 只发现稳定 section 并调度官方 refresh，
NetFleet 不增加第二 downloader 或第二 cache。渲染结果仍交给 canonical deploy
owner 完成校验、snapshot、compile、activate、rollback 和 target-local
readback。部署器可从已校验的 package 目录或 GitHub Release 本机缓存读取同一代码
载体；目标端按 `apk/opkg` 安装，声明式路径仍由同一部署事务负责 snapshot、compile、activate、
rollback 和 owner readback。代码包与 deployment bundle 相同重放时不得刷新订阅或切换数据面；
跨目标只复用 package，不复用设备状态。

部署性能合同：package 模式必须在一次包管理器事务中安装两个 NetFleet package，
避免重复进程、锁和依赖解析；host 部署器必须输出准备、传输加目标事务和总耗时，
这些指标只用于运维观测，不参与选择或激活决策。重复部署在身份和文件校验通过后
直接返回 `already_installed`，不得重新安装 package。

升级性能合同：直接 APK 覆盖和 feed `apk upgrade` 都只传输发生变化的 package，
不重新生成 deployment bundle，不刷新订阅，也不重启 Nikki。一次事务安装两个包，
因此常规 UI/runtime 更新的设备端路径短于从 Git 构建再传输 bundle；首次配置 feed
仅增加一次公钥和仓库文件写入。实际耗时仍以目标机 `apk` 日志和 package manager
回读为准，不能把完整 VM qualification 时间当作升级时间。
