# NetFleet 原生 Mihomo 与可替换后端

## 目标

让 NetFleet 从依赖已安装 Nikki 的独立分发产品，演进为能够直接管理订阅、Mihomo 生命周期和
OpenWrt 数据面的独立运行产品；在两个真实后端完成后，再从差异中提炼可替换后端合同。

## 当前差距

当前 `nikki-mihomo` 路径仍把 SubscriptionOwner、RuntimeBackend 和 OpenWrtDataPlaneOwner
委托给 Nikki/Mihomo。source 没有原生订阅 owner、`native-mihomo` 激活链、sing-box adapter
或运行后端切换，因此这些能力不得出现在当前 UI 或发布说明中。

## 最小实现顺序

1. 先实现一条完整的 `native-mihomo` 纵向链，覆盖订阅发现与缓存、配置生成、核心生命周期、
   controller 回读、DNS/nft/TProxy/路由激活和失败清理。
2. 复用当前 capability、provider、region、选择和恢复模型，不建立并行配置 owner 或双写。
3. 后端迁移作为受保护事务：验证新配置，建立 DIRECT 护栏，停止旧 owner，启动并探测新 owner；
   失败恢复旧 owner，成功且完成 target-local readback 后才提交身份。
4. 只有第二个真实后端满足同一安全合同后，才从真实差异中提炼 `RuntimeBackend` 接口。

## 准入条件

- 未启用和任何失败路径都能恢复 OpenWrt 网络直通；
- 订阅秘密不进入浏览器、日志、Git 或公共 package；
- 同一订阅、代理核心和数据面在任一时刻都只有一个 writer；
- 配置校验、原子启用、owner readback、disable、卸载和失败清理都有真实 target 证据；
- 不以并行运行多个代理核心或长期双写作为迁移 fallback。

## 吸收条件

当 `native-mihomo` 的真实 caller、source、配置 owner 和完整验收存在时，将对应当前合同分别
吸收到 architecture 的 domain model、runtime、interfaces 和 packaging 文档；本 proposal 随后删除。
