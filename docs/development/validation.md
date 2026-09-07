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

## 插件与发布

插件脚手架和包生成按[插件开发](plugins.md)验证。发布候选必须完成同一 source 的签名包
安装、重复升级、运行、退出和卸载验证，再按[打包合同](../architecture/packaging.md)
取得公开资产回读。源码通过、VM 通过和发布成功各自只证明对应层面。
