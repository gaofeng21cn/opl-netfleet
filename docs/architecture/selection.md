# 测量、资格与选择

本文是当前测量事实、候选资格、比较顺序、切换门槛和 automatic 选择语义的权威合同。
历史聚合只用于展示，不参与本文件定义的任何选择。

## 测量、资格与比较合同

速度、Mihomo 候选健康、配额和关键业务保护是不同事实。延迟与配额由独立适配器标准化，候选健康来自同轮 Mihomo owner readback；protected probes 既决定一次 enable/select 是否可提交，也为已生成的两层 Mihomo fallback 提供独立运行期健康目标，但其耗时和结果不进入 comparator。这些事实不能互相代换。

### 三类测量事实

| 事实 | 目标与方法 | 标准化结果 | 明确禁止 |
| --- | --- | --- | --- |
| 延迟 | enable、显式 `select auto` 或 supervisor 到期轮次先记录各 Provider/地区 URLTest 的历史尾部，再按 `checks.provider_healthcheck_timeout_ms` 并发触发每个 provider 一次 Mihomo 原生 health-check，并对 capability selector 做一次 group delay；selector 结果未覆盖的组，只接受本轮后历史时间戳确实变化、delay 大于 0 且组和叶子仍健康的结果。单个 provider 失败只使其候选失去本轮证据 | 每个返回项为 `status=ok,delay_ms=<正整数>`，缺失项为 `unavailable`；最终叶子必须在所选组的本轮成功结果中 | 用单节点 delay timeout 提前终止整机场批量检查、supervisor 自建第二扫描算法、旧 URLTest 历史补位、逐候选 shell 串行请求、直接 ping 共享入口、业务探针耗时或历史平均值；不带期望状态接收任意响应 |
| 候选健康 | 同轮读取 Mihomo Provider/地区组和真实叶子的 alive/readback | `available=true|false` 和稳定叶子身份 | 把业务 URL 耗时、入口 ping 或旧历史当作候选健康 |
| 运行期业务健康 | 两层 Mihomo lazy fallback 分别使用 `fail_open.healthcheck.path_probe_id` 与 `guard_probe_id` 引用的 protected probe，并复用同一 timeout、interval 和失败次数 | 内层在 preferred/指定兜底 provider/其他 provider 间恢复，外层在 proxy path/DIRECT 间兜底 | 把 protected probe 耗时写入排序、另建 NetFleet 轮询 daemon、用一个速度 URL 冒充关键业务健康 |
| 配额 | 只读 Nikki 官方 subscription metadata；不发额外业务请求 | `available`、`exhausted` 或 `unknown`，可带 `remaining_bytes`、`reset_at` | 把 ping 不通判为耗尽，把 unknown 判为耗尽，或假定买断一定无限量 |

整机场批量 health-check 的总等待预算属于 target-local `checks.provider_healthcheck_timeout_ms`；测速目标 URL、单个 delay timeout 和期望 HTTP status 属于 `checks.latency`。二者必须分开，因为 provider 原生 health-check 会并发等待该机场多个节点，不能被单节点 delay 的较短预算提前终止。测速 URL 只用于 Mihomo 原生 delay，不承担 capability 业务资格。一次显式轮次对每个 enabled provider 最多触发一次原生 health-check，再调用一次 capability group delay，并对最终所选组做一次叶子 readback；不重试、不额外逐组测速。Mihomo 在启动期可能先返回临时控制面 fallback，即使同一次 group delay 已完成，NetFleet 仍可在 `checks.latency.timeout_ms` 内只读刷新 `/proxies` 和 `/providers/proxies`，等待候选组暴露 manifest 绑定的真实 provider 叶子；该等待不触发第二次测量，超时后 `DIRECT` 等控制面值仍不能作为候选。Mihomo 的 capability selector 在嵌套 URLTest 下可能只返回当前分支，因此 adapter 可以从同一轮后各候选组更新过的历史尾部补齐结果，但时间戳未变化、delay 为 0、组失活或叶子不可回读时仍必须标为 `unavailable`。若当前没有可比较的 delay，自动选择保持当前健康路径，当前保护路径已坏则按 active guard DIRECT、Recovery Profile、Nikki 官方 passthrough 顺序恢复。

地区内叶子由 Mihomo URLTest 独占。compiler 不为每个 Provider/地区组创建独立 interval；速度测量来自 enable、显式或定期 `select auto`，以及连接失败触发的 URLTest health-check。active capability 的两层 lazy fallback 使用 protected probe 做运行期业务健康检查，只改变 Mihomo 数据路径，不产生排序 delay 或 NetFleet evidence。`selection.leaf_switch_margin_ms` 直接写入 Mihomo `tolerance`，默认 `150`：当前叶子被 health-check 标为失活后，下一次选路使用最快存活叶子；仍可用时只有新测量满足 `current_delay > fastest_delay + tolerance` 才切，因此 `150` 的真实语义是替代叶子严格快超过 `150 ms`。连接被拒绝会立即触发 health-check；其他拨号/握手失败按配置的 `max_failed_times` 和 timeout 窗口累计后触发。NetFleet comparator 不维护第二套叶子状态或隐藏阈值。

关键业务 URL 和预期 status 属于 target-local `fail_open.probes`；`fail_open.healthcheck` 以 `path_probe_id`、`guard_probe_id` 引用其中两项，并统一声明 `timeout_ms`、`interval_seconds` 和 `max_failed_times`。实际业务域名只存在于设备私有 policy 或 Nikki mixin，公开 bundle 和 engine 不包含实例域名常量。事务探针必须通过当前 Mihomo 显式代理端口并使用 Nikki 认证配置，不能用路由器本机直连替代；生成 Profile 的 Provider fallback 和内层 path fallback 使用 path probe，外层 guard 使用 guard probe，最终都允许进入 DIRECT。两项 probe 可以引用同一 ID，但都必须显式存在；它们不参与候选速度排序。

当前 source 不提供逐候选 capability 业务探测，也不接受未消费的 `checks.availability` 配置。AI automatic 的地区资格来自显式 allowed/excluded 地区，最终业务资格由 Policy Source 的 AI 分类规则和事务 protected probe 验证；protected probe 失败时整笔多 capability 事务按同一 Fail-Open 路径恢复。若未来必须在写 selector 前逐候选验证 AI 业务资格，必须先证明平台可以在不增加常驻代理和第二证据库的情况下完成。

配额只读 Nikki 已有 metadata。只有 metadata 明确报告剩余量为零或官方 exhausted 标记时才排除候选；`unknown` 仍可通过可用性和 delay 参与候选，但不能凭 unknown 获得优先级。测量结果只作为一次命令的临时对象输出，不保存 LKG、排名、generation 或“最佳”结论，比较器不得读取历史记录。

### 标准化对象与 owner

适配器之间只传递类似下列的脱敏对象，比较器不读取 UCI、订阅原文、`ping` 文本、`curl` 输出或 Mihomo 私有响应字段：

```json
{
  "candidate_id": "stable-node-id",
  "provider_id": "provider-id",
  "region_id": "region-id",
  "capability": "standard",
  "latency": {
    "method": "mihomo_delay",
    "status": "ok",
    "delay_ms": 42,
    "target": "https://www.gstatic.com/generate_204"
  },
  "available": true,
  "quota": {
    "state": "available",
    "remaining_bytes": 123456
  }
}
```

`latency adapter` 只负责采样和聚合；`quota adapter` 只负责 metadata 映射；`qualification` 只判断 capability、地区授权、Mihomo 健康和 quota 排除；`comparator` 只按显式 policy 排序；`compiler` 只把 protected probe 引用投影到 Mihomo fallback；`activation owner` 只负责把选出的稳定组安全写回并回读叶子与事务探针。任何适配器失败都必须返回有区别的 `unavailable`/`unknown`，不能把缺失值转换成零或成功。

### 一轮比较的确定顺序

NetFleet 自动选择在 enable 初次决定、用户明确触发或 supervisor 到期时执行同一个有界轮次；运行期故障由生成 Profile 内两层职责不同但同属 Mihomo 的 lazy fallback 处理：path probe 在 preferred、primary provider tier 和 reserve provider tier 间恢复，guard probe 在 proxy path/DIRECT 间兜底。supervisor 不读取 fallback 结果作为下一次排序证据。每轮复用同一批标准化对象，不为地区、provider、节点重试：

1. **资格过滤**：先排除 capability 不匹配、未获授权地区、组内 latency URLTest 未通过、没有真实叶子身份的候选和明确 `exhausted` 的候选；Mihomo 的 `COMPATIBLE`、`DIRECT`、`REJECT`、`GLOBAL`、`PASS`、`BLOCK` 等控制面占位值不是叶子，delay `unavailable` 不能伪装成通过。保护业务 check 在变更前后验证当前路径，并在 active artifact 内继续作为 fallback 健康目标，但不把业务 URL 的耗时或状态混入速度排序。
2. **地区代表**：每个授权地区取本轮 `available=true` 且 `latency=ok` 候选中最小 `delay_ms` 的叶子；同 delay 用稳定 region ID 和 candidate ID 作确定性 tie-break。
3. **地区切换**：当前地区代表仍合格时，只有替代地区代表满足 `current_delay_ms - alternative_delay_ms >= selection.region_switch_margin_ms`（默认 150）才切换；当前地区没有合格代表时直接选最快合格地区。业务 status 只决定是否合格，不参与差值。
4. **机场与节点**：地区确定后，在当前故障层的合格 `(provider,node)` 中按 `delay_ms` 升序；只有 delay 完全相同才读取显式 quota tie-break（已知剩余量大的优先），再按稳定 provider ID、node ID 排序。`subscription|buyout` 不得覆盖真实 delay；`primary|reserve` 只决定当前候选层，primary 阶段无合格结果时才进入 reserve，不能把 reserve 当成隐含速度权重。
5. **能力组合**：每个 capability 先按自己的授权范围和门槛过滤候选。automatic capability 形成一个无环依赖图：唯一根能力先选择；跟随能力只在根能力地区对自身仍合格时复用该地区，否则选择自身同轮最快合格地区。依赖来自 `prefer_region_from`，engine 不按 `standard`、AI、地区或机场名称分支。
6. **回退**：automatic 选择中 primary 候选全部失败后才进入 reserve。运行时 path probe 失败先由 Mihomo 在 manifest 列出的 primary tier 机场中选择，主用层全部失败后进入 manifest 列出的 reserve tier，最后由外层 guard 进入 `DIRECT`。显式 enable/select 事务失败则先把 active capability guard 切到 `DIRECT`，以 selector/runtime readback 建立即时安全护栏，再恢复 Recovery Profile owner/runtime，原生恢复失败才进入 Nikki 官方 passthrough。保护域名结果始终独立报告。任何选择写入失败或业务回读失败都先恢复此前健康 selector，否则走同一事务恢复顺序。

若 delay 全部不可用但业务仍可达，NetFleet 不宣称“最快”并保持当前路径。测速失败不是 quota exhausted，也不能触发隐藏的第二测量方法。

`automation.startup_grace_seconds` 只用于 enable 后等待 Nikki、Mihomo 和 provider 收敛；`automation.runtime_grace_seconds` 只用于已经接管后的连续失联判定。`DIRECT` 是终端无代理数据面逃生路径：全部代理路径失败后，后续连接不再经过代理，但这不等于“所有海外流量都断开”；实际可达性由直连出口决定。

全局 mutation lock 只由短生命周期调用者持有。调用者在锁内启动 UCode owner 时关闭子进程的锁 fd，保证事务仍串行，同时禁止 Nikki/Mihomo 后台进程继承锁并永久阻塞后续恢复或部署。

### 配置如何保持可替换

policy 的 owner 分区固定；全局许可、能力开关和策略模式不能互相替代。自动选择只由 capability 自身的 `mode` 启用，顶层 `selection` 只提供可覆盖的默认门槛：

```json
{
  "main": {
    "enabled": true
  },
  "capabilities": {
    "standard": {
      "enabled": true,
      "mode": "automatic",
      "region_switch_margin_ms": 150,
      "leaf_switch_margin_ms": 150
    },
    "ai-compatible": {
      "enabled": false,
      "mode": "manual",
      "excluded_regions": ["hong-kong"]
    }
  },
  "selection": {
    "region_switch_margin_ms": 150,
    "leaf_switch_margin_ms": 150
  },
  "automation": {
    "enabled": true,
    "selection_interval_seconds": 1800,
    "poll_interval_seconds": 15,
    "startup_grace_seconds": 120,
    "runtime_grace_seconds": 45
  },
  "checks": {
    "provider_healthcheck_timeout_ms": 20000,
    "latency": {
      "method": "mihomo_delay",
      "url": "https://www.gstatic.com/generate_204",
      "timeout_ms": 2000,
      "expected_status": 204
    },
    "quota": {
      "source": "nikki_subscription_metadata",
      "zero_is_exhausted": true
    }
  }
}
```

`providers` 只描述稳定 provider ID、稳定命名的 Nikki subscription section、计费类型、quota metadata 映射和故障层级；cache 文件名只能由 section 派生，匿名 `@subscription[n]` 和第二个 `cache` 身份都必须拒绝。`regions`/`provider_regions` 只描述可复用的网络资源、授权关系、国旗/显示名和节点 filter；`capabilities` 描述开关、显示名、允许/排除地区及可选选择参数；顶层 `selection` 只提供默认地区和叶子切换门槛；`automation` 只提供调度开关、选择周期、轻量 readback 周期和 runtime grace；`checks` 分别声明整机场 health-check 总预算与单节点 delay 合同；`fail_open.healthcheck` 显式引用 `fail_open.probes` 作为 path/guard 运行期健康合同。换机场、开关能力、测速 URL、超时、保护 URL、健康探针映射、周期或门槛都只改 target-local policy，不改 comparator、compiler 或 adapter。门槛缺省只由 policy owner 解析：capability 覆盖、否则 `selection`、否则 150；compiler、selector 和 status 不得各自再写一份缺省。

### 测试与比较矩阵

所有测试都验证一个明确 owner；测试 fixture 传入标准化 JSON，避免用网络命令输出快照把 adapter、算法和配置绑在一起。

| 阶段 | 测试方式 | 必须证明的结果 | 失败处理 |
| --- | --- | --- | --- |
| 原生基线 | 设备只读回读 Nikki effective Profile、DNS/nft、路由、IPv4 和保护域名 status | 未启用 NetFleet 时基线不变且可用 | 不做 mutation，停止后续动作 |
| schema/引用 | UCode 核验 JSON 分区、精确组名、provider/region/capability 引用、循环和重复稳定身份 | 不猜组名、不接受未知引用 | compile 拒绝，Profile 不变 |
| provider source | 检查 Nikki cache 可读、SAFE_PATH symlink、自动模式机场组只包含 `provider_regions` 已授权节点，并运行 `mihomo -t` | 只有一份订阅事实；未知地区和订阅元数据不能进入 automatic/fallback | 只保留 staged 失败，不切 active |
| latency adapter | 注入 Mihomo group delay 成功、部分缺失、timeout、controller 错误和全失败输入；设备再做一轮真实 capability delay | `delay_ms`、`unavailable` 和一轮一次请求约束正确 | 不逐候选串行请求，不直接 ping 共享入口，不产生资格结论 |
| protected probes/fallback | 对事务后的关键业务及生成的 path/guard fallback 注入期望 status、非期望 status、TLS/解析错误和 timeout | 事务探针决定 enable/select 能否提交；运行期 probe 只改变 Mihomo fallback 数据路径，不产生候选资格或 delay | 事务按统一 Fail-Open 路径恢复；运行期按 provider -> native -> DIRECT 退路 |
| quota adapter | 注入 available、明确 zero/exhausted、metadata 缺失和格式错误 | exhausted 排除，unknown 与 ping 失败分离 | unknown 保留但不加权；格式错误单独报告 |
| 资格/排序 | 使用标准化 fixture 覆盖同区、跨区、150 ms 边界、同 delay quota tie-break 和稳定 ID | comparator 无 I/O、结果可重复，不读历史 | 返回无候选，不写设备 |
| activation/readback | canary 先执行 staged -> enable -> selector readback -> protected status -> disable；再在 replica 原样复现 | effective Profile、当前链和原生退回一致 | 立即恢复旧 selector/Recovery Profile |
| 故障注入 | 逐项断节点、断 provider、断地区 primary、quota exhausted、全代理失败、Mihomo/NF 进程退出 | preferred -> 指定兜底 provider -> 其余 primary/reserve -> DIRECT，以及必要时 Recovery Profile/Nikki 官方 passthrough 的恢复顺序成立 | 不遗留 DNS/nft/半启用状态 |
| 性能基准 | 独立记录一轮 delay、编译/激活耗时、status/UI p95；不写入 selection 输入 | 找到设备预算，不改变算法语义 | 回到更小批次或减少功能，不加缓存/后台循环 |

源测试只验证纯函数、schema 和 adapter 错误映射；QEMU qualification 在 Apple Silicon macOS 上由原生 `qemu-system-aarch64` 通过 Hypervisor.framework/HVF 启动与目标同指令集的官方 OpenWrt `armsr/armv8` 系统镜像和 ARM64 runtime 资产，验证通用平台、管理恢复与回滚边界，并把 runner/guest 架构、QEMU 版本、accelerator 和阶段耗时写入 exact commit/tree receipt。它不提供 Docker/TCG 回退，仍只是 synthetic platform proof；真实设备测试才验证 proxy-path delay、业务 status、Nikki/Mihomo effective state 和 Fail-Open。性能基准不是功能通过证据，设备通过也不能反向证明历史排序或隐藏评分正确。

## 选择与故障语义

### 同一轮次的自动跨地区选优

自动选优使用 Mihomo 原生 URLTest 组提供叶子可用性。enable、用户“重新选优”和 supervisor 到期调度都调用同一个一次性选择函数；display evidence 不属于选择状态。该动作的速度输入是同目标的 Mihomo proxy-path delay；protected probes 守事务提交，并作为生成 Profile 的运行期 fallback 健康目标，但不参与 comparator：

1. 先过滤候选资格：节点必须可用且当前叶子必须同时属于候选组的成员列表，并存在于 manifest 为该组绑定的 `/providers/proxies` source 中，具有真实代理类型且 `alive=true`；只在全局 `/proxies` 出现、来自另一机场的同名叶子或 Mihomo 控制面占位值一律不可用。Provider 不能明确 `quota_exhausted`，且候选属于当前 capability；quota 探测失败与节点探测失败保持不同原因；
2. NetFleet 在一次有界轮次中先对每个 provider 触发一次 Mihomo 原生 health-check，各 Provider/地区 URLTest 按 `leaf_switch_margin_ms` 得到本轮叶子；随后对 preferred selector 发一次同目标 group delay，并对最终所选组做叶子成功结果核对；不重试、不平均历史值；
3. 每个地区取本轮 Mihomo 健康且 delay 可用的各 Provider 当前叶子代表，选择最小 `delay_ms`。当前地区代表仍成功时，只有最快替代地区 `current_delay - alternative_delay >= selection.region_switch_margin_ms`（默认 150）才切区；当前地区无合格代表时直接选择最快合格地区；
4. 地区确定后，在当前故障层各 Provider/地区组代表中按 `delay_ms` 从小到大选择；速度相同才按订阅剩余流量从多到少、再按稳定 Provider ID 和当前叶子 ID 排序；买断 Provider 不因类型获得隐藏加分；NetFleet 只切 capability selector，不直接写 URLTest 叶子；reserve 只有 primary 阶段无合格结果时才进入。
5. 每个 capability 独立持有模式、地区范围和门槛；automatic 能力按 `prefer_region_from` 的无环依赖顺序运行。AI 排除香港，海外加速地区仍合格时直接跟随，否则选择 AI 自身同轮最快合格地区；不引入 capability 名称特判；
6. 只有 policy 明确启用故障层级时，才在 primary 候选全部失败后纳入 reserve；正常候选池应把需要参与速度竞赛的 Provider 放在同一层。运行中 preferred 链失败时，Mihomo 先在精确列出的 primary provider tier 内选择健康路径，全部失败后才进入 reserve provider tier，最终进入 DIRECT；显式选择没有合格候选且保护路径已坏时按“active guard DIRECT -> Recovery Profile -> Nikki 官方 passthrough”恢复；
7. 直接 ping provider 入口不能代表跨地区出口质量；不得把持久化 delay、平均值、业务耗时、LKG、freshness、generation、排名结果或选择历史用于下一轮选择。允许保存上文定义的固定空间 display evidence，但它不能改变 comparator、候选资格或 selector。

Provider quota 只允许三态：`available`、`exhausted`、`unknown`。只有 Nikki metadata 明确显示剩余量为零时才标记 `exhausted`；`unknown` 不能被当作耗尽，也不能作为“剩余量更多”的优选证据。NetFleet 不建立独立 quota 轮询：下一次 enable、显式或定期 `select auto` 顺带读取 Nikki metadata 并排除明确耗尽的 Provider；运行中若机场因耗尽而实际断流，Mihomo 按 `path_probe_id` 的业务健康合同进入 provider fallback，最终到 DIRECT 终点。quota 元数据本身不能证明链路已断，也不能阻止 DIRECT。Mihomo URLTest 继续负责数据面组内健康；NetFleet 自动比较使用 controller delay。AI automatic 只复用已有地区资格、同轮 delay、原子 selector 提交和公共 protected probes，不引入第二业务探测、证据库或第二选择器。

### 最小运行合同

1. target-local policy 只增加 Provider 计费类型、quota metadata、地区成员关系、两个 `150 ms` 门槛，以及 fallback 的 path/guard probe ID、timeout、interval 和失败次数；需要参与速度竞赛的 Provider 配置在同一故障层，不改 Policy Source 规则；
2. compiler 生成每个 Provider/地区的受控候选组；Provider 级 fallback 只聚合相同授权 filter 覆盖的节点，继续直接引用 Nikki cache，不靠伪节点名称正则决定 automatic 资格；
3. 所有触发源复用同一个候选轮次和上述固定排序：Mihomo proxy-path delay 负责速度，Mihomo owner readback 负责候选健康；唯一 supervisor 只负责周期，不引入第二算法或历史状态；
4. 以 `standard` 为根 automatic capability，`ai-compatible` 通过配置排除香港并跟随根能力的合规地区；两者由同一个 owner 顺序决定并原子提交。standard 与 AI 都只按 provider role 进入 primary、reserve 和 DIRECT；AI 的每一层继续应用非香港授权 filter；
5. target 必须回读当前地区保持、delay 优势小于 `region_switch_margin_ms` 不切换、达到该门槛才切换、AI 避港、quota 耗尽排除、delay 不可用与 quota 耗尽分离、业务不可用和 Recovery Profile 退回；
6. canary 证据闭合后才冻结 policy/artifact，replica 只复制同一输入和动作合同。
