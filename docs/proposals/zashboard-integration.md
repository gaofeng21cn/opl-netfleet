# Zashboard 高级观察面集成

## 目标

在使用 Mihomo 的后端下提供成熟的实时连接、流量、规则命中、代理组和 Provider 观察体验，
避免 NetFleet 重复实现完整 dashboard。

## 当前差距

当前 package 不包含 Zashboard 静态资源，也没有受 LuCI ACL 约束的 controller HTTP/WebSocket
同源桥接。`dashboard_lan_ready` 只表示既有 controller 诊断条件，不代表浏览器已经被授权。
因此当前生产 UI 只能提供有限的只读连接投影，不能显示“实时运行”入口。

## 最小实现

1. 选择并锁定一个能够关闭写操作、适配同源桥接的 Zashboard 版本，随 package 提供静态资源，
   不依赖公网 CDN。
2. 新增受 LuCI 登录态和 ACL 保护的 HTTP/WebSocket 桥接，controller secret 只留在设备 owner。
3. 默认只读连接、流量、内存、规则、代理组和 Provider；拒绝配置重载、核心启停、升级、连接
   关闭和 raw controller mutation。
4. 仅在用户打开“实时运行”页时加载，不增加常驻前端进程或 NetFleet 后台轮询。
5. 仅当当前后端声明兼容观察能力时显示入口；非 Mihomo 后端使用自己的观察适配器，不伪装 API。

## 可选 selector 调整

若真实需求要求临时改路，只能操作 manifest 明确公开的用户 selector，并经 NetFleet RPC 校验、
mutation lock 和 owner readback；Zashboard 不能直接写内部组或持久配置。此能力不是只读集成的前置。

## 验收与吸收

必须验证 ACL、secret 不出设备、WebSocket 断连、只读写拒绝、按需资源加载、设备资源占用和真实
LuCI DOM。完成后把当前接口和 UI 合同吸收到 architecture 与 UI 设计文档，再删除本 proposal。
