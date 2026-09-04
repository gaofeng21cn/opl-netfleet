<p align="center">
  <img src="assets/branding/opl-netfleet-logo.png" alt="OPL NetFleet 标志" width="136" />
</p>

<p align="center">
  <strong>中文</strong> | <a href="./README.en.md">English</a>
</p>

<h1 align="center">OPL NetFleet</h1>

<p align="center"><strong>面向 OpenWrt 的网络增强插件</strong></p>
<p align="center">多机场整合 · 分层自动选优 · 平稳切换 · 故障自动恢复</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-netfleet/actions"><img src="https://img.shields.io/github/actions/workflow/status/gaofeng21cn/opl-netfleet/netfleet-release.yml?label=checks" alt="Checks" /></a>
  <a href="https://github.com/gaofeng21cn/opl-netfleet/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-netfleet" alt="最新版本" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0 许可证" /></a>
</p>

NetFleet 为使用 Nikki 和 Mihomo 的 OpenWrt 设备提供更省心的多机场网络管理。它把不同订阅中的节点按机场、地区和用途整理到统一界面，根据实时连接质量选择合适的出口，并在路径变化时自动完成切换。

你仍然可以在熟悉的 LuCI 中查看状态、调整偏好和随时关闭增强。NetFleet 会保留一份可独立使用的原生配置；接管过程遇到问题时，设备会自动恢复到这份配置，尽量保持网络可用。

## 你会得到什么

- **统一管理多个机场。** 在一个界面中查看机场、地区、节点状态、延迟和订阅用量。
- **自动选择更合适的路径。** NetFleet 分别比较地区、机场和具体节点，让切换结果清楚可见。
- **按用途选择出口。** 常规网络与有地区要求的服务可以使用不同能力，也可以在条件合适时共享同一地区。
- **主用与备用分层。** 日常优先使用主用机场，主用路径均不可用时再进入备用层，最后回到直连。
- **持续检查运行状态。** 设备会定期刷新订阅、重新测量并检查透明代理和 DNS；异常持续超过保护时间后自动恢复。
- **可控的启用与关闭。** 安装、生成配置和正式接管分开进行，每一步都有清晰状态，关闭后回到原生 Nikki 配置。

## 设计思路

NetFleet 把“访问需求”和“具体节点”分开管理。规则只需要选择稳定的能力，例如常规网络或具有地区要求的服务；机场和节点则作为可替换资源参与实时选择。这样一来，新增机场、节点改名或局部故障都不会迫使用户重写整套规则。

自动选择分为三层：

1. **地区**决定网络距离、内容可用性和连接体验；
2. **机场**代表相对独立的线路和额度，用于隔离故障；
3. **节点**由 Mihomo URLTest 在同一地区内完成快速切换。

每一轮都使用最新测量结果，并设置切换门槛，避免线路在细小延迟波动中来回跳动。历史数据用于帮助用户理解运行情况，当前选择始终以当轮可用性和实时测量为准。

Nikki 继续负责订阅、配置和 OpenWrt 数据面的生命周期，Mihomo 继续负责连接与节点健康检查，NetFleet 在两者之上提供统一的策略组织、自动选择和恢复体验。这种分工复用了成熟能力，也让接管与退出都更直接。

完整设计理念见[产品白皮书](docs/product/whitepaper.md)，当前实现与运行行为见[架构总览](docs/architecture/overview.md)。

## 当前功能

当前版本提供原生 LuCI 页面和设备端运行服务，支持：

- 首次设置向导，自动发现当前 Nikki Profile、订阅缓存、地区和主入口组；
- 多机场主用/备用角色配置和地区范围设置；
- `standard` 与 `ai-compatible` 等能力的自动地区选择；
- Provider、地区与节点三级健康检查；
- 保护探针、分层 Fail-Open 和原生 Profile 恢复；
- 机场、地区、节点、订阅用量、事件与连接诊断；
- 周期性订阅刷新、配置重编译和自动选优；
- OpenWrt APK/IPK 软件包、签名 APK feed 和 Fleet 声明式部署。

连接页面目前提供适合日常排查的只读信息。更完整的 Mihomo 实时观察界面仍在设计中，相关方案见[产品白皮书](docs/product/whitepaper.md)。

## 安装

### 准备工作

开始前，目标设备需要：

- 可用的 OpenWrt 软件包管理器；
- 已安装并正常运行的 Nikki 与 Mihomo；
- 一份可独立使用的原生 Nikki Profile；
- 至少一个稳定命名、已有有效缓存的订阅。

从同一 Release 下载并安装 `opl-netfleet` 与 `luci-app-netfleet`。OpenWrt 25.12 的 APK 示例：

```sh
apk add --upgrade ./opl-netfleet-<版本>.apk ./luci-app-netfleet-<版本>.apk
```

安装完成后，打开 LuCI 的“服务 -> NetFleet”。首次设置会依次完成：

1. 发现当前原生 Profile、机场缓存、地区和 `MATCH` 主入口组；
2. 检查当前环境并展示推荐配置；
3. 在用户确认后生成策略、编译配置并启动 NetFleet；
4. 回读运行状态和保护探针结果。

整个过程由设备本地完成。订阅 URL 和令牌继续保存在 Nikki 与设备私有配置中；NetFleet 使用现有缓存组织节点，并让用户在接管后明确设置机场角色、地区范围、自动周期和保护探针。

## 升级

一次性升级可以同时安装同一 Release 中的两个软件包：

```sh
apk add --upgrade ./opl-netfleet-<版本>.apk ./luci-app-netfleet-<版本>.apk
```

发布版还提供签名的 `packages.adb`，可以加入 OpenWrt APK 软件源，通过系统软件包管理器检查和升级。软件包升级只更新程序文件，现有策略、订阅缓存和当前运行配置会继续保留；升级完成后可在 NetFleet 页面检查状态并决定何时应用新配置。

## 日常使用

### 自动选优

启用后，NetFleet 会按设定周期刷新订阅并运行一轮有界健康检查。根能力先选择地区；有额外地区要求的能力会在允许时跟随该地区，否则选择自己的最快合格地区。地区内的具体节点继续由 Mihomo URLTest 维护。

切换顺序固定为：

```text
当前优选 -> 其他主用机场 -> 备用机场 -> DIRECT
```

这套顺序把日常性能和故障恢复放在同一条可见路径中。用户可以从 LuCI 看到当前能力、地区、机场、节点、选择原因和回退状态。

### 关闭与恢复

关闭 NetFleet 时，设备会切回首次设置时选定的 Recovery Profile，并回读 Nikki、Mihomo、透明代理与 DNS 状态。若原生 Profile 本身无法恢复，设备会调用 Nikki 的官方清理流程进入直通模式，并报告实际业务探针结果。

## 面向多设备部署

个人使用可以直接通过 LuCI 完成首次设置。需要在多台设备上精确复现配置时，可使用 Fleet 声明式部署入口：

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref <release-or-commit> \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

deployment bundle 由私有 OPL Instance 生成，包含策略、订阅引用、Nikki mixin 和平台声明。默认部署会完成安装、编译和 staged 回读；增加 `--activate` 后，部署器会先确认同一源码已经通过 OpenWrt QEMU qualification，再启用并回读目标设备。

多设备推广建议先在可本地恢复的 canary 完成一次“编译、启用、回读、关闭”全流程，再把同一发布包和配置推广到其他设备。完整步骤见[Canary 推广与复原](docs/operations/canary-promotion.md)。

## 开发

快速检查：

```bash
scripts/check-fast.sh
```

完整 fake-device 部署矩阵：

```bash
scripts/check-full.sh
```

本机 React/Vite 参考页面用于快速确认信息层级和交互，设备端以原生 LuCI 页面为准：

```bash
cd ui
bun install
NETFLEET_UI_TARGET=<ssh-alias> NETFLEET_UI_TARGET_LABEL="Canary" bun run dev
```

## 文档

- [文档索引](docs/README.md)
- [架构总览](docs/architecture/overview.md)
- [UI 设计](docs/design/ui.md)
- [产品白皮书](docs/product/whitepaper.md)
- [开发与设备操作规则](AGENTS.md)

## 许可证

OPL NetFleet 采用 [Apache License 2.0](./LICENSE)。
