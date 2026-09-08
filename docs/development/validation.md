# 开发验证

本文负责选择和执行仓库已有验证入口。它不记录通过次数、设备快照或测试完成状态；
当前行为由架构 owner 定义，具体测试以源码入口为准。

## 源码与 UI

在仓库根目录运行 `scripts/check-fast.sh`，它检查 Git 空白错误、Python source/package/UI
合同，并在本机有 UCode 时调用 `scripts/check-mvp.sh`。UCode 缺失会明确提示延期，不能
把这部分视为通过。`scripts/check-full.sh` 加入完整 fake-device 部署矩阵；前端调整使用
`scripts/check-ui.sh`。只改文档时检查相对链接、引用资产、示例命令是否存在与
`git diff --check`，不以 Markdown 关键词或固定文本判断语义。

算法证据的入口是 `tests/selection_contract.uc`、`tests/adapter_contract.uc` 和
`tests/compiler_contract.uc`；运行、状态和显示聚合分别由 `tests/activation_contract.uc`、
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

默认完整 suite 在独立 VM 中验证原生运行、首次设置和 Nikki 迁移；软件包候选增加独立
安装 lane。`--diagnostic` 只用于定位单条路径，不能授权部署。管理、组件和传输子阶段
由对应 guest 脚本编排，不是任意可选的正式准入门禁。数据面变更的候选须完成完整
qualification，HTTPS 模块另用自己的包与故障演练。
这些都是 synthetic platform proof；真实 provider、DNS、TPROXY、硬件和应用验收按
[Canary 推广与复原](../operations/canary-promotion.md)独立完成。

runtime lane 记录 30 次状态请求的 p50/p95，以及至少 60 秒监督器 CPU/RSS 采样；
预热后 RSS 增长超过 2 MiB 会失败，回执保留预热值、峰值和最终值以便比较。
这是有界性能基线，不是路由器吞吐或长期稳定性结论。`maintenance_device.uc` 在真实
OpenWrt 文件系统上验证插件私有数据与实例组合的备份往返、旧格式保留和失败恢复。

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
