# 微内核与功能插件

NetFleet 的内核负责插件发现、服务绑定、接口版本、依赖解析、调用准入和代码生命周期。
产品数据模型、OpenWrt 配置、Mihomo 后端、订阅、编译、选择、恢复、管理、诊断和自动
调度由功能插件提供。进程插件继续使用 [Plugin API v1](extensions.md)，UCode 功能插件
使用同一安装目录与管理入口，以服务接口组合设备本地调用。

## 对象与调用

插件包拥有代码、资源和版本；服务是插件提供的具名接口；命令将已有 CLI/RPC 操作绑定
到服务方法。系统配置选择服务提供者和常驻调度入口，插件私有配置仍由原功能 owner
持有。默认产品安装所需插件，内核单独安装时能够列出组件与报告缺失服务。

UCode 插件的 `manifest.json` 使用 `opl-netfleet-service-plugin.v1`，声明 `id`、`version`、
`package`、`services` 和 `commands`。服务声明包含接口 major、相对模块路径与所需服务
及 major。模块通过 `loadfile` 返回工厂，工厂接收 `context` 并返回接口对象；
`context.use(name)` 只解析该模块已声明的依赖。不同插件之间不按私有源码路径导入。
插件内部实现可以拆分文件，公开服务名称与内部布局分别演进。

系统默认绑定保存在 `/usr/share/opl-netfleet/system.json`，管理员覆盖保存在私有
`/etc/opl-netfleet/system.json`。提供者选择不依赖目录顺序或最后安装者。调用前解析当前
依赖图，拒绝缺失提供者、接口不匹配和循环依赖；按依赖关系创建所需服务，未使用的插件
不执行代码。命令路由沿用既有 CLI/RPC 名称和读写权限，浏览器不能指定模块路径。

## 平台能力边界

业务服务声明所需能力，不以 UCI 为依赖入口。当前 OpenWrt `platform` 插件分别提供以下
服务；系统绑定可以逐项选择其他提供者，依赖图只加载实际使用的能力实现。

| 服务 | 责任与接口 |
| --- | --- |
| `platform.storage` | JSON/YAML 读取、文件摘要与修改时间、文本和原子 JSON 写入、目录创建 |
| `platform.paths` | `POLICY_PATH`、`EVIDENCE_PATH`、`RECOVERY_PATH`，由安装平台确定存储位置 |
| `platform.profile` | `current_profile`、`set_profile`、`backend_enabled`、`set_backend_enabled`，读写所选后端配置并回读 |
| `platform.credentials` | `api_secret`、`proxy_authentication`，凭据只在设备内用于授权调用 |
| `platform.subscriptions` | `subscription_exists`、`subscription_display_name`、`subscription_options`、`subscription_quota`，输出规范化订阅元数据 |
| `platform.device` | `device_name`、`upstream_ready`，报告设备身份和上游可用性 |
| `platform.process` | `shell_quote`、`run_owner`，平台命令构造与已注册业务动作调用 |
| `platform.documents` | `validate_policy` 校验候选策略与当前平台约束，`load_policy`、`load_evidence` 加载有效文档，`write_evidence` 写入 evidence；不读取 UCI |

上述能力涉及的 UCI 字段、WAN/路由探测和 CLI 路径封装在对应提供者中。共享选择控制器依赖
profile、credentials、documents 和 paths；调度器通过 process 调用业务动作，不直接拼接
OpenWrt 安装路径。文件工具不会因读取 JSON 而加载凭据、订阅或 UCI 实现。

通用能力服务不是操作系统 API 的别名：返回值表达产品含义，后端配置仍由原 owner 保存。
替换提供者必须保持空值、失败结果、原子写入与回读语义；不能以缓存成功代替实际写入。
策略模型只校验 evidence 存储标识的结构；documents 校验其路径与 paths 提供者一致。
配置加载、生成候选与备份恢复均使用该校验，恢复在写入前拒绝不匹配的路径。
OpenWrt 仍只使用 `/etc/opl-netfleet/evidence.json`，策略不能指定另一写入位置。
`run_owner` 继续继承调用宿主的 mutation 锁，不能绕过命令准入或启动第二个调度循环。

平台能力解耦与完整宿主移植分别验证。当前 Linux 代码租约、进程身份、APK/procd 生命周期
及 DNS/TProxy 接管属于 OpenWrt 宿主实现；它们不因业务服务可替换就自动成为 macOS 能力。
订阅持久管理、后端设置及维护等 OpenWrt 专用服务仍包含 UCI 和本机操作。
跨平台产品方向见[设计白皮书](../product/whitepaper.md)，插件开发使用同一服务声明与绑定合同。

## 热替换与资源

每条 CLI/RPC 调用使用独立服务上下文和当前代码，不保留跨调用模块缓存。一次调用绑定
同一代代码，更新等待正在执行的调用结束后替换文件；新调用读取新版本。代码读取租约
与现有网络 mutation lock 分工明确：前者保护包文件的一致读取，后者仍是网络写入的唯一
串行入口。替换操作按网络锁、代码租约的固定顺序获取，避免互相等待。

不属于 Mihomo 长期依赖闭包的插件，例如选择算法，更新时不重启 Mihomo。持有服务、监听或网络规则的插件
必须先执行其退出与回读方法，包管理器确认交接后才能替换或删除文件。失败保留旧包和
退出所需代码，不将“文件已写入”等同于资源已移交。插件自己的持久数据迁移与恢复继续
由该插件承担。

资源插件按依赖拓扑退出和恢复，依赖消费者先退出、提供者先恢复。同一包事务涉及多个
插件时，共享资源只退出一次，相关包都结束替换后才恢复。失败保留退出意图和恢复记录，
后续重试先核对当前 owner 状态。包管理器启动服务的默认动作也受维护状态约束。

常驻 supervisor 只按系统配置调用调度服务。选择周期、订阅刷新、健康判断与恢复策略
归调度及对应功能插件；内核不实现这些业务规则。稳定入口在读取内核代码前持有共享
代码租约；supervisor 每个周期重新加载内核和调度插件，保留插件自己的周期状态。
内核包更新排空已安装插件及内核调用，完成文件替换后由同一协调入口恢复资源。

## 分发与验收

`opl-netfleet-kernel` 提供内核与稳定入口，`opl-netfleet-plugin-*` 提供功能及各自依赖，
`opl-netfleet` 组合默认产品。可选能力及第三方插件使用相同插件协议、包布局和安装流程。
拆分后的旧内置实现、静态注册和直接导入随调用迁移一起删除。

验证覆盖服务解析、版本与依赖错误、独立更新、在途调用排空、失败回退，以及原有
订阅、编译、启用、选择、恢复、关闭和设备管理路径。软件包与 QEMU 验收分别绑定真实
产物；物理设备部署继续遵守[设备准入](overview.md#准入证据)。
