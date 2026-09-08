# 测量、资格与选择

本文是当前测量事实、候选资格、比较顺序、切换门槛和 automatic 选择语义的权威合同。
历史聚合只用于展示，不参与本文件定义的任何选择。

## 测量、资格与比较合同

速度、Mihomo 候选健康、配额和关键业务保护是不同事实。延迟与配额由独立适配器标准化，候选健康来自同轮 Mihomo owner readback；protected probes 既决定一次 enable/select 是否可提交，也为已生成的两层 Mihomo fallback 提供独立运行期健康目标，但其耗时和结果不进入 comparator。这些事实不能互相代换。

### 测量事实

| 事实 | 目标与方法 | 标准化结果 | 明确禁止 |
| --- | --- | --- | --- |
| 延迟 | enable、显式 `select auto` 或 supervisor 到期轮次先记录各 Provider/地区 URLTest 的历史尾部，再按 `checks.provider_healthcheck_timeout_ms` 并发触发每个 provider 一次 Mihomo 原生 health-check，并对 capability selector 做一次 group delay；selector 结果未覆盖的组，只接受本轮后历史时间戳确实变化、delay 大于 0 且组和叶子仍健康的结果。单个 provider 失败只使其候选失去本轮证据 | 每个返回项为 `status=ok,delay_ms=<正整数>`，缺失项为 `unavailable`；最终叶子必须在所选组的本轮成功结果中 | 用单节点 delay timeout 提前终止整机场批量检查、supervisor 自建第二扫描算法、旧 URLTest 历史补位、逐候选 shell 串行请求、直接 ping 共享入口、业务探针耗时或历史平均值；不带期望状态接收任意响应 |
| 候选健康 | 同轮读取 Mihomo Provider/地区组和真实叶子的 alive/readback | `available=true|false` 和稳定叶子身份 | 把业务 URL 耗时、入口 ping 或旧历史当作候选健康 |
| 运行期业务健康 | 两层 Mihomo lazy fallback 分别使用 `fail_open.healthcheck.path_probe_id` 与 `guard_probe_id` 引用的 protected probe，并复用同一 timeout、interval 和失败次数 | 内层在 preferred/primary tier/reserve tier 间恢复，外层在 proxy path/DIRECT 间兜底 | 把 protected probe 耗时写入排序、另建 NetFleet 轮询 daemon、用一个速度 URL 冒充关键业务健康 |
| 配额 | 读取当前后端 subscription metadata；不发额外业务请求 | `available`、`exhausted` 或 `unknown`，可带 `remaining_bytes`；手工月重置日仅供 UI 参考，见[订阅对象](domain-model.md#后端与订阅归属) | 把 ping 不通判为耗尽，把 unknown 判为耗尽，按参考日期清零用量，或假定买断一定无限量 |

整机场批量 health-check 的总等待预算属于 target-local `checks.provider_healthcheck_timeout_ms`；测速目标 URL、单个 delay timeout 和期望 HTTP status 属于 `checks.latency`。二者必须分开，因为 provider 原生 health-check 会并发等待该机场多个节点，不能被单节点 delay 的较短预算提前终止。测速 URL 只用于 Mihomo 原生 delay，不承担 capability 业务资格。一次显式轮次对每个 enabled provider 最多触发一次原生 health-check，再调用一次 capability group delay，并对最终所选组做一次叶子 readback；不重试、不额外逐组测速。Mihomo 在启动期可能先返回临时控制面 fallback，即使同一次 group delay 已完成，NetFleet 仍可在 `checks.latency.timeout_ms` 内只读刷新 `/proxies` 和 `/providers/proxies`，等待候选组暴露 manifest 绑定的真实 provider 叶子；该等待不触发第二次测量，超时后 `DIRECT` 等控制面值仍不能作为候选。Mihomo 的 capability selector 在嵌套 URLTest 下可能只返回当前分支，因此 adapter 可以从同一轮后各候选组更新过的历史尾部补齐结果，但时间戳未变化、delay 为 0、组失活或叶子不可回读时仍必须标为 `unavailable`。若当前没有可比较的 delay，自动选择保持当前健康路径，当前保护路径已坏则按 active guard DIRECT、Recovery Profile、所选后端 passthrough 顺序恢复。

地区内叶子由 Mihomo URLTest 独占。compiler 不为每个 Provider/地区组创建独立 interval；速度测量来自 enable、显式或定期 `select auto`，以及连接失败触发的 URLTest health-check。active capability 的两层 lazy fallback 使用 protected probe 做运行期业务健康检查，只改变 Mihomo 数据路径，不产生排序 delay 或 NetFleet evidence。`selection.leaf_switch_margin_ms` 直接写入 Mihomo `tolerance`，默认 `150`：当前叶子被 health-check 标为失活后，下一次选路使用最快存活叶子；仍可用时只有新测量满足 `current_delay > fastest_delay + tolerance` 才切，因此 `150` 的真实语义是替代叶子严格快超过 `150 ms`。连接被拒绝会立即触发 health-check；其他拨号/握手失败按配置的 `max_failed_times` 和 timeout 窗口累计后触发。NetFleet comparator 不维护第二套叶子状态或隐藏阈值。

关键业务 URL 和预期 status 属于 target-local `fail_open.probes`；`fail_open.healthcheck` 以 `path_probe_id`、`guard_probe_id` 引用其中两项，并统一声明 `timeout_ms`、`interval_seconds` 和 `max_failed_times`。实际业务域名只存在于设备私有 policy 或 Nikki mixin，公开 bundle 和 engine 不包含实例域名常量。事务探针必须通过当前 Mihomo 显式代理端口并使用所选后端认证配置，不能用路由器本机直连替代；生成 Profile 的 Provider fallback 和内层 path fallback 使用 path probe，外层 guard 使用 guard probe，最终都允许进入 DIRECT。两项 probe 可以引用同一 ID，但都必须显式存在；它们不参与候选速度排序。

选路提交前，activation 按依赖顺序对已选 preferred selector 使用 path probe、对内层 proxy path 使用 guard probe，刷新 Mihomo 按 URL 独立保存的健康状态，再回读完整优选路径。测速 URL 的成功不能替代这两个业务 URL 的健康事实。验证只经过所选链，不遍历备用分支，不固定 fallback，也不把业务探针延迟写入排序；Mihomo 单个 delay 响应可能带有数值却未满足预期 HTTP status，因此必须同时回读该 URL 的独立健康记录。任一层验证失败保留具体错误并走原事务恢复。

当前 source 不提供逐候选 capability 业务探测。AI automatic 的地区资格来自显式 allowed/excluded 地区，最终业务资格由 Policy Source 的 AI 分类规则和事务 protected probe 验证；protected probe 失败时整笔多 capability 事务按同一 Fail-Open 路径恢复。若未来必须在写 selector 前逐候选验证 AI 业务资格，必须先证明平台可以在不增加常驻代理和第二证据库的情况下完成。

配额只读所选后端已有 metadata。只有 metadata 明确报告剩余量为零或官方 exhausted 标记时才排除候选；`unknown` 仍可通过可用性和 delay 参与候选，但不能凭 unknown 获得优先级。测量结果只作为一次命令的临时对象输出，不保存 LKG、排名、generation 或“最佳”结论，比较器不得读取历史记录。

### 标准化对象与 owner

适配器之间只传递类似下列的脱敏对象，比较器不读取 UCI、订阅原文、`ping` 文本、`curl` 输出或 Mihomo 私有响应字段：

```json
{
  "candidate_id": "stable-node-id",
  "provider_id": "provider-id",
  "region_id": "region-id",
  "capability": "standard",
  "role": "primary",
  "leaf_verified": true,
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

1. **资格过滤**：先排除 capability 不匹配、未获授权地区、组内 latency URLTest 未通过、没有真实叶子身份的候选和明确 `exhausted` 的候选；Mihomo 按真实类型确认的 `compatible/direct/reject/global/pass/block` 控制面终端不是叶子；不得按节点显示名判断类型。叶子必须属于当前组成员，并在 manifest 绑定 source 的 `/providers/proxies` 中唯一存在且健康，delay `unavailable` 不能伪装成通过。保护业务 check 在变更前后验证当前路径，并在 active artifact 内继续作为 fallback 健康目标，但不把业务 URL 的耗时或状态混入速度排序。
2. **地区代表**：每个授权地区取本轮 `available=true` 且 `latency=ok` 候选中最小 `delay_ms` 的叶子；同地区代表的同速比较复用下述 quota 与稳定身份顺序；跨地区比较在同速时还比较稳定 region ID，具体确定顺序由 `selection.algorithm` 服务的 `best_region` 定义。
3. **地区切换**：当前地区代表仍合格时，只有替代地区代表满足 `current_delay_ms - alternative_delay_ms >= selection.region_switch_margin_ms`（默认 150）才切换；当前地区没有合格代表时直接选最快合格地区。业务 status 只决定是否合格，不参与差值。
4. **机场与节点**：地区确定后，在当前故障层的合格 `(provider,node)` 中按 `delay_ms` 升序；只有 delay 完全相同才读取显式 quota tie-break（已知剩余量大的优先），再按稳定 provider ID、node ID 排序。`subscription|buyout` 不得覆盖真实 delay；`primary|reserve` 只决定当前候选层，primary 阶段无合格结果时才进入 reserve，不能把 reserve 当成隐含速度权重。
5. **能力组合**：每个 capability 先按自己的授权范围和门槛过滤候选。automatic capability 形成一个无环依赖图：唯一根能力先选择；跟随能力只在根能力地区对自身仍合格时复用该地区，否则选择自身同轮最快合格地区。依赖来自 `prefer_region_from`，engine 不按 `standard`、AI、地区或机场名称分支。
6. **回退**：automatic 选择中 primary 候选全部失败后才进入 reserve。运行时 path probe 失败先由 Mihomo 在 manifest 列出的 primary tier 机场中选择，主用层全部失败后进入 manifest 列出的 reserve tier，最后由外层 guard 进入 `DIRECT`。显式 enable/select 事务失败则先把 active capability guard 切到 `DIRECT`，以 selector/runtime readback 建立即时安全护栏，再恢复 Recovery Profile owner/runtime，原生恢复失败才进入所选后端 passthrough。保护域名结果始终独立报告。任何选择写入失败或业务回读失败都先恢复此前健康 selector，否则走同一事务恢复顺序。

若 delay 全部不可用但业务仍可达，NetFleet 不宣称“最快”并保持当前路径。测速失败不是 quota exhausted，也不能触发隐藏的第二测量方法。

调度、启动等待、运行失联和事务恢复统一由[运行与恢复](runtime-and-recovery.md)定义；
本文件只定义每轮输入与选择。配置结构由[产品对象](domain-model.md#配置解耦合同)定义。

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

`providers` 只描述稳定 provider ID、稳定命名的所选后端 subscription section、计费类型、quota metadata 映射和故障层级；cache 文件名只能由 section 派生，匿名 `@subscription[n]` 和第二个 `cache` 身份都必须拒绝。`regions`/`provider_regions` 只描述可复用的网络资源、授权关系、国旗/显示名和节点 filter；`capabilities` 描述开关、显示名、允许/排除地区及可选选择参数；顶层 `selection` 只提供默认地区和叶子切换门槛；`automation` 只提供调度开关、选择周期、轻量 readback 周期和 runtime grace；`checks` 分别声明整机场 health-check 总预算与单节点 delay 合同；`fail_open.healthcheck` 显式引用 `fail_open.probes` 作为 path/guard 运行期健康合同。换机场、开关能力、测速 URL、超时、保护 URL、健康探针映射、周期或门槛都只改 target-local policy，不改 comparator、compiler 或 adapter。门槛缺省只由 policy owner 解析：capability 覆盖、否则 `selection`、否则 150；compiler、selector 和 status 不得各自再写一份缺省。


对应源码与验证入口见[开发验证](../development/validation.md)。
