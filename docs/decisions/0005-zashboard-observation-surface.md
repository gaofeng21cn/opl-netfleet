# 0005：Zashboard 作为独立完整运行面

## 上下文

Zashboard 已能成熟展示并操作 Mihomo 的实时连接、流量、内存、规则命中、代理组和 Provider。
NetFleet 重写这些界面成本高且容易形成第二套 Mihomo 状态解释；把它裁成只读嵌入页也会失去
用户选择完整 Zashboard 的主要价值。当前 Nikki 已经拥有静态资源、controller 配置和经过使用
验证的 `openDashboard()` 打开方式。

## 决定

Zashboard 是独立、完整的 Mihomo 实时运行面，不嵌入 NetFleet 内容区。NetFleet 负责统一产品
导航、就绪判断和打开动作；过渡期直接调用 Nikki 官方 `openDashboard()`，由 Nikki 继续拥有静态
资源、controller 和 secret 到 URL 的组装，NetFleet 不复制这些状态。Zashboard 内的 selector
切换和连接管理属于 Mihomo 当前运行态；NetFleet 仍唯一拥有持久 policy、订阅编排、服务启停
和恢复事务。

未来 `native-mihomo` 替换 Nikki 后，dashboard 资源、controller 配置和打开入口一并迁入 NetFleet，
但保持独立页面和完整能力，不改变用户入口，也不并行运行第二 controller。

## 后果

NetFleet 可以直接复用成熟运行体验，并通过一个稳定入口把自有策略管理面与 Mihomo 实时面组织
为同一产品。当前 Nikki 方式会让 controller secret 出现在新标签页 URL，因此该 URL 是带凭据的
临时地址；NetFleet 不记录、不缓存、不展示它。用户从 Zashboard 发出的即时操作不会自动写回
NetFleet 配置，刷新或重新编译后仍以 NetFleet policy 为准。

## 未采用

- 在 NetFleet 内容区嵌入或复制 Zashboard；
- 为过渡期另建静态资源副本、controller 或同源代理；
- 把 Zashboard 的即时运行态操作当成 NetFleet 持久配置；
- 为非 Mihomo 后端伪装 Mihomo API。

## 重审条件

当 NetFleet 原生拥有 Mihomo controller 时，重新评估不在 URL 携带 secret 的认证方式；只有
另一运行面能保留 Zashboard 的完整能力、资源效率和独立页面体验时，才重新评估前端选择。
