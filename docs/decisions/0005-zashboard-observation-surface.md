# 0005：Zashboard 只作为高级观察面

## 上下文

Zashboard 已能成熟展示 Mihomo 的实时连接、流量、内存、规则命中、代理组和 Provider。NetFleet
重写这些界面成本高且容易形成第二套 Mihomo 状态解释，但直接暴露 controller 又会泄漏 secret
并允许绕过 NetFleet 的 mutation owner。

## 决定

Zashboard 的长期角色是 `ObservationSurface`，不是配置、运行或恢复 owner。稳定摘要和受保护
命令继续由 NetFleet 页面负责；Zashboard 仅在兼容后端下按需加载，通过同源 ACL 桥接读取
controller。任何写操作默认拒绝；未来若允许临时 selector 调整，也必须经过 NetFleet 校验、
加锁和 readback。

## 后果

NetFleet 可以复用成熟实时观察体验，同时保持秘密和唯一 mutation owner；在桥接、静态资源、
只读能力和真实 caller 完成前，生产 UI 不显示“实时运行”入口。

## 未采用

- 把 controller secret 写入 URL、页面源码或浏览器存储；
- 允许 Zashboard 直接修改内部组、持久配置、核心生命周期或升级；
- 为非 Mihomo 后端伪装 Mihomo API。

## 重审条件

若上游 Zashboard 无法关闭写能力或适配同源桥接，则不嵌入该版本；只有新的观察实现提供相同
信息且更好满足设备资源、ACL 和秘密边界时，才重新评估前端选择。
