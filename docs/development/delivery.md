# 双平台交付

面向维护者，回答一次主线改动怎样进入对应平台的交付入口。共同身份与状态边界归
[打包合同](../architecture/packaging.md#平台交付与版本身份)，平台机制分别归
[OpenWrt](../platform/openwrt.md#版本化分发)和[macOS](../platform/macos.md#打包与签名)。

## 共享检查，独立交付

PR 与 `main` 更新运行 `NetFleet 双平台检查`。检查结果只证明所指向源码的验证结果；
不会自动创建 Release、替换本机应用或更新设备。不按 `openwrt/` 路径跳过 macOS 检查：
共享业务代码也位于这个目录。所需本地检查按[开发验证](validation.md)选择。

| 改动 | 验证范围 | 交付选择 |
| --- | --- | --- |
| 共享业务、对象、策略或交互 | 共享检查及两端相关链路 | 两端分别验收后交付，可先后进行 |
| 平台宿主、包管理或系统集成 | 对应平台；若改变共享接口则扩展到两端 | 只交付受影响的平台 |
| 文档或开发工具 | 链接、命令及受影响构建入口 | 无需仅为同步版本而发布产品 |

先完成本地验证，再进入主线。正式交付从干净、已吸收的源码构建，记录精确 commit/tree，
不要把可移动的 `main` 名称当作永久身份。主线继续前进不表示已安装版本同步更新。

平台版本分别维护；OpenWrt 插件继续独立版本化，macOS 应用也不跟随 OpenWrt 包号强制
递增。比较共享代码看源码身份，判断安装情况看目标实际产物。一个平台交付失败不回滚
另一平台已经验收的交付；失败平台修复后重新验证自己的候选。

## OpenWrt 公开发布

本节用于开发并发布新版本。“把设备更新到最新版”使用
[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)，默认消费已发布
Feed；不能因为源码领先、另有开发任务或构建工具可用，就重新进入本节。

### 构建前预检与候选复用

先检查源码与设备载荷，而不是先启动编译。修改 `plugins/` 后执行
`python3 scripts/sync-plugin-sources.py sync`，只递增真实变更插件的 manifest 版本，
再执行 `python3 scripts/plugin-catalog.py write`。检查和提交必须包含这些投影。
冻结前同时核对新版调用者所需的最低提供者版本；新字段保存等能力即使未改变服务 API，
也须在真实 APK 依赖中约束最低版本，不能让页面升级后仍组合到不具备该能力的旧存储。
构建入口会对归档 ref 再运行载荷一致性检查；本地工作区同步不能补救旧 ref 的缺失。

Linux x86_64 SDK 不能由 macOS 的 Make、OpenSSL 直接执行。构建入口在非 Linux x86_64
宿主上自动使用本地 `opl-netfleet-openwrt-sdk-builder:latest` Docker 镜像；可通过
`NETFLEET_SDK_IMAGE` 指定已准备的构建镜像。首次准备镜像执行
`docker build --platform linux/amd64 -f scripts/openwrt-sdk.Dockerfile -t opl-netfleet-openwrt-sdk-builder:latest .`。源码与签名材料只读挂载，SDK 与输出目录可写。
原生 Linux 路径检查 GNU Make 4+、工具和 SDK OpenSSL，所有 Make 调用遵循 `MAKE`。
SDK UCode 准备后使用本 SDK 的动态库路径，并执行 fs/socket 导入自检，避免 SDK 搬迁后失效的旧 RPATH。
架构优先从 SDK `.config` 读取，未配置时才查询 Make。共享 SDK 由构建锁保护，冲突立即
返回；不要启动第二个构建、抢锁或清空别人使用的 SDK。

复用已准备的 SDK 与下载缓存；输出使用独立候选目录。构建会清理本次产品编译目录，
但保留 SDK 工具与下载缓存。当前默认产品构建入口仍生成完整候选包集合，并非按包摘要
增量构建器；普通设备更新只安装有变化的包，两者不要混淆。只改文档或开发工具且产品
载荷未变时，不为新的 Git 提交重建已冻结的包；验证仍以原候选的准确身份为准。
完整 VM 的测试夹具修复可用 `openwrt-vm.sh --ref <候选提交> --test-ref <测试提交>`；
入口只允许测试与文档差异，设备源、依赖或其他包输入变化会拒绝复用，回执另记测试身份。
模拟旧版 APK 时，必须同步其内部最低依赖，先验证旧版组合可安装再测试升级；
不能只递减包版本而保留指向新版提供者的依赖。

构建 Makefile 每次解析只启动一次插件元数据读取和依赖图校验，再批量取得全部版本和
依赖；不逐插件重复扫描依赖图。最终文件清单也在一个进程中计算 SHA-256，按字节序
排序，保持原有清单格式。产品 clean、签名校验、字节码验证和运行时门禁继续执行。

候选目录旁的 `<候选目录>.build-timings.json` 记录预检、编译、打包和总秒数；编译桶再拆成
`sdk_prepare_seconds`、`clean_seconds`、`product_compile_seconds`。诊断时结合 SDK 日志的
`time: package/...#user#system#elapsed` 行；这些子项可能嵌套，不直接相加冒充总耗时。
同一次构建已经产出有效候选后，不为收集计时再构建一次。失败时先定位最早失败阶段，
修复后只重跑受影响检查；不把一次快速预检失败统计为编译耗时。合格候选供多个设备
复用一次，部署不重新构建。设备更新与阶段计时的唯一 SOP 见
[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)。

1. 选定干净主线源码，更新实际变更的软件包版本，先完成源码、载荷同步、UI 和受影响故障路径检查，再冻结候选。未变更的插件不递增版本；不要在检查尚未完成时同时启动多批构建。
2. 使用 `scripts/netfleet-package-build.sh` 本地构建，或手动运行
   `.github/workflows/netfleet-openwrt-candidate.yml`，输入源码 ref、SDK URL 及 SHA-256。
   工作流只上传保留 7 天的候选，不因推送 tag 自动发布。
3. 按[软件包资格验证](validation.md)完成同源码、同候选资产的 ARM64 OpenWrt VM 验收。
4. 使用已有发布入口：

```sh
scripts/publish-netfleet-release.sh --tag vX.Y.Z \
  --candidate /absolute/path/to/candidate \
  --qualification /absolute/path/to/qualification.json \
  --compat-candidate /absolute/path/to/optional-candidate \
  --compat-qualification /absolute/path/to/optional-qualification.json \
  --apk scripts/openwrt-apk.py
```

发布使用与构建相同的 `NETFLEET_SDK`；`scripts/openwrt-apk.py` 在 Linux 直接运行 SDK APK，
在 macOS 使用已准备的本地构建镜像执行签名校验与索引工具。输入目录只读、索引输出目录可写，
不需要每次部署临时拼装 Docker 包装器，也不直接执行异平台二进制。

完整发行版提供上述可选包参数；只发布默认产品时省略 `--compat-candidate` 和
`--compat-qualification`、`--apk`，并明确没有完整安装组合。
复用未变化的可选 APK 且实际依赖调用链变化时，用
`scripts/https-compat/qualify.py --composition` 对新的默认候选执行组合验证；
未变调用链可复用原独立资格，发布入口逐文件验证其适用性。组合验证传入 `--packages`、`--base-qualification`、
`--candidate` 和 `--output`。该入口保留引擎原始版本与构建身份，使用新基础包源码
测试首次完整安装、重复安装与故障恢复，不伪造引擎升级或改写旧清单。
测试工具有修复时可另传 `--test-ref <commit>`：安装包仍保留原 commit/tree 与 SHA-256，
回执另记测试源码；入口验证基座运行源码未变。只修测试或部署工具不重建包、不重跑
已经成立的完整基础资格。测试返回 `mutation_busy` 时仅重试明确未执行的调用，
执行结果不明时先读事务，不重放。
入口检查候选与资格回执绑定、版本与 tag 一致、候选已被最新远端主线包含，再创建不可变
Release 并下载公开资产校验。主线前进后仍使用已冻结并验收的候选；候选自身变更才重新
构建和验收，不改旧回执。发布成功
仍不等于设备已升级。实际推广按[部署操作](../operations/deployment.md)执行。

## macOS 本地交付

按[macOS 构建与验证](macos.md#本地交付)完成 arm64 检查，以干净源码构建直接可运行的
`.app`，再替换已正常退出的本机应用。应用的“关于 OPL NetFleet”和包内 `build.json`
提供版本、渠道及源码回读。构建成功、磁盘替换成功、应用启动成功分别验收。

该渠道不创建 GitHub Release、下载页或更新 feed。macOS CI 中的应用只用于构建验证，
不作为本机已安装的证据。系统代理/TUN 授权验收仍是单独的实际网络操作。

## macOS DMG 公开分发

macOS 使用独立的 `macos-vX.Y.Z` tag，版本对应应用 `Info.plist`，不与 OpenWrt 包号绑定。
按[签名与 DMG](macos.md#签名与-dmg)构建、公证并冻结 arm64 DMG，完成最终包的隔离
macOS VM 验收后才发布。应用签名、两次公证、最终 DMG 摘要、源码身份和 VM 结果分别
回读；发布后下载公开资产并核对相同摘要。内部验收日志与订阅数据不进入 Release。

macOS-only Release 必须使用 `gh release create --latest=false`，避免抢占 OpenWrt
安装入口依赖的 `/releases/latest/download/install-netfleet.sh`。公开 macOS 资产通过
对应 tag 获取；本流程不提供应用内自动更新，也不自动更新已安装的本机应用。
