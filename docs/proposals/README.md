# 待实现方案

本目录只保存已经形成产品方向、但尚未进入当前实现和架构合同的方案。proposal 不是当前能力、
发布承诺或任务进度；是否实现仍由真实 caller、owner、最小纵向链和验收证据决定。

方案实现后，应把已经成立的当前合同吸收到 `docs/architecture/`，保留仍有未来决策价值的理由
到 `docs/decisions/`，然后删除对应 proposal。被拒绝的方案仅在能够防止高概率重复错误时保留。

## 提案列表

- [`opl-netfleet-cloud.md`](opl-netfleet-cloud.md)：跨多站点集中性能监视与加密机场订阅子集下发的云端控制面（`opl-netfleet-cloud`）及设备同步插件方案。
- [`openwrt-release-bundle-delivery.md`](openwrt-release-bundle-delivery.md)：通过「薄系统包壳（`.apk`/`.ipk` 零 SDK 产包）+ 纯源码签名 Release Bundle + 原子符号链接切换」解决跨 OpenWrt 24.10/25.12 兼容与多包升级回滚脆弱问题。
