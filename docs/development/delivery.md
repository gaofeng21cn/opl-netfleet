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

1. 选定干净主线源码，更新实际变更的软件包版本，完成对应本地检查。
2. 使用 `scripts/netfleet-package-build.sh` 本地构建，或手动运行
   `.github/workflows/netfleet-openwrt-candidate.yml`，输入源码 ref、SDK URL 及 SHA-256。
   工作流只上传保留 7 天的候选，不因推送 tag 自动发布。
3. 按[软件包资格验证](validation.md)完成同源码、同候选资产的 ARM64 OpenWrt VM 验收。
4. 使用已有发布入口：

```sh
scripts/publish-netfleet-release.sh --tag vX.Y.Z \
  --candidate /absolute/path/to/candidate \
  --qualification /absolute/path/to/qualification.json
```

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
