<p align="center">
  <img src="assets/branding/opl-netfleet-logo.png" alt="OPL NetFleet 标志" width="136" />
</p>

<p align="center">
  <strong>中文</strong> | <a href="./README.en.md">English</a>
</p>

<h1 align="center">OPL NetFleet</h1>

<p align="center"><strong>基于微内核的 OpenWrt 代理与网络管理平台</strong></p>
<p align="center">独立管理 Mihomo · 多机场自动选优 · 功能插件组合 · 独立热替换</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-netfleet/actions"><img src="https://img.shields.io/github/actions/workflow/status/gaofeng21cn/opl-netfleet/netfleet-release.yml?label=checks" alt="Checks" /></a>
  <a href="https://github.com/gaofeng21cn/opl-netfleet/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-netfleet" alt="最新版本" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0 许可证" /></a>
</p>

NetFleet 将订阅管理、业务分流、自动选路、DNS、透明代理和运行维护整合到同一个 LuCI 界面。原生模式直接管理 Mihomo，可在没有运行 Nikki 的 OpenWrt 设备上完成首次接入；已有 Nikki 用户也可以沿用现有环境，或通过迁移入口转到 NetFleet 原生后端。

它围绕“机场、地区、业务出口”组织网络：用实时测量选择路径，以主用、备用和直连分层处理故障。微内核负责服务组合与生命周期，订阅、策略、后端、选择、恢复和管理由功能插件提供，单台设备配置和多设备声明式部署共用同一套运行逻辑。

## 你会得到什么

- **独立完成代理管理。** 原生模式覆盖订阅、配置文件、DNS、透明代理、核心维护和备份恢复。
- **统一组织多个机场。** 查看地区、节点、延迟与用量，设置主用和备用，让局部线路故障有替代路径。
- **按业务自动选择出口。** 常规网络与有地区要求的服务可以使用不同出口能力，选择结果和切换原因可见。
- **自由组合功能插件。** 自有与第三方插件共用开发接口，支持独立安装、更新和热替换；组件页统一展示安装、依赖与接口兼容状态。
- **可控地应用和恢复。** 安装、配置生成和网络接管分开；应用失败时恢复原配置，关闭时切回独立恢复配置。
- **复现多设备配置。** Fleet 入口按明确版本部署，在设备端校验、编译并回读结果。

## 两种接入方式

| 方式 | 适用场景 | 管理分工 |
| --- | --- | --- |
| **NetFleet + Mihomo（原生）** | 从零配置，或希望由 NetFleet 统一管理 | NetFleet 管理订阅、配置、核心服务、DNS 和透明代理，无需运行 Nikki 服务 |
| **Nikki + Mihomo** | 已有稳定 Nikki 环境，希望加入多机场选优与恢复 | Nikki 保留订阅和数据面管理，NetFleet 提供共享策略、选优与恢复事务 |

两种后端明确选择、互斥运行，迁移有独立预检和失败恢复。原生后端复用固定版本 Nikki 的配置投影与 nft 模板，保留上游来源与许可证；当前网络接入采用 TProxy。

## 设计亮点

### 声明式策略与分层选路

NetFleet 把“访问需求”和“具体节点”分开管理。规则只需要选择稳定的能力，例如常规网络或具有地区要求的服务；机场和节点则作为可替换资源参与实时选择。这样一来，新增机场、节点改名或局部故障都不会迫使用户重写整套规则。

自动选择分为三层：

1. **地区**决定网络距离、内容可用性和连接体验；
2. **机场**代表相对独立的线路和额度，用于隔离故障；
3. **节点**由 Mihomo URLTest 在同一地区内完成快速切换。

每一轮都使用最新测量结果，并设置切换门槛，避免线路在细小延迟波动中来回跳动。历史数据用于帮助用户理解运行情况，当前选择始终以当轮可用性和实时测量为准。

### 微内核与插件热替换

NetFleet 将产品功能组织为 **19 个功能插件、69 个服务**。内核处理发现、服务绑定、依赖解析、调用准入和代码生命周期；订阅、选路、配置编译、恢复、后端与调度均通过服务组合运行。系统配置明确选择服务提供者，功能包可以独立开发、安装和更新。

可复用的业务服务通过存储、后端配置、凭据和进程等独立能力访问运行环境。OpenWrt 的具体实现由平台提供者承担，选择算法与控制流程、策略校验和调度可以通过服务绑定复用；跨平台分工见[平台能力边界](docs/architecture/microkernel.md#平台能力边界)。

插件有两种开发方式：**UCode 服务插件**通过声明依赖和 `context.use()` 组合能力；**进程插件**通过 Extension API v1 使用 Shell、Python 等设备支持的语言。两者共用安装目录、管理入口和软件包流程，任何符合协议的插件都能被发现、加载和热替换。

每次调用使用当前插件代码，升级先等待在途调用结束，新调用随即使用新版本。选优算法等不在 Mihomo 长期依赖链中的插件可独立更新，无需重启 Mihomo；资源插件自身或其依赖更新时，通过该资源插件的排空与恢复方法完成交接。

| 功能插件 | 作用 | 交付与运行方式 |
| --- | --- | --- |
| **默认网络功能** | 订阅、编译、选优、启停、恢复、配置和调度 | `opl-netfleet` 组合默认产品，每个功能插件独立打包 |
| **HTTPS 兼容** | 为指定设备和目标提供 HTTP/1.1 到 HTTP/2 的兼容转换 | 管理插件连接独立可选转换包；设备信任私有 CA 后显式接入，故障时旁路回原选路 |
| **Zashboard** | 查看 Mihomo 实时连接、流量、规则命中和代理组 | 独立 Dashboard 插件管理入口和资源；面板资源可单独更新，无需重启 Mihomo |
| **开发示例** | 读取设备信息与诊断 | `host-info` 演示服务依赖组合，`device-info` 演示多语言进程插件和生命周期 |

自有和第三方开发者使用同一套脚手架、声明校验、OpenWrt 软件包和签名分发流程。可直接从[插件开发与安装指南](docs/development/plugins.md)开始；服务与热替换合同见[微内核与功能插件](docs/architecture/microkernel.md)，进程接口与组件管理见[模块与扩展](docs/architecture/extensions.md)。

### 设备本地运行，恢复优先

UCode 运行服务在 OpenWrt 本地执行，Mihomo 负责连接和组内节点健康检查，LuCI 展示状态并提交受限操作。运行和恢复不依赖浏览器持续打开，也不要求云端控制器或 Node.js 宿主。

配置先校验、生成候选，再显式启用并检查真实运行结果。关闭或恢复时优先切回可独立运行的 Recovery Profile，无法恢复时由所选后端清理自身网络接管、恢复直通。恢复插件协调统一恢复路径，各资源插件承担自己的故障退出。

完整设计理念见[产品白皮书](docs/product/whitepaper.md)，当前实现与运行行为见[架构总览](docs/architecture/overview.md)。

安装支持的平台与可选包范围见所选 Release。

## 安装

### 准备工作

开始前，目标设备需要：

- 可用的 OpenWrt 软件包管理器；
- Mihomo 及该发布包要求的 OpenWrt 依赖；
- 原生接入：包含原生后端支持的包、可用上游 DNS 和一个有效机场订阅；接入前不得有其他代理核心占用网络；
- Nikki 接入：已正常运行的 Nikki、一份可独立使用的原生配置，以及至少一个有效订阅缓存。

在 OpenWrt 25.12 上，用一次性安装入口加入签名软件源并安装默认产品与 LuCI，软件包管理器会解析微内核和功能插件依赖：

```sh
uclient-fetch -q -O /tmp/install-netfleet.sh https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/install-netfleet.sh && sh /tmp/install-netfleet.sh
```

该命令只安装 APK 公钥、软件源和程序文件，不写入 policy、订阅或 Nikki mixin，也不自动接管网络。

安装完成后，打开 LuCI 的“服务 -> NetFleet”。空白设备先选择“首次接入 Mihomo”，明确确认下载订阅及网络接管；使用已运行 Nikki 时直接进入发现。随后进入共享首次设置：

1. 发现当前原生 Profile、机场缓存、地区和 `MATCH` 主入口组；
2. 检查当前环境并展示推荐配置；
3. 在用户确认后生成策略、编译配置并启动 NetFleet；
4. 回读运行状态和保护探针结果。

整个过程由设备本地完成。订阅 URL 和令牌保存在所选后端的私有配置中，不进入 policy 或公开状态。接管后可维护机场角色、地区映射、出口能力、业务绑定、域名与网段规则、自动周期和保护探针。原生订阅地址由独立“管理订阅”入口保存；修改来源不会自动停网，更新成功前继续使用上次可用缓存。

已有 Nikki 设备需要切换后端时，在“配置 -> 基础接入”选择“迁移到 NetFleet 原生后端”。迁移前检查真实资源和业务；成功后只运行原生后端，失败恢复旧后端，不长期双写。后端迁移与普通软件升级不是同一操作。

## 升级

LuCI 的“组件与更新”页显示组件安装版本、Mihomo 运行版本及关键依赖，可手动检查软件源。
NetFleet 按默认产品清单一起更新微内核、功能插件与 LuCI；第三方插件可以独立维护。原生后端的 Mihomo 单独确认更新，先验证当前配置，失败时恢复旧包和运行状态。不默认无人值守升级，也不升级整个系统。

同页的 Zashboard 区域独立检查和更新官方静态资源，不重启 Mihomo 或修改连接凭据。已安装版本来自有效安装记录或本地资源识别，无法识别时显示未知；检查更新后才展示可用版本。软件包、代理核心和面板资源分别确认，不隐式捆绑更新。

完整产品通过组件页升级。独立功能插件也可以直接从已配置的软件源定向更新，例如：

```sh
apk update && apk upgrade opl-netfleet-plugin-selection
```

升级保留现有策略、订阅缓存和系统服务绑定，软件包钩子负责代码替换前后的排空与恢复。升级后在组件页和状态页检查版本及运行结果；新配置仍通过显式应用生效。插件安装、升级和卸载步骤见[开发与安装指南](docs/development/plugins.md)。

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

创建并校验服务插件：

```bash
python3 scripts/netfleet-plugin.py scaffold my-plugin /tmp/my-plugin --kind service
python3 scripts/netfleet-plugin.py validate /tmp/my-plugin
```

使用 `--kind process` 创建进程插件。两种模板、服务组合示例、SDK 打包和签名安装流程见[插件开发与安装](docs/development/plugins.md)。

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
- [微内核与功能插件](docs/architecture/microkernel.md)
- [设备独立管理](docs/architecture/management.md)
- [模块与扩展](docs/architecture/extensions.md)
- [插件开发与安装](docs/development/plugins.md)
- [HTTPS 兼容模块](docs/architecture/https-compatibility.md)
- [UI 设计](docs/design/ui.md)
- [产品白皮书](docs/product/whitepaper.md)
- [开发与设备操作规则](AGENTS.md)

## 许可证

OPL NetFleet 默认采用 [Apache License 2.0](./LICENSE)，另有明确许可声明的文件除外。LuCI 等文件保留其 MIT 声明。包含 Nikki 派生模块的组合分发仍须遵循 [GNU GPL 3.0](openwrt/files/usr/share/opl-netfleet/nikki/LICENSE)。原有 NetFleet 文件的 Apache-2.0 声明继续保留，许可正文见 [Apache-2.0](openwrt/files/usr/share/opl-netfleet/LICENSE.Apache-2.0)；复用的 Nikki 模块保留其 GPL-3.0 许可证、版权、固定上游版本和[修改说明](openwrt/files/usr/share/opl-netfleet/nikki/NOTICE)。第三方原始声明不因组合分发而移除。
