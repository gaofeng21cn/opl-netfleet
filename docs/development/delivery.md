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

产品版本与最低系统壳要求均由 `product-version.json` 维护（含 `version` 与 `min_shell_version`），由 `scripts/prepare-product-release.py` 校验版本单调关系并统一同步 `openwrt/Makefile`、macOS `desktop/app/Info.plist`（含 `CFBundleShortVersionString` 与单调递增的 `CFBundleVersion`）及 `docs/development/plugin-catalog.json`，并由 `scripts/netfleet-bundle-build.py` 与 `scripts/netfleet-ipk-build.py` 消费；OpenWrt 插件继续独立版本化。各平台制品使用同一个产品 tag 和源码身份，
安装情况以目标实际产物为准。某个平台待验收时保留该状态，修复后验证原候选。

统一每日产品任务检测交付变化并经 PR/CI 准备版本。正式产品 tag 同时触发 OpenWrt 云端发布
和 macOS 签名候选构建。macOS 完成净机验证后，由维护者推进 Sparkle 更新源。
设备安装按[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)执行。

## OpenWrt 公开发布

本节用于开发并发布新版本。“把设备更新到最新版”使用
[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)，默认消费已发布
Feed；不能因为源码领先、另有开发任务或构建工具可用，就重新进入本节。

### 构建前预检与候选复用

先检查源码与设备载荷，而不是先启动编译。修改 `plugins/` 后，只递增真实变更插件的 manifest 版本，
再执行 `python3 scripts/plugin-catalog.py write`。检查和提交必须包含这些更新；OpenWrt 打包与部署脚本在构建阶段直接从 `plugins/` 取用服务插件。
冻结前同时核对新版调用者所需的最低提供者版本；新字段保存等能力即使未改变服务 API，
也须在真实 APK 依赖中约束最低版本，不能让页面升级后仍组合到不具备该能力的旧存储。
构建入口会对归档 ref 再运行载荷一致性检查；本地工作区同步不能补救旧 ref 的缺失。

Linux x86_64 SDK 不能由 macOS 的 Make、OpenSSL 直接执行。构建入口在非 Linux x86_64
宿主上自动使用本地 `opl-netfleet-openwrt-sdk-builder:latest` Docker 镜像；可通过
`NETFLEET_SDK_IMAGE` 指定已准备的构建镜像。首次准备镜像执行
`docker build --platform linux/amd64 -f scripts/openwrt-sdk.Dockerfile -t opl-netfleet-openwrt-sdk-builder:latest .`。源码与签名材料只读挂载，SDK 与输出目录可写。GitHub 候选构建固定使用 Ubuntu 24.04，与本地 SDK 容器的宿主工具链一致。
原生 Linux 路径检查 GNU Make 4+、工具和 SDK OpenSSL，所有 Make 调用遵循 `MAKE`。
SDK UCode 构建前按 SDK 自带的固定提交初始化 base feed，再安装 host 构建依赖；新解压的 SDK 与已有缓存使用同一路径。准备后使用本 SDK 的动态库路径，并执行 fs/socket 导入自检，避免 SDK 搬迁后失效的旧 RPATH。
架构优先从 SDK `.config` 读取，未配置时才查询 Make。共享 SDK 由构建锁保护，冲突立即
返回；不要启动第二个构建、抢锁或清空别人使用的 SDK。

构建入口通过 `scripts/netfleet-bundle-build.py` 打包经 `NETFLEET_BUNDLE_SIGN_KEY`（Ed25519 / `usign`）签名的纯源码 Release Bundle，再调用 OpenWrt SDK 封装薄系统包壳 `.apk`（`opl-netfleet`、`luci-app-netfleet`、`mihomo-meta`）及零 SDK 确定性构建入口 `scripts/netfleet-ipk-build.py` 输出对应 `.ipk` 与 `usign` 签名 `Packages*` 索引。只改文档或开发工具且产品
载荷未变时，不为新的 Git 提交重建已冻结的包；验证仍以原候选的准确身份为准。
完整 VM 的测试夹具修复可用 `openwrt-vm.sh --ref <候选提交> --test-ref <测试提交>`；
入口只允许测试与文档差异，设备源、依赖或其他包输入变化会拒绝复用，回执另记测试身份。
生成与校验顺序覆盖包结构校验、签名验签、`FILES.sha256` 一致性及 Release Bundle 完整性门禁，不再执行构建期跨分支 `ucode -c` 字节码预编译。

候选目录旁的 `<候选目录>.build-timings.json` 记录预检、编译、打包和总秒数；编译桶再拆成
`sdk_prepare_seconds`、`clean_seconds`、`product_compile_seconds`。诊断时结合 SDK 日志的
`time: package/...#user#system#elapsed` 行；这些子项可能嵌套，不直接相加冒充总耗时。
同一次构建已经产出有效候选后，不为收集计时再构建一次。失败时先定位最早失败阶段，
修复后只重跑受影响检查；不把一次快速预检失败统计为编译耗时。合格候选供多个设备
复用一次，部署不重新构建。设备更新与阶段计时的唯一 SOP 见
[有限插件组合更新](../operations/canary-promotion.md#有限插件组合更新)。

### 资格冻结与阶段化交付

长资格开始前先冻结四个身份：源 commit/tree、候选 `manifest.json`、测试 ref 和资格输入
目录。可以把以下只读预检作为长 QEMU 资格的第一步：

```sh
python3 scripts/netfleet-delivery-preflight.py \
  --ref <source-commit> --candidate <candidate-dir> --fixture <fixture-dir> \
  --require-clean --output <private-preflight.json>
```

预检会验证候选确实属于该源码、测试 ref 只改变测试工具、载荷没有 `._*` 或编辑器临时文件，
并确认 components owner 仍通过 `platform.paths` 取得私有运行路径。
生产代码、候选包或依赖变更后必须重新冻结并取得完整资格；只有测试工具变化且身份仍绑定时，
才允许使用 `--test-ref`。资格失败后按失败阶段恢复，保留同一身份下已经成立的阶段回执，
不要把一个长场景的失败简单重跑成另一批候选。

交付耗时按构建、预检、短门、完整资格、发布、设备事务和最终回读分别记录。并行阶段只能报告
墙钟耗时与各阶段耗时，不能把并行子任务相加冒充端到端时长；历史耗时缺少阶段回执时只报告
已知部分，不用估算补齐。

#### 常规正式发布

源码检查通过后，为已进入主线的候选提交推送对应版本的 annotated tag，触发 `.github/workflows/release.yml`。

| Actions 阶段 | 运行位置 | 验证内容及输出 |
| --- | --- | --- |
| 锁定源码与构建候选 | GitHub 托管 Ubuntu x64 | 核对 tag、产品版本和主线归属。用固定 SDK 构建签名薄壳 APK、零 SDK IPK 及签名纯源码 Release Bundle，封存候选和摘要。 |
| 并行运行四组基础资格 | 四个 GitHub 托管 Ubuntu ARM64 job | 独立启动干净 OpenWrt VM，分别验证原生运行、首次设置及组件事务、管理与运行及迁移、签名薄壳安装与运行。ARM64 Linux 有 KVM 时使用 KVM，否则使用 TCG。各组记录阶段耗时和结果。 |
| 汇总发布回执 | GitHub 托管 Ubuntu x64 | 核对四组回执绑定本次源码、候选清单和夹具，生成统一发布资格回执。 |
| 发布与公开回读 | GitHub 托管 Ubuntu x64 | 发布同一套签名包、`Packages*`/`packages.adb` 与 Release Bundle 资产，随后从公开地址下载并核对源码身份、文件集合和逐字节摘要。 |

先看 Actions 的 job 名称定位当前验收内容，再看对应阶段日志和回执。候选与回执仍在保留期内时，
用 **Re-run failed jobs** 续跑失败阶段和下游任务，复用同一运行中的成功候选与回执。
如果验收脚本已修复并合入主线，从 `main` 手动触发 `Release NetFleet`，填写原产品 tag、
tag 运行 ID、签名候选 artifact ID 和摘要。基础资格验收使用同一主线提交的 VM runner
与客体验收脚本，回执记录该提交，产品源码、签名包和封存夹具仍绑定原候选。
首次设置验收为已进入回滚的组件事务预留独立的有界观察窗口，直到读到同一事务的终态。
组件验收只在 RPC 明确返回启动前的 `mutation_busy` 时重试请求。LAN 故障验收在取得部署锁后注入故障，
持锁覆盖完整观察窗口。
坏包用例还会核对预期失败原因、旧包版本、配置和代理连通性。
仅修改客体验收脚本时，每日发布不生成新产品版本。已有候选可使用上述入口复验。
APK 和夹具按原字节免二次压缩上传。`netfleet-output/` 保存默认包，`netfleet-vm-components/` 保存与候选绑定的升级和回滚夹具。`scripts/openwrt-sdk.json` 固定构建所用 SDK 的 URL 和 SHA-256。

#### 定向诊断和本地验收

开发时可手动运行 `.github/workflows/netfleet-openwrt-candidate.yml`，输入源码 ref、SDK URL 及 SHA-256，或用
`scripts/netfleet-package-build.sh` 在已准备的 SDK 上构建。需要定向复现时，按[隔离 OpenWrt](validation.md#隔离-openwrt)选择对应诊断，
复用同一候选和夹具。本机运行 QEMU 资格命令时，用
`env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY` 清除宿主壳代理环境变量。

使用已通过完整验收的本地候选进行容灾发布时，复用已经建立的 tag，先停止该 tag 的云端发布运行并确认终止，再调用同一发布器。

```sh
scripts/publish-netfleet-release.sh --tag vX.Y.Z \
  --candidate /absolute/path/to/candidate \
  --qualification /absolute/path/to/qualification.json
```

入口检查候选与资格回执绑定、版本与 tag 一致、候选已被最新远端主线包含，再创建不可变
Release 并下载公开资产校验。主线前进后仍使用已冻结并验收的候选。候选自身变更时重新
构建和验收，不改旧回执。发布成功
仍不等于设备已升级。实际推广按[部署操作](../operations/deployment.md)执行。

## macOS 本地交付

按[macOS 构建与验证](macos.md#本地交付)完成 arm64 检查，以干净源码构建直接可运行的
`.app`，再替换已正常退出的本机应用。应用的“关于 OPL NetFleet”和包内 `build.json`
提供版本、渠道及源码回读。构建成功、磁盘替换成功、应用启动成功分别验收。

该渠道不创建 GitHub Release、下载页或更新 feed。macOS CI 中的应用只用于构建验证，
不作为本机已安装的证据。系统代理/TUN 授权验收仍是单独的实际网络操作。

## macOS DMG 公开分发

macOS 使用同一产品 `vX.Y.Z` tag，版本对应应用 `Info.plist`。旧 `macos-v` Release
保留原资产。发布入口将通过验收的 DMG、`OPL-NetFleet-macos-arm64.dmg.sha256` 和 Ed25519 签名的
`appcast.xml` 追加到同一产品 Release，并将 `appcast.xml` 同步到非 `latest` 的浮动
`macos-stable` Release，使 OpenWrt 独立发布不会打断 macOS Sparkle 更新源。
应用内自更新由 Sparkle 2 验证 `appcast.xml` 的 Ed25519 签名与 Apple 代码签名/公证，
确认安装前经由宿主标准退出路径停止核心并撤销网络接管。
按[签名与 DMG](macos.md#签名与-dmg)构建、公证并冻结 arm64 DMG，完成最终包的隔离
macOS VM 验收后才发布。应用签名、两次公证、最终 DMG 摘要、源码身份和 VM 结果分别
回读；发布后下载公开资产并核对相同摘要。内部验收日志与订阅数据不进入 Release。

每日产品发布创建 `vX.Y.Z` tag 后自动启动 `.github/workflows/macos-sparkle-release.yml`，
与 OpenWrt 包资格验证并行。构建绑定同一 annotated tag 指向的 `main` 源码。
已有 tag 补建候选或需要提前验证时，从远端 `main` 手动运行同一工作流，传入
`release_tag=vX.Y.Z` 和已进入 `main` 的完整 `source_sha`。
工作流在 GitHub Environment `release` 使用 Apple Developer ID 的单身份 `.p12`、对应密码、
公证账号与 App-Specific Password，以及应用的 `SPARKLE_ED25519_PRIVATE_KEY`。
构建前检查当前 `macos-stable` 及已有的目标 tag 和 Release。tag 指向其他源码或已有版本化 macOS 资产时停止构建。
托管 macOS ARM64 runner 完成构建、签名、公证与候选封存。其中 DMG 和 VM 测试输入归档
各上传一次，免二次压缩。Actions 摘要列出候选版本、源码和最终 DMG 摘要。凭据见[签名与 DMG](macos.md#签名与-dmg)。

有可用的隔离 Apple Silicon macOS VM 时，从该次成功的 run 下载候选与测试输入，按[签名与 DMG](macos.md#签名与-dmg)
完成测试并关闭 VM。当前由维护者在具备 Tart 的机器上按需执行该阶段。只有这一阶段需要占用 VM。
构建缓存、候选封存及发布均由托管 runner 处理。详细验收记录留在执行机器。

产品 tag、公开 Release 和 VM 回执齐备后，从 `main` 派发 `macos-sparkle-publish.yml`，传候选 run ID 和最小资格回执。
托管 Ubuntu runner 从该 run 取原制品，校验后发布和回读。发布中断时复用同一 run ID 和回执。

```sh
gh run download "$candidate_run_id" --repo gaofeng21cn/opl-netfleet \
  --name "netfleet-macos-$release_tag" --dir "$candidate_dir"
gh run download "$candidate_run_id" --repo gaofeng21cn/opl-netfleet \
  --name "netfleet-macos-vm-inputs-$release_tag" --dir "$vm_input_dir"
tar -xzf "$vm_input_dir/netfleet-macos-vm-inputs.tar.gz" -C "$vm_input_dir"
gh workflow run macos-sparkle-publish.yml --repo gaofeng21cn/opl-netfleet --ref main \
  -f release_tag="$release_tag" -f candidate_run_id="$candidate_run_id" \
  -f qualification_json="$(jq -c '{vm_qualified,dmg_sha256,build:(.build|{channel,working_tree_dirty,package_version,package_release,source_commit,source_tree})}' "$vm_receipt")"
```

发布脚本核对验收回执、DMG 摘要、应用构建号和 tag 所指的源码 commit/tree，再追加缺失的 DMG、
`.sha256` 与 `appcast.xml`。同名远端资产仅在摘要和大小都一致时接受。

浮动 `macos-stable` 在版本化资产均已回读后更新。推进要求 `sparkle:version`
（`CFBundleVersion`）严格递增且 `sparkle:shortVersionString` 不回退，同一份 appcast
允许幂等重跑。发布脚本先上传并验证候选 appcast，再切换资产名。两次改名之间公开更新地址可能
短暂不可用，发布脚本保留上一份 appcast 并在切换失败后恢复。进程中断时，重试会用
保留下来的 appcast 核对版本并继续切换。发布后读回两个 Release，核对版本化资产的公开摘要、
原 OpenWrt Feed 资产与 `macos-stable` 的 enclosure URL、产品版本和构建号。

同一 tag 的 OpenWrt Feed 与 macOS DMG 各自核对自己的资产和摘要。追加已验收的
DMG 与 `appcast.xml` 保持既有 Feed 资产原字节，不创建独立版本；浮动 `macos-stable` 仅承载
指向最新已签名 DMG 的 `appcast.xml`。分发构建支持用户确认后的
Sparkle 2 原生自更新，不执行后台静默替换，也不自动更新本地开发构建。
