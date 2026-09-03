# NetFleet 文档

本目录按语义 owner 组织文档。阅读当前实现从[架构总览](architecture/overview.md)开始；
理解长期方向从[设计白皮书](product/whitepaper.md)开始。

## 当前事实

- [`architecture/`](architecture/overview.md)：当前产品对象、选择、运行、接口和打包合同。
- [`design/ui.md`](design/ui.md)：React 参考面与原生 LuCI 的视觉和交互设计合同。
- [`operations/canary-promotion.md`](operations/canary-promotion.md)：通用 canary 推广与恢复流程。

## 目标与理由

- [`product/whitepaper.md`](product/whitepaper.md)：产品理念、理想形态和长期方向，不定义当前能力。
- [`proposals/`](proposals/README.md)：已经形成方向但尚未成为当前合同的技术方案。
- [`decisions/`](decisions/README.md)：未来仍有价值的决策理由、替代方案和重审条件。

## 不在这里管理的内容

任务状态、负责人、百分比和逐次执行记录归 OPL Flow、Issue 或任务系统；历史变化归 Git。
实现陷阱应进入测试、代码注释或 `AGENTS.md`，私有设备拓扑和部署经验归 private OPL
Instance 或 `AGENTS.local.md`。本目录不建立 archive、会话日志或第二套状态系统。
