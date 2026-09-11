# 开发验证

本文负责选择和执行仓库已有验证入口。它不记录通过次数、设备快照或测试完成状态；
当前行为由架构 owner 定义，具体测试以源码入口为准。

## 双平台修改与集成

日常开发使用 `scripts/check-fast.sh`，缺少工具会明确列出未执行项；集成使用
`scripts/check-platform.sh shared`，要求 Python、Bun、Node、UCode 与 fs/socket 模块齐备，
缺失直接失败。两者复用同一套源码检查，不维护第二份用例名单。

| 改动 | 必需验证 |
| --- | --- |
| 共享模型、编译、选择、恢复或服务合同 | 严格 shared 检查；两端受影响的真实调用；改变 OpenWrt 行为时取得同源码 QEMU 资格 |
| 平台实现、宿主和系统集成 | 对应平台完整入口；共享服务签名变化再覆盖另一端 |
| 共同界面词汇、状态或交互 | UI 测试与两个渲染入口；实际页面交互不能由 fixture 成功代替 |
| 仅文档归属 | 回读唯一 owner、相对链接与锚点、示例及空白检查 |

`.github/workflows/netfleet-check.yml` 在 main 提交与 PR 中执行 Linux shared 检查和
macOS arm64 完整检查。Linux 的 `scripts/bootstrap-ucode.py` 与 macOS 构建器读取同一
UCode 固定源码身份，Linux 使用系统 json-c 构建测试运行时；只写用户缓存。Linux shared
检查不声称已经运行 OpenWrt 的 UCI/procd 合同，后者必须通过下文 QEMU 入口。
macOS 完整入口为 `scripts/check-platform.sh macos`，复用 shared 检查、真实 Mihomo 隔离
链路、进程崩溃回收、React 客户端、应用构建和 helper 自检。HTTPS 资格探针需要公网访问，
不安装 helper、不修改系统网络。远端 CI 不发布安装包，也不部署设备。

共享源码目前位于 `openwrt/files/usr/libexec/opl-netfleet`，不能按目录名判断修改仅影响
OpenWrt。新平台差异首先落到现有能力接口及组合根；平台适配器不重写业务算法或策略合并。
公共模型使用同一组正例、负例和输入不变性用例；适配器另验证真实存储、运行与失败恢复，
不要求两个操作系统生成逐字相同的路径、时间格式或错误原语。

## 源码与 UI

在仓库根目录运行 `scripts/check-fast.sh`，它检查 Git 空白错误、Python source/package/UI
合同，并在本机有 UCode 时调用 `scripts/check-mvp.sh`，在有 Bun 时调用 `scripts/check-ui.sh`
并构建桌面生产入口，在有 Node 时运行 macOS 桌面运行契约。每个缺失工具都会明确提示延期，
不能把延期项视为通过。`scripts/check-full.sh` 加入完整 fake-device 部署矩阵。只改文档时
检查相对链接、引用资产、示例命令是否存在与 `git diff --check`，不以 Markdown 关键词或
固定文本判断语义。

两个平台共用一个内核与业务插件，但各有自己的组合根：OpenWrt 读
`openwrt/files/usr/share/opl-netfleet/system.json`，macOS 读 `desktop/ucode/system.json`
并叠加 `desktop/ucode/plugins`。`tests/test_platform_composition.py` 按内核的服务解析语义
静态检查两个组合根：绑定是否指向已启用且确实提供该服务的插件、依赖闭包与版本是否可解析、
桌面宿主调用的命令是否由 macOS 组合根声明。它不需要 UCode、设备或已构建应用，因此共享
插件新增平台依赖时会在源码门禁暴露，而不是等到某个平台运行时才失败。

`UCODE` 与 `UCODE_LIB` 把共享源码门禁指向非默认位置的 UCode 运行时与模块目录，因此本机
macOS 也能先跑共享业务合同，不必等到 QEMU。宿主原语只存在于对应平台：
`adapter_contract.uc`、`backend_contract.uc` 与 `operation_contract.uc` 依赖 OpenWrt 的
libuci 和 `/proc`，其他机器上由 `check-mvp.sh` 明确列为延期，不能视为通过；OpenWrt 侧
继续由 QEMU lane 的全量 `tests/*_contract.uc` 执行，它是 `set -eu`，任何合同失败都会中断
该阶段。

算法证据的入口是 `tests/selection_contract.uc`、`tests/adapter_contract.uc` 和
`tests/compiler_contract.uc`；三模式切换与失败恢复由 `tests/operating_mode_contract.uc` 覆盖；运行、状态和显示聚合分别由 `tests/activation_contract.uc`、
`tests/status_contract.uc`、`tests/evidence_contract.uc` 覆盖。它们分别证明纯函数、
平台响应映射与生成合同；不证明某台设备的实时延迟、业务或网络恢复。

微内核组合的源码入口为 `tests/scope_contract.uc`、`tests/host_adapter_contract.uc` 和
`tests/composition_contract.uc`，分别验证资源撤销、显式平台注入及插件动作、实例、绑定和
生命周期。它们已由 `check-mvp.sh` 调用，可在提供相应 UCode 模块的原生开发环境运行；
不会因开发机可运行共享逻辑就推断完整平台宿主已经可发布。

组合合同同时覆盖私有锁隔离、过期预览拒绝和部分恢复失败后的资源二次暂停、原配置
回滚；摘要缓存测试验证命中、过期、损坏、权限变化和调用前重新检查。管理界面测试
覆盖服务写动作、组合确认以及跨页工厂复用与独立权限。

## 隔离 OpenWrt

运行 `scripts/openwrt-vm.sh --help` 确认当前命令与模式；qualification 入口在
`scripts/openwrt-vm/qualify.sh`。Apple Silicon macOS 路径使用原生 ARM64 QEMU/HVF 与
官方 OpenWrt armsr/armv8 镜像。一次性镜像可以扩容，原缓存镜像及设备磁盘不改写。
receipt 绑定精确 commit/tree、runner/guest 架构、QEMU、accelerator 和阶段结果；
不能用测试文件存在或 VM 启动替代完整 qualification。
固定规则集由宿主机按 lock 下载和缓存，随校验过的载荷传入 VM；运行夹具再次核对
大小与摘要，避免网络故障演练中重新依赖公网下载。
官方包下载不稳定时，可设置 `NETFLEET_VM_PACKAGE_MIRROR=http://192.168.1.2:<port>`，
让一次性 guest 通过宿主提供的官方文件镜像取得依赖；路径与文件内容须保持原样，
APK 继续验证官方签名。该设置只修改 VM 的官方包源传输，回执记录使用了本地镜像，
不能作为真实设备的公网链路验收，也不能关闭签名校验。

默认完整 suite 在独立 VM 中验证原生运行、首次设置和 Nikki 迁移；软件包候选增加独立
安装 lane。`--diagnostic` 只用于定位单条路径，不能授权部署。管理、组件和传输子阶段
由对应 guest 脚本编排，不是任意可选的正式准入门禁。数据面变更的候选须完成完整
qualification，HTTPS 模块另用自己的包与故障演练。
`NETFLEET_VM_PACKAGE_BASELINE` 指向迁移前的真实签名 APK 集合与 `baseline.pem` 公钥。
集合必须包含旧主包、LuCI 和目标上已安装的旧 HTTPS 引擎；关闭引擎不会消除它对包
依赖排序的影响。未带该引擎的迁移结果不能用于带引擎的设备。外部部署执行器的回退
不由包测试代为证明，须以同一执行器、旧包集合和实际失败阶段单独验证。
原生 HTTPS lane 在不安装 Python 的 guest 中运行 `tests/https_native_network.sh`，覆盖双栈协议转换、地址证据全部失效与恢复、流式请求及故障旁路。
真实旧版本迁移向该脚本传入第二参数目录，内含 `old`、`new` 精确 APK 集合及 `dependencies` 离线官方签名索引与依赖包，由 `tests/https_native_upgrade.sh` 验证依赖拒绝、升级、可选包回退和重新升级。后端与平台先完成独立更新；可选插件回退不得同时倒退后端，须保持基础网络、核心进程、私有配置和 CA。
组件安装检查在真实签名包的 pre-upgrade 阶段终止事务进程树，清除临时进度并破坏已安装入口，
通过保留的恢复入口验证旧文件、包数据库、私有输入、选路和保护探针；另验证终态已持久化但
pending 未清除时的恢复。这是软件中断故障注入，不是物理断电或闪存损坏测试。
这些都是 synthetic platform proof；真实 provider、DNS、TPROXY、硬件和应用验收按
[Canary 推广与复原](../operations/canary-promotion.md)独立完成。

runtime lane 记录 30 次状态请求的 p50/p95，以及至少 60 秒监督器 CPU/RSS 采样；
预热后 RSS 增长超过 2 MiB 会失败，回执保留预热值、峰值和最终值以便比较。
这是有界性能基线，不是路由器吞吐或长期稳定性结论。性能比较必须分别读取
`lanes.runtime.metrics` 与 `lanes.package-runtime.metrics`：顶层 `metrics` 是源码 runtime
lane 的投影，不能用它替代签名包的安装运行结果。`supervisor_cpu_milli_percent` 除以
1000 才是百分比，RSS 字段单位为 KiB；预热、峰值与最终值分别保留，最终值低不代表
没有瞬时峰值。

`tests/maintenance_device.uc` 在真实 OpenWrt 文件系统上验证插件私有数据与实例组合的备份往返、旧格式保留和失败恢复。

## 实体设备性能评估

在同一设备、相同策略与网络条件下比较候选和基线，记录硬件、核心版本、插件组合、
机场/地区/节点数量及并发负载。控制面测量应覆盖冷启动与缓存命中的读取、编译、选路、
组合应用和包更新；热替换分别记录调用排空时间、资源恢复时间和业务中断时间。

数据面独立测量 IPv4/IPv6、DNS、TCP/UDP TProxy、吞吐、并发连接和关键业务长连接；
同时观察核心与宿主进程树的 CPU/RSS、文件描述符、连接数及临时空间。HTTPS 兼容模块
启用与旁路分别测量上传、SSE 和取消。扩大订阅与实例规模，检查控制面并发读取和插件
私有写入是否拖延网络恢复；持续运行及反复更新后检查资源是否回到稳定水平。

`profile-openwrt.uc [1..30]` 在设备端通过真实 status caller 分段记录宿主加载、controller 读取、
网关核验、订阅投影和状态计算的 p50/p95；仅输出软件身份、对象数量和耗时，不输出节点或配置。
分段存在嵌套，不能相加当总耗时；总耗时包含加载。`observe-openwrt.uc` 记录冷入口状态延迟，
以及 CPU ticks、RSS 和文件描述符的起点、峰值、终点，便于同设备更新前后比较。

完整 native QEMU lane 还执行 `tests/native_workload.sh`：双栈四路并发 8 MiB 传输、30 秒流式
连接与同时进行的状态读取，校验完整载荷、事件数量及核心 PID。它复用隔离网络的真实 TProxy 路径；
既有 LAN/本机 IPv4/IPv6 DNS 与 TCP/UDP 正反对照继续保留。此负载是可重复的有界兼容性基线，
不作为物理链路吞吐上限或数日稳定性的结论。真实设备不自动执行该负载脚本。

`ucode tests/benchmark-scale.uc` 以 300、3000、15000 个合成节点、3 个机场和20 个地区，重复验证真实候选解释与选择算法，输出 p50/p95；这是共享计算基线，不执行机场下载或网络测速。饱和吞吐和数日长稳仍属于上述按需评估方法。比较报告保存在私有验收证据中，不能
将某次 VM 延迟写成产品 SLA，也不能用空闲 CPU 代替真实转发性能。可能影响联网的负载
和故障试验先在隔离环境执行，实体设备范围依照[canary 流程](../operations/canary-promotion.md)。

## 插件与发布

插件脚手架和包生成按[插件开发](plugins.md)验证。发布候选必须完成同一 source 的签名包
安装、重复升级、运行、退出和卸载验证，再按[打包合同](../architecture/packaging.md)
取得公开资产回读。源码通过、VM 通过和发布成功各自只证明对应层面。

`tests/test_plugin_sdk.py` 覆盖完整模板、仓库外打包、动作和页面引用、配置读写与资源
安装。配置 `UCODE=/path/to/ucode` 后同一入口执行 `workspace-note` 的实际工厂，验证
持久化、重新加载、过期提交拒绝、损坏文件保护和作用域清理；`host-info` 的 `/proc`
检查仅适用于 Linux。

`scripts/openwrt-vm/plugin-fixtures.py <output> --sdk <sdk>` 在隔离 Linux/amd64 SDK
构建容器中从实际示例生成两版签名 APK；输出目录必须不存在。将输出传给
`scripts/openwrt-vm.sh --ref <commit> --diagnostic native --plugin-packages <output> --output <receipt>`，
验证通用 RPC、配置保存、升级保留与卸载清理。省略 `--diagnostic native` 并增加
`--packages <candidate>`，可在完整产品 qualification 中同时执行这些插件安装检查。

插件页面通过共享宿主测试验证清单导航、实例与权限绑定、失败处理和资源撤销。真实浏览器
验收还需完成独立插件读取、编辑保存、只读访问、切页、热更新和卸载。热更新必须包含一个
静态 import 子模块：修改子模块而保持页面入口不变，确认新的 revision 目录执行新内容，
旧页面作用域已关闭。只验证 URL 字符串或根模块重新加载不能替代这条完整模块图验收。

原生 DNS 健康读取由 `tests/test_backend_health.py` 使用真实本地 UDP socket 验证：合法 NXDOMAIN、无应答超时、错误 ID、截断和非法响应。运行该测试需要 `ucode` 和 socket 模块；本地可通过 `UCODE`、`UCODE_LIB` 指定。完整 QEMU 原生链路还通过 `tests/native_runtime_integration.uc` 验证正式 gateway 生成的本地 DNS policy、真实应答及 backend 就绪结果。

有限插件更新验收覆盖精确包集合、资格与源码身份、旧版漂移、签名/架构、额外归档拒绝、
world 约束恢复、无资源 owner 插件更新时核心 PID 不变，以及共享模型和组件管理自身升级后的依赖资源恢复。共享模型处于核心依赖链，更新遵循生命周期排空和恢复，不承诺核心 PID 不变。真实设备验收使用 LuCI 原生入口
完成导航及明细展开，不能以 React fixture 或 RPC 成功替代浏览器交互。
`observe-openwrt.uc` 只做有界状态读取与保护探针，记录状态 p50/p95、监督器/核心 PID、
进程 CPU ticks 和 RSS；这些值不等于带宽上限或长期稳定性。操作窗口见
[Canary 流程](../operations/canary-promotion.md)。
