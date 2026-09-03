# Canary 推广与复原

本文定义同一 canonical artifact 从可本地恢复的 canary 推广到远程 replica 的通用流程。
具体设备名称、地址、SSH route、网络拓扑和目标映射只属于 private OPL Instance 或
`AGENTS.local.md`，不得写入公开仓库。

## 0. 独立只读基线

任何 mutation 前分别记录每个目标的 Nikki 当前 Profile、订阅 cache、Mihomo 单实例、
DNS/nft/IPv4、基础业务访问和可回退路径。每个目标必须单独授权；一台设备的授权和基线
不能推断另一台设备已满足条件。

## 1. Canary

1. 安装或复制 disabled runtime，确认网络、Profile、DNS/nft、路由和服务无差异。
2. 只在 canary 执行 compile，取得 staged JSON、manifest、`mihomo -t` 和引用回读。
3. 先以最小真实 capability 执行 enable，回读 Nikki effective Profile、Mihomo 当前链、
   DNS/nft/IPv4 和业务访问。
4. 验证 manual select、disable、Nikki 手工切回、持久化和 active uninstall 的拒绝或安全退回。
5. 只有以上证据通过，才试验故障选择；protected probe 失败先进入已验证的 DIRECT guard，
   guard 无法回读才恢复 native Profile。
6. 通过后冻结 canonical artifact、配置合同和验收命令，形成唯一复制输入。

## 2. Replica

1. 重新取得 replica 的独立授权、备份和只读基线；canary 成功不能代替授权。
2. 原样安装同一 artifact，先验证 disabled 无网络差异，再按 canary 已证明的顺序执行。
3. 不因远程路径困难而减少 owner readback；失败立即 disable 或切回原始 Nikki Profile。
4. replica 只复制已经冻结并证明的能力，不在首次推广中引入新算法、UI 或目标专用补丁。

## 最短复原路径

- 只安装或 compile：无需恢复，Nikki 当前原始 Profile 继续工作。
- 已 enable 且 NetFleet 仍可执行：在 Nikki 选择 Recovery Profile，或执行 `disable`，再确认
  effective Profile、DNS/nft/路由和业务访问。
- NetFleet 已崩溃或被卸载：直接在 Nikki 手工切回 Recovery Profile；该路径不能依赖
  NetFleet CLI、RPC、supervisor 或历史状态。
- 恢复或卸载失败：停止删除动作，保留 staged/active artifact 和原始 Profile，使用 Nikki
  官方恢复路径；不得靠重复重试或手写 DNS/nft 清理掩盖问题。

automatic 能力必须先在 canary 取得同轮选择、能力资格、保护探针和 owner readback；
replica 只复制冻结后的能力，并仍需独立完成 installed/effective/runtime/business 验收。
