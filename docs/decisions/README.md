# 架构决策

本目录只保留未来仍会影响设计取舍的决策理由。当前行为仍以
[架构文档](../architecture/overview.md)和真实实现为准；ADR 不作为任务状态或运行事实 owner。

- [0001：单一运行与 mutation owner](0001-single-runtime-owner.md)
- [0002：策略来源与恢复配置分离](0002-policy-source-and-recovery.md)
- [0003：React 参考开发、原生 LuCI 落地](0003-react-preview-native-luci.md)
- [0004：版本化 package 与 deployment bundle 分离](0004-package-and-deployment-bundle.md)
- [0005：Zashboard 只作为高级观察面](0005-zashboard-observation-surface.md)
- [0006：Nikki GPLv3 边界与第一阶段订阅编排](0006-nikki-gplv3-boundary.md)

新 ADR 应记录上下文、决定、后果、被拒绝的替代方案和重审条件。当前合同变化必须落到对应
architecture 文档；被完全取代的 ADR 只有在所有仍有价值的理由都转移后才可删除。
