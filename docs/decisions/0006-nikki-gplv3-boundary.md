# 0006：Nikki GPLv3 边界与第一阶段订阅编排

## 上下文

Nikki 上游是 GPLv3。NetFleet runtime package 是 Apache-2.0，LuCI 是 MIT。若把 Nikki
源码、init、mixin 或 LuCI/RPC 实现复制进本仓库，会把 GPLv3 传染到 Apache/MIT 分发物。
同时，第一阶段需要稳定发现已启用订阅并安全刷新缓存，但不能变成第二个下载器，也不能
接管 Mihomo、DNS、nft 或路由。

## 决定

只把已安装的 Nikki 进程当作协议/生命周期边界：通过稳定 UCI section 名称和官方
`/etc/init.d/nikki update_subscription <section>` 调用刷新。NetFleet 可以快照、校验摘要、
拒绝空/损坏内容并恢复上一份已验证 cache，但 cache 路径、URL/token、下载和单机场原子
替换仍由 Nikki 拥有。仓库、package、日志、fixture 和浏览器不得包含 Nikki GPLv3 源码，
也不得包含订阅 URL/token 或订阅正文。

第一阶段 SubscriptionOwner 因此只覆盖只读发现、脱敏投影和唯一 mutation owner 内的
refresh 编排。它不是白皮书中的完整独立订阅 owner，也不授权 native Mihomo 或 OpenWrt
数据面迁移。

## 后果

refresh 和 status 可以给出每个稳定 section 的 `display_name`、`cache_present`、
`cache_sha256`、`quota`、`last_attempt`、`last_success` 和 `last_result`，同时保持单一
writer 与单一设备锁。后续若要不再依赖 Nikki，必须先有完整 successor
接管订阅 cache、运行后端、数据面和安全清理，而不是在本仓库内 vendor Nikki。

## 未采用

- 把 Nikki GPLv3 源码、init 或 LuCI 复制进本仓库再改；
- 建立第二套订阅 cache、selector、cleanup 或 generic multi-backend 抽象；
- 让浏览器持有 token，或在 RPC 中接受 URL/section/订阅内容。

## 重审条件

只有 successor 已完整拥有订阅发现/缓存、Mihomo 生命周期和 OpenWrt 数据面，并通过同一
恢复合同后，才可以停止调用 Nikki 官方 updater；GPLv3 源码仍不得进入本仓库。
