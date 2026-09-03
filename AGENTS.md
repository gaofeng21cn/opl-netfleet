# OPL NetFleet

[设计白皮书](docs/product/whitepaper.md)只说明设计理念和理想形态；[当前架构](docs/architecture/overview.md)及其主题子文档是当前产品对象、运行 owner、行为和安全合同的唯一架构 SSOT；[README.md](README.md) 只描述当前真实可用表面。本文件只维护开发、设备操作和文档生命周期约束。

当前仓库已经包含[当前架构](docs/architecture/overview.md)定义的可安装 MVP runtime 和部署入口。新增任何代码、配置、协议、依赖、测试或 UI 前，必须先证明它属于当前真实 caller；不得把历史实现、task branch 或设备残留重新吸收为当前架构。

## 修改边界

- 修改前回读真实 caller、当前 source、目标 owner surface 和生效位置。历史代码、文档、测试、CI 或其他 target 状态不能替代 live readback。
- 第一条实现只建立 target-local `compile -> enable -> owner readback -> disable` 纵向链。没有真实仓外 caller 时，不增加 Python facade、Cordis Host、worker、公开 schema 或兼容版本。
- provider source、节点、生成配置和 owner snapshot 留在设备私有 state。Git 只保存当前实现真正消费的脱敏合同、package source 和测试。
- 退役接口前必须证明 successor 已接管真实 caller；caller-zero 后在同一批次删除实现、配置、测试和文档，不保留 alias、fallback 或兼容字段。
- 产品对象、选择算法、Fail-Open 语义、运行 owner 或公开协议变化必须先更新 [docs/architecture/](docs/architecture/overview.md) 中拥有该主题的唯一文档，再修改实现和 surface。

## 设备与秘密

- 默认设备命令只读。外部写入必须绑定精确 target、全局 single writer、fresh precondition、target-local rollback/reconcile 和最终 owner-authoritative readback。
- 每个 target 独立授权；一个 target 的 plan、canary 或成功不能授权另一个 target。
- DIRECT-first 是硬下限：失败和回滚不得遗留 DNS/nft 劫持、半启用服务或不可恢复外部写入。
- 个人或部署实例专属的 target 名称、拓扑、SSH route、跳板、地址和事故记录只能写入 Git 忽略的根目录 `AGENTS.local.md` 或 private Instance。任何设备操作前必须先完整读取存在的 `AGENTS.local.md`；文件不存在表示本机没有补充的私有 target 上下文，不得猜测或从其他 target 推断。
- 术语固定：private OPL Instance 是 owner-specific desired configuration 的唯一权威；部署器 `--instance <dir>` 读取的四文件目录只叫 deployment bundle，是可再生成的投影，不是 Instance、SSOT 或手工编辑位置。具体 private Instance 路径只能写入 `AGENTS.local.md`。
- 远程 transport、target 端口和服务进程是独立证据层；单一超时或其他端口可达不授权重启服务、修改认证参数或新增远程访问 daemon。
- NetFleet 的开发、部署、验收和远程恢复永远不授权 `reboot`、`poweroff`、`sysupgrade`、`firstboot`、固件/eMMC 写入或依赖现场/OOB 才能撤销的操作。软件恢复无法重新证明管理面时立即停止并返回 `needs_local_recovery`；只有用户针对精确设备重新授权且现场或 OOB owner 已就绪后，才可另行处理物理恢复。
- 不提交 console/site ID、API key、SSH route、订阅 URL/token、节点、resolver、入口地址、完整配置、扫描数据库、设备日志或 operation receipt。

## YAML 与 yq 边界

- `yq` 只允许用于只读 YAML -> JSON 转换：`yq -M -p yaml -o json <input>`。
- 禁止 `yq -i`、`eval-all`、复杂 `any/any_c` 表达式、依赖 shell 插值的程序，以及直接修改 Nikki subscription、active Profile 或 runtime config。
- policy、evidence、manifest 和生成 artifact 必须使用 JSON；只有未来真实外部兼容性证明必须为 YAML 时，才允许在临时输出上执行一次 JSON -> YAML 转换。
- 所有生成文件先写同目录临时文件，经 `mihomo -t` 和身份校验后原子 rename；不能用 AGENTS.md 文本代替运行时校验。
- compile 前必须确认设备 `yq` 可执行并支持最小只读转换；不满足时拒绝 compile，不改动当前 Profile、DNS、nft 或路由。

## 文档生命周期

- 每个语义主题只有一个当前 owner：设计理念和长期目标归 `docs/product/whitepaper.md`，当前产品合同按主题归 `docs/architecture/`，UI 视觉合同归 `docs/design/ui.md`，通用部署流程归 `docs/operations/`，操作入口归 `README.md`，贡献与治理规则归 `AGENTS.md`。白皮书和 proposal 不得冒充当前实现，其他位置只允许摘要和链接，不复制当前叙事。
- 已形成方向但尚未实现的稳定方案归 `docs/proposals/`；实现后把当前合同吸收到 architecture、保留仍有价值的理由到 `docs/decisions/`，再删除 proposal。ADR 只记录未来仍有价值的理由、替代方案和重审条件，不记录任务状态或设备快照。
- 活文档只描述当前事实和当前约束，不记录日期补丁、完成清单、路线图、设备快照、任务进度或按提交增量堆叠的历史。
- 过时内容直接删除。Git history 是历史和归档，不创建 `docs/archive`、`legacy` 文档或兼容说明保存已退役行为。
- 代码、接口、schema、命令或测试退役时，同一变更删除对应文档；不能把旧内容改成“已废弃”后继续留在活文档。
- 文档校验只检查可机械证明的事实，例如相对链接、文件存在、schema、可执行示例和秘密边界。不得用关键词、固定章节、文件数量或文本快照判断语义正确性。
- 修改后回读全部受影响文档，确认同一主题没有第二个当前答案，并运行相应 link、contract、build 或 package gate。

## 验证与交付

- 先运行覆盖改动的最小真实路径，再按当前真实技术栈和影响范围扩展门禁。没有对应生产实现时不保留空语言工具链或测试。
- 会修改 OpenWrt 文件系统、服务、UCI 或数据面的部署候选必须先通过仓库 QEMU OpenWrt qualification；VM 只替代通用平台和回滚试错，真实 provider/DNS/TPROXY/硬件仍由可本地恢复的 canary 验收。未取得同 commit/tree receipt 的候选最多允许 bundle、validate、compile/staged，不得 activate。
- source 测试只证明 source；设备安装、生效、网络恢复和业务可用性必须分别取得 target-local readback。
- Git 写任务使用独立 worktree；集成前 fresh fetch canonical `main`，按当前 SSOT 语义重放并保留其他 owner 的字节。共享 mutation 只在最终吸收阶段串行。
