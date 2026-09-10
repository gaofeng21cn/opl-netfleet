# NetFleet 文档

本目录按语义 owner 组织文档。阅读当前实现从[架构总览](architecture/overview.md)开始；
理解长期方向从[设计白皮书](product/whitepaper.md)开始；查看平台差异从
[平台实现层](platform/README.md)开始。

## 当前事实

- [`architecture/`](architecture/overview.md)：当前产品对象、选择、运行、接口、状态呈现、显示证据和打包合同。
- [`architecture/microkernel.md`](architecture/microkernel.md)：功能服务组合、依赖绑定、插件热替换与资源交接。
- [`architecture/device-identity.md`](architecture/device-identity.md)：网络侧设备身份、IPv6 地址更新和证据过期。
- [`product/capabilities.md`](product/capabilities.md)：能力清单与平台归属，连接功能规划与各平台实现。
- [`platform/`](platform/README.md)：跨平台实现层入口，以及各平台机制事实的当前 owner。
- [`platform/macos.md`](platform/macos.md)：macOS 机制事实、私有状态、流量接管与恢复边界。
- [`design/ui.md`](design/ui.md)：React 参考面、原生 LuCI 与 macOS 客户端的视觉和交互设计合同。
- [`operations/deployment.md`](operations/deployment.md)：按后端与设备状态选择安装、更新、迁移入口，以及 Nikki Fleet 事务。
- [`operations/canary-promotion.md`](operations/canary-promotion.md)：通用 canary 推广与恢复流程。
- [`development/validation.md`](development/validation.md)：源码、UI、隔离 OpenWrt、发布验证，以及实体性能评估方法。
- [`development/plugins.md`](development/plugins.md)：插件接口、开发模板、软件包构建、安装与热加载。
- [`development/macos.md`](development/macos.md)：macOS 本机构建、启动与验证。

## 目标与理由

- [`product/whitepaper.md`](product/whitepaper.md)：产品理念、理想形态和长期方向，不定义当前能力。
- [`proposals/`](proposals/README.md)：已经形成方向但尚未成为当前合同的技术方案。
- [`decisions/`](decisions/README.md)：未来仍有价值的决策理由、替代方案和重审条件。

## 不在这里管理的内容

任务状态、负责人、百分比和逐次执行记录归 OPL Flow、Issue 或任务系统；历史变化归 Git。
实现陷阱应进入测试、代码注释或 `AGENTS.md`，私有设备拓扑和部署经验归 private OPL
Instance 或 `AGENTS.local.md`。本目录不建立 archive、会话日志或第二套状态系统。
