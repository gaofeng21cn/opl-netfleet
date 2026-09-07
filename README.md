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

NetFleet 为 OpenWrt 设备提供多机场网络管理。它可以增强已有 Nikki + Mihomo，也可以通过原生后端直接管理 Mihomo。不同订阅中的节点按机场、地区和用途组织，根据实时连接质量选择出口，并在路径变化时切换。

你仍然可以在熟悉的 LuCI 中查看状态、调整偏好和随时关闭增强。NetFleet 会保留一份可独立使用的原生配置；接管过程遇到问题时，设备会自动恢复到这份配置，尽量保持网络可用。

## 你会得到什么

- **统一管理多个机场。** 在一个界面中查看机场、地区、节点状态、延迟和订阅用量。
- **自动选择更合适的路径。** NetFleet 分别比较地区、机场和具体节点，让切换结果清楚可见。
- **按用途选择出口。** 常规网络与有地区要求的服务可以使用不同能力，也可以在条件合适时共享同一地区。
- **主用与备用分层。** 日常优先使用主用机场，主用路径均不可用时再进入备用层，最后回到直连。
- **持续检查运行状态。** 设备会定期刷新订阅、重新测量并检查透明代理和 DNS；异常持续超过保护时间后自动恢复。
- **可控的启用与关闭。** 安装、生成配置和正式接管分开进行，每一步都有清晰状态，关闭后回到选定的原生恢复配置。

## 设计思路

NetFleet 把“访问需求”和“具体节点”分开管理。规则只需要选择稳定的能力，例如常规网络或具有地区要求的服务；机场和节点则作为可替换资源参与实时选择。这样一来，新增机场、节点改名或局部故障都不会迫使用户重写整套规则。

自动选择分为三层：

1. **地区**决定网络距离、内容可用性和连接体验；
2. **机场**代表相对独立的线路和额度，用于隔离故障；
3. **节点**由 Mihomo URLTest 在同一地区内完成快速切换。

每一轮都使用最新测量结果，并设置切换门槛，避免线路在细小延迟波动中来回跳动。历史数据用于帮助用户理解运行情况，当前选择始终以当轮可用性和实时测量为准。

Mihomo 负责连接与节点健康检查，NetFleet 负责统一策略、跨机场选优与恢复事务。Nikki 模式沿用 Nikki 的订阅和数据面生命周期；原生模式由 NetFleet 在独立命名空间管理这些能力，并复用固定版本 Nikki 的配置投影和 nft 模板，不重新实现另一套节点选择器或并行控制器。

完整设计理念见[产品白皮书](docs/product/whitepaper.md)，当前实现与运行行为见[架构总览](docs/architecture/overview.md)。

## 当前功能

当前源码提供原生 LuCI 页面和设备端运行服务，支持以下入口。源码能力不等于某个 Release 或设备已经验收；安装前应确认发布资产对应的源码和后端支持范围。

- 首次设置向导，发现所选后端的原生配置、订阅缓存、地区和主入口组；
- 空白设备显式接入原生 Mihomo；已有 Nikki 设备通过预检、确认和失败恢复事务迁移；
- 原生订阅的新增、编辑、删除和单项更新，秘密输入不进入公开状态；
- 多机场主用/备用角色配置和地区范围设置；
- `standard` 与 `ai-compatible` 等能力的自动地区选择；
- Provider、地区与节点三级健康检查；
- 保护探针、分层 Fail-Open 和原生 Profile 恢复；
- 机场、地区、节点、订阅用量、事件与连接诊断；
- 独立打开完整 Zashboard，观察 Mihomo 实时连接、流量、规则命中和代理组；
- 周期性订阅刷新、配置重编译和自动选优；
- 原生后端的 IPv4/IPv6 TCP、UDP 透明代理，以及 LAN 和路由器本机 DNS 接管；
- 原生网络接入设置：DNS 上游与域名覆盖、LAN/本机代理范围、设备规则、监听端口和认证；
- 域名后缀与 IPv4/IPv6 CIDR 业务规则，可指定出口或直连；
- 本地配置文件导入、下载、受控编辑，以及 NetFleet 私有配置备份与恢复；
- 核心重启、重载和脱敏启动日志，以及独立的 Zashboard 资源版本检查与更新；
- OpenWrt APK/IPK 软件包、签名 APK feed 和 Fleet 声明式部署。

NetFleet 的事件与诊断页保留日常排查摘要；“Zashboard”在新标签页打开完整页面。两种后端共用独立入口，读取当前 controller 和资源状态。连接参数沿用 Zashboard 的带密钥 URL 方式，不写入 NetFleet 日志或展示缓存。

原生网络接入当前支持 TProxy。Mihomo 本身也支持 TUN 和 Redirect，但 NetFleet 尚未适配和验证这些模式在 OpenWrt 上的接管、清理与失败恢复，因此界面不开放模式切换。网络接入、配置文件和资源更新由原生后端管理；Nikki 模式仍由 Nikki 负责对应资源。

## 安装

### 准备工作

开始前，目标设备需要：

- 可用的 OpenWrt 软件包管理器；
- Mihomo 及该发布包要求的 OpenWrt 依赖；
- Nikki 接入：已正常运行的 Nikki、一份可独立使用的原生配置，以及至少一个有效订阅缓存；
- 原生接入：包含原生后端支持的包、可用上游 DNS 和一个有效机场订阅；接入前不得有其他代理核心占用网络。

在 OpenWrt 25.12 上，用一次性安装入口加入签名软件源并安装两个 package：

```sh
uclient-fetch -q -O /tmp/install-netfleet.sh https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/install-netfleet.sh && sh /tmp/install-netfleet.sh
```

该命令只安装 APK 公钥、软件源和程序文件，不写入 policy、订阅或 Nikki mixin，也不自动接管网络。

安装完成后，打开 LuCI 的“服务 -> NetFleet”。使用已运行 Nikki 时直接进入发现；空白设备先选择“首次接入 Mihomo”，明确确认下载订阅及网络接管，再进入共享首次设置：

1. 发现当前原生 Profile、机场缓存、地区和 `MATCH` 主入口组；
2. 检查当前环境并展示推荐配置；
3. 在用户确认后生成策略、编译配置并启动 NetFleet；
4. 回读运行状态和保护探针结果。

整个过程由设备本地完成。订阅 URL 和令牌保存在所选后端的私有配置中，不进入 policy 或公开状态。接管后可维护机场角色、地区映射、出口能力、业务绑定、域名与网段规则、自动周期和保护探针。原生订阅地址由独立“管理订阅”入口保存；修改来源不会自动停网，更新成功前继续使用上次可用缓存。

已有 Nikki 设备需要切换后端时，在“配置 -> 基础接入”选择“迁移到 NetFleet 原生后端”。迁移前检查真实资源和业务；成功后只运行原生后端，失败恢复旧后端，不长期双写。后端迁移与普通软件升级不是同一操作。

## 升级

LuCI 的“组件与更新”页显示组件安装版本、Mihomo 运行版本及关键依赖，可手动检查软件源。
NetFleet 与 LuCI 界面一起更新；原生后端的 Mihomo 单独确认更新，先验证当前配置，失败时恢复旧包和运行状态。不默认无人值守升级，也不升级整个系统。

同页的 Zashboard 区域独立检查和更新官方静态资源，不重启 Mihomo 或修改连接凭据。没有安装版本记录时显示“版本未记录”，不从文件时间猜测版本；检查更新后才展示可用版本。软件包、代理核心和面板资源分别确认，不隐式捆绑更新。

完成首次安装后，OpenWrt 可以直接从已配置的软件源升级：

```sh
apk update && apk upgrade opl-netfleet luci-app-netfleet
```

软件包升级只更新程序文件，现有策略、订阅缓存和当前运行配置会继续保留；升级完成后可在 NetFleet 页面检查状态并决定何时应用新配置。也可以重新执行一次性安装入口，它会补齐缺失的 NetFleet 包，再定向升级这两个包，不会重复创建实例配置或主动升级已满足约束的基础依赖。不要省略升级命令中的包名，以免变成全系统升级。

## 日常使用

### 配置与维护

“配置 -> 网络接入”管理原生后端的 DNS、代理范围、设备规则、监听和认证，应用前校验，失败恢复原配置；不修改 OpenWrt 的 WAN/LAN 地址或默认路由。业务流量的域名与网段分流在“业务规则”中配置。

“配置 -> 配置文件与备份”用于导入、下载和编辑本地配置，以及导出或恢复 NetFleet 备份。使用中的文件不能直接覆盖或删除。备份包含订阅地址等私有数据，不是系统固件备份，应妥善保管。

“事件与诊断”提供核心重启、重载及按需读取的启动日志；即使 Mihomo 控制接口不可用，仍可排查启动错误。管理范围与恢复规则见[设备独立管理](docs/architecture/management.md)。

### 自动选优

启用后，NetFleet 会按设定周期刷新订阅并运行一轮有界健康检查。根能力先选择地区；有额外地区要求的能力会在允许时跟随该地区，否则选择自己的最快合格地区。地区内的具体节点继续由 Mihomo URLTest 维护。

切换顺序固定为：

```text
当前优选 -> 其他主用机场 -> 备用机场 -> DIRECT
```

这套顺序把日常性能和故障恢复放在同一条可见路径中。用户可以从 LuCI 看到当前能力、地区、机场、节点、选择原因和回退状态。

### 关闭与恢复

关闭 NetFleet 时，设备切回选定的恢复配置，并回读当前后端、Mihomo、透明代理与 DNS。只有原生配置无法恢复时，才调用该后端的清理流程恢复网络直通，并报告真实业务探针结果。原生 gateway 只清理自己持有的网络状态，不删除其他服务的规则或路由。

## 面向多设备部署

个人使用可以直接通过 LuCI 完成首次设置。需要在多台设备上精确复现配置时，可使用 Fleet 声明式部署入口：

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref <release-or-commit> \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

deployment bundle 由私有 OPL Instance 生成，包含策略、订阅引用、后端 mixin 和平台声明。默认部署会完成安装、编译和 staged 回读；增加 `--activate` 后，部署器会先确认同一源码已经通过 OpenWrt QEMU qualification，再启用并回读目标设备。已有 Nikki bundle 的投影与原生迁移是独立入口，不能通过改一个后端名称代替迁移。

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
- [设备独立管理](docs/architecture/management.md)
- [UI 设计](docs/design/ui.md)
- [产品白皮书](docs/product/whitepaper.md)
- [开发与设备操作规则](AGENTS.md)

## 许可证

OPL NetFleet 默认采用 [Apache License 2.0](./LICENSE)，另有明确许可声明的文件除外。LuCI 等文件保留其 MIT 声明。包含 Nikki 派生模块的组合分发仍须遵循 [GNU GPL 3.0](openwrt/files/usr/share/opl-netfleet/nikki/LICENSE)。原有 NetFleet 文件的 Apache-2.0 声明继续保留，许可正文见 [Apache-2.0](openwrt/files/usr/share/opl-netfleet/LICENSE.Apache-2.0)；复用的 Nikki 模块保留其 GPL-3.0 许可证、版权、固定上游版本和[修改说明](openwrt/files/usr/share/opl-netfleet/nikki/NOTICE)。第三方原始声明不因组合分发而移除。
