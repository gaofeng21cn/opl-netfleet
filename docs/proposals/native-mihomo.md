# NetFleet 原生 Mihomo 与可替换后端

## 目标

让 NetFleet 从依赖已安装 Nikki 的独立分发产品，演进为能够直接管理订阅、Mihomo 生命周期和
OpenWrt 数据面的独立运行产品；在两个真实后端完成后，再从差异中提炼可替换后端合同。

## 当前差距

当前 `nikki-mihomo` 路径仍把 SubscriptionOwner、RuntimeBackend 和 OpenWrtDataPlaneOwner
委托给 Nikki/Mihomo。source 已有[原生订阅准备](../architecture/domain-model.md#原生订阅准备)，
及[原生核心显式代理生命周期](../architecture/runtime-and-recovery.md#原生核心生命周期)，
但没有完整原生网关激活链、sing-box adapter 或运行后端切换，不能把核心启动显示为整网接管。

## 最小实现顺序

1. 先实现一条完整的 `native-mihomo` 纵向链，覆盖订阅发现与缓存、配置生成、核心生命周期、
   controller 回读、DNS/nft/TProxy/路由激活和失败清理。
2. 复用当前 capability、provider、region、选择和恢复模型，不建立并行配置 owner 或双写。
3. 后端迁移作为受保护事务：验证新配置，建立 DIRECT 护栏，停止旧 owner，启动并探测新 owner；
   失败恢复旧 owner，成功且完成 target-local readback 后才提交身份。
4. 只有第二个真实后端满足同一安全合同后，才从真实差异中提炼 `RuntimeBackend` 接口。

## 数据面实验入口

在 Apple Silicon 开发机运行隔离的 ARM64 OpenWrt VM：

```sh
scripts/openwrt-vm.sh --ref origin/main --native-experiment --output /tmp/netfleet-native-experiment.json
```

实验通过正式原生来源 CLI 从隔离 HTTPS 服务下载订阅、校验并生成私有缓存，再交给现有
compiler、真实 Mihomo 和 procd，LAN 客户端位于独立网络
命名空间。fw4 为实验接口提供明确的区域，临时 nft TProxy/DNS 规则和 policy route 负责
IPv4 截获；正常停止先撤截获再结束进程，核心意外退出时由其前台 owner 清理截获。
实验还检查重复启动冲突、重复停止、无效配置、无截获时的反证请求、节点实际流量、
停止与崩溃后的直通请求，以及不属于运行 owner 的规则原样保留。

这不是安装包里的第二后端，也不修改现有产品的 Nikki 生命周期。实验回执使用独立 schema，
始终包含 `qualified=false`、`production_ready=false`；不能配合 `--packages`，不能被用于
生产激活。默认 VM/package qualification 不增加本实验的耗时。

此入口验证正式来源准备、核心显式代理启停以及原生 IPv4 数据面原语；它不证明完整网关启停与
周期选优接线、IPv6、路由器自身流量、fw4 reload、owner 进程强杀、开机恢复、包卸载、
Nikki 迁移或 Zashboard 资源管理已经实现。正式路径还必须将这些责任收敛到现有 mutation
owner，不能复制实验脚本作为常驻第二控制器。

## 准入条件

- 未启用和任何失败路径都能恢复 OpenWrt 网络直通；
- 订阅秘密不进入浏览器、日志、Git 或公共 package；
- 同一订阅、代理核心和数据面在任一时刻都只有一个 writer；
- 配置校验、原子启用、owner readback、disable、卸载和失败清理都有真实 target 证据；
- 不以并行运行多个代理核心或长期双写作为迁移 fallback。

## 吸收条件

当 `native-mihomo` 的真实 caller、source、配置 owner 和完整验收存在时，将对应当前合同分别
吸收到 architecture 的 domain model、runtime、interfaces 和 packaging 文档；本 proposal 随后删除。
