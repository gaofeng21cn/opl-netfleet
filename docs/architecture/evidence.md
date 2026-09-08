# 显示证据

本文定义 owner 事件与显示证据的记录、身份、聚合和失效；当前测量和排序归
[选择合同](selection.md)，显示方式归[状态呈现](ui-state.md)。

## 事件记录

`/var/lib/opl-netfleet/events.json` 保存固定上限的 owner 事件；OpenWrt 的 `/var` 位于临时文件系统，不能承诺重启后保留。它，不是 operation history 或选择输入。它记录 one-shot owner 已实际完成的 enable、select、disable 和 subscription refresh；refresh 事件只保存执行时间、聚合结果、机场总数/变化数/失败数、是否重载、调用来源，以及每个稳定 section 的 `result`/`digest`，不保存 URL、token、节点、cache 内容或完整配置。写入失败不改变数据面结果。调用来源只允许 owner 已知的 `luci|cli|deployer|supervisor`，未知入口如实记录 `unknown`，不能据进程或时间猜测。Mihomo 自主 health-check/fallback 继续写所选后端管理的 core log，NetFleet 日志页只读展示其中与 `NETFLEET-` 相关的最近行，并明确受所选后端日志清理策略约束；NetFleet 不为捕捉每次叶子变化增加常驻监听器。

## 存储与采样

`/etc/opl-netfleet/evidence.json` 是唯一 display evidence owner，并位于 OpenWrt 持久 overlay；不得放在指向 `/tmp` 的 `/var` 下。每次成功的 enable、显式或定期 `select auto` 按 capability 覆盖保存本轮有界候选结果，并分别维护固定空间的机场和地区 delay 聚合；每个机场或地区在一轮内只记其最小有效 delay，全局机场表和地区表都只投影根 automatic capability。

候选结果覆盖 manifest 中的全部候选组。未通过的组保留无真实节点、测速 URL 健康失败、缺少本轮延迟或配额耗尽等原因，不因提前过滤而从证据消失。机场和地区的 `measurement` 投影根能力最近一轮的采样时间、有效测速最小延迟、有效测速候选数及排除原因计数；历史聚合不能补入本轮值。无证据时为 `null`，本轮没有有效测量时 `best_delay_ms` 为 `null`。测速成功数不等于通过地区授权、故障层级和业务保护的最终入选数。

## 可比性与失效

聚合身份只绑定实际延迟测量口径（测量模型、URL、期望状态与 timeout），不绑定完整 artifact、Policy Source 或 policy：代码、显示文案、Fail-Open、自动周期、设备重启或其他不改变延迟可比性的更新不得清空历史。机场、地区或 capability 拓扑变化时，当前轮按稳定 ID 保留仍存在对象的聚合、移除已不存在对象并从单样本建立新增对象；测量口径变化才整体重置。

## 已存证据的读取

旧 identity 在精确匹配当前 artifact/policy 时允许一次无损升级到新口径；部署 owner 首次升级时把仍存在的旧 `/var/lib/opl-netfleet/evidence.json` 原子迁入持久 owner，成功后删除旧路径，失败回滚恢复原字节。

## 失败边界

该聚合只用于 status/LuCI 展示，selector 永远只读当前轮，不得读取平均值或历史值。evidence 缺失、损坏或写入失败必须被忽略，不能阻断 enable、select、disable 或原生恢复。
