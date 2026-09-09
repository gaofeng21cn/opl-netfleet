# 状态呈现

机场和地区表同时呈现“本轮测速”与“历史最近”。本轮值只读取根能力最近一轮的 `measurement`，标注采样时间，缺失或失败不使用历史数值补位；失败原因按组计数显示。历史最近和平均值保留原有聚合语义，不能作为本轮入选证明。

本文定义 owner 状态如何解释为用户可见信息；不定义 RPC、候选排序或视觉布局。
数据读取与授权归[公开接口](interfaces.md)，视觉组件归[UI 设计](../design/ui.md)。

## 对象身份与当前出口

状态中的机场正式名称由 UCI 引用的当前后端 subscription section 的 `name` 提供；section 没有名称时才回退到稳定 section ID。恢复配置的用户显示名由 status owner 通过同一 target-local 后端 metadata 解析并投影为 `recovery_profile_display_name`；无法取得可靠名称时返回 `null`，UI 显示“当前原生配置”，不得从 `subscription:`/`file:` 引用或 provider 计费属性猜名称。capability 的可见 Mihomo 组名来自 policy `display_name`；地区可见名称由可选 `flag` 与 `display_name` 组合，缺失时回退到稳定 region ID，共享 UI 再把任意一对 regional-indicator 字符通用转换为 ASCII 两位地区代码，统一显示为“地区代码 + 中文名称”，不能依赖 emoji 字体或为单个地区写特例。这些显示名只用于编译的用户表面和 status/UI projection，不参与 provider、地区或节点选择，也不能成为算法分支。内部对象仍用稳定 ID，provider/region 内部组一律 hidden。NetFleet inactive 时，status 另从当前后端 owner 和一次 controller `/proxies` 读取每个绑定策略来源组的原生实际链；LuCI 显示“当前原生出口”，capability 只标注为“下次启用配置”。原生组缺失、controller 不可用和网络直通必须分别显示，不能统一降级成“未知”。

## 当前地区与库存计数

地区目录与当前地区规划是两层对象。policy 的 `regions` 与 `provider_regions` 只定义稳定地区 ID、显示名、Provider filter 映射和 capability 许可；status 完整投影目录供 owner 关联运行状态和历史，目录项本身不代表当前必须可用。当前地区规划只包含同一次设备状态中 `available_count > 0` 且 `available_provider_count > 0` 的地区：它既是地区页的可操作列表，也是首页地区数量、最近最优和平均最优的统计边界。`available_count` 表示真实候选路径数量；`available_node_count` 只是后端库存诊断，可能未知，不能作为地区可用性的门槛。机场和地区的实时可用数只有在 NetFleet 已接管、生成配置存在且 Mihomo 控制面可读时才具有故障语义；NetFleet 未接管或控制面不可读时，UI 必须显示“未测量”，不得把 status 中用于占位的零值解释为机场或地区下线。没有真实可用路径的目录项不进入当前规划、不作为首页分母，也不触发“不可用地区”警告；只有当前正在使用的地区失去真实路径时才作为运行异常提示。不能用“至少两个节点”或“至少两个机场”等数量门槛排除合法的小众地区，一条真实可用的 Provider/节点路径即可进入当前规划。

机场表的“可用地区”是去重后的 provider-region 数量，地区表的“可用机场”是去重后的 region-provider 数量；机场的“节点”是 manifest 绑定 source 在 `/providers/proxies` 中的 Mihomo 已加载库存，按节点名去重并使用 `alive` 统计可用数，不因地区识别或 capability 许可排除小众节点；当 SubscriptionOwner 读取的原始订阅条目数与已加载数不同，机场同一单元格补充“订阅 N 条”，不能把未被 Mihomo 接受的条目计作可用节点。地区的“节点”以 `/proxies` 当前 group 的成员关系为边界，并用同一 source 补充 file-provider 叶子身份和健康状态。按 Mihomo 类型确认的直连、拒绝等控制面终端是已知的非节点，排除后不影响其他候选组计数；不得按节点显示名猜测类型。缺失成员列表或不能解析的嵌套组仍是未知，显示“节点清单暂不可读”，不能伪造零值。没有真实可用叶子的地区不能凭历史 evidence 占位。

## 测量与订阅展示

机场表和地区表都显示 evidence 中的“最近最优”“平均最优”、有效样本数与最近有效测量时间。没有有效样本时合并延迟空态为“暂无有效测量”，仅有一次时显示“仅 1 次测量”，达到两次后才显示真实平均，即使与最近值相同也不改写。机场值是一轮内该机场全部合格地区候选的最小有效 delay，地区值是一轮内该地区全部合格机场候选的最小有效 delay。历史保留范围来自 manifest 的当前候选目录，不来自某轮成功解析的运行候选；临时失效或本轮未取得叶子不清空历史、不增加样本，也不把旧测量时间刷新为本轮时间。删除目录对象时裁剪，改变延迟测量口径时重置。UI 明确区分库存健康和有效测量历史，旧延迟不冒充本轮成功。

机场详情把 SubscriptionOwner 的 `last_success` 标为“订阅更新时间”，把 `last_attempt` 标为“最近尝试”；没有 NetFleet 刷新事件时，“最近尝试”显示“尚未执行”，“订阅更新时间”显示当前后端订阅缓存的实际修改时间，缓存也不存在才显示“尚未执行”，不得拿最后测量或 cache digest 猜更新时间。订阅制机场从同一次 target-local 后端 metadata 读取 `expire` 并投影为 quota `expires_at`；缺失显示“机场未返回到期时间”，买断制显示“不限时间”，不得从节点名称或订阅 URL 猜测。地区默认按本轮有效 delay 升序、可用节点数降序、可用机场数降序及显示名排列；没有本轮有效值的项放在末尾，历史延迟不参与本轮排名。“当前使用”只作标记，不改变位置；历史最近与平均最优仍可显式选择排序。机场表继续按当前选中项、可用地区数、最近最优 delay 和显示名排序。两者都只是展示顺序，不改变运行时 comparator 或 selector。

## 运行模式与退路

配置模式来自 policy：`automatic` 能力允许“自动选优 / 地区 / DIRECT”，`manual` 能力只允许地区和 DIRECT，地区级 `manual_only` 不进入自动池。运行模式来自 Mihomo 可见 selector 的当前成员：选择“自动选优”时 supervisor 定期重排；选择地区或 DIRECT 时显示“手动保持”并暂停后台选择。LuCI 配置页按 [UI 设计合同](../design/ui.md#页面骨架)组织结构化草稿与独立管理分区；首次设置按“环境与恢复 / 机场 / 地区 / 出口 / 运行与安全”推进，不把 raw policy 字段逐项暴露。顶部“NetFleet 已启用”只表示生成 Profile 是当前 owner；能力卡标题不重复显示状态，摘要中的“策略”是唯一模式投影，说明块使用“选优规则”。compiler 根据 Policy Source 中每个 `policy` 业务组的首选成员，把默认行为投影为 `capability` 或 `direct`；status 优先读取该 manifest 投影，兼容旧 manifest 时只允许从 Mihomo 当前组的有序成员回读，不按组名猜测。出口页分别显示“默认走此出口”和“默认直连、可临时切换”，不再把 entry 与 policy binding 混成“接管的原始策略组”。用户可见的“运行时网络退路”只按 status 从 manifest 返回的 role stages 投影为“当前优选 → 主用机场 → 备用机场 → 直连”，没有 reserve stage 时明确显示“备用机场（未配置）”。机场的 `primary|reserve` role 与 `subscription|buyout` 计费是独立事实，UI 不得用买断属性推断备用角色。

“退出与故障恢复”是独立区块：优先恢复 `recovery_profile_display_name` 对应的原生配置；只有该恢复失败时，最终退路才是停止当前代理后端并恢复网络直通。这是条件关系，不能与运行时网络退路合并，也不能用一条连续箭头暗示每次都会执行两步。用户可见文案使用“直连 / 网络直通 / 原生配置”，不暴露 `DIRECT`、`passthrough`、`RecoveryProfileRef` 等内部标识。界面中的门槛、周期和说明必须直接读取 status 返回的 policy 值，不能在前端写死 capability、地区、机场或阈值。机场表和地区表的延迟着色使用 `status.selection.region_switch_margin_ms` 作为展示分界，缺失或非数字时不加警告色；该分界只服务展示，不冒充 comparator。UI 不得按 capability id 是否包含 `ai` 或其他子串选择图标或文案，跟随能力的说明必须读取该能力的 `prefer_region_from` 显示名。

## 地区选择反馈

出口卡片同时显示实际路径和选择方式。手动保持时显示 `manual_region_id` 对应地区，
不能把故障直连或当前测速最快地区当成用户意图。概览与地区表的当前使用标记来自
同一运行路径，自动与手动地区均应标记。概览的“最近测量最快”和“历史平均最低”只表达
有效测量统计，不证明切换或业务资格；自动模式注明切换门槛，手动模式注明后台选优暂停。
