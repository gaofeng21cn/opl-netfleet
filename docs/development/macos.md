# macOS MVP 构建与验证

面向本机开发和试用者。运行边界见[macOS 平台实现](../platform/macos.md)；首版复用
共享业务服务，提供本机窗口、配置导入、订阅、编译、选优、恢复和诊断，不包含 HTTPS
兼容插件、LAN 网关管理或 OpenWrt 软件包更新。第三方进程插件在桌面端明确不支持。

## 构建

需要 macOS 13 或更新系统、Xcode Command Line Tools、Python 3、CMake、Make 和
pkg-config 与 Bun。运行时由固定下载地址与 SHA-256 清单构建，不依赖已安装的 Clash 客户端：

```sh
python3 scripts/macos/bootstrap.py
python3 scripts/macos/build-app.py
open '.build/macos/OPL NetFleet.app'
```

构建器先按锁文件安装 `ui/` 构建依赖，执行 TypeScript 检查，再通过独立的
`vite.desktop.config.ts` 编译 React 桌面入口到 `ui/dist-desktop`。静态产物装入应用的
`Resources/desktop/web`，运行时不启动 Vite、不加载设备预览桥或模拟场景。
输出包含独立 Node、UCode、Mihomo、yq 和原生窗口。构建在任务缓存内完成，不安装
Homebrew 软件或特权服务。UCode 使用固定源码，Darwin 补丁解决实际 `popen` 及旧
macOS libc 兼容断点；源码、补丁与下载摘要均保留在构建入口和依赖回执中。
构建器检查包内动态库路径并进行本地 ad-hoc 签名；这不是 Developer ID 签名或公证。
App 图标由仓库现有 logo 通过 macOS `sips` 与 `iconutil` 生成；侧栏使用同一品牌源文件。
arm64 与 Intel 有独立依赖清单，某一架构构建成功不代表另一架构已经验收。

## 使用

业务界面与 React 参考面共用组件，提供概览、出口、机场、地区、配置和诊断六页。
Cmd+1 至 Cmd+6 切换页面，Cmd+R 刷新本机状态；关闭窗口仍保留后台会话。
机场、地区、出口、业务规则、自动运行与安全参数使用共享结构化表单。保存依据草稿初始
版本校验；出现版本冲突时保留草稿，需重新载入并核对后保存。高级 JSON 编辑仍可用于
完整策略，运行时校验始终生效。结构化保存、编译和启用是独立操作。

首次启动不启用代理。在“机场”粘贴 Clash / Mihomo 订阅地址，添加后自动下载、校验、
识别地区并编译，名称可留空。完整订阅配置保留其规则；仅节点列表使用最小主入口。
准备过程不会启动核心或接管网络，也不会产生重复的本地导入机场。无法识别地区或主入口
时显示待配置，可补充地区映射或导入完整配置后重试。手动文件导入仍位于“配置 → 基础配置”。

来源编辑、增删和启停前需停止核心；日常“更新订阅”可以在运行中执行。运行中的更新复用
共享缓存回退、编译、重载和保护检查。订阅列表显示节点记录数、最近更新时间及是否纳入
业务配置；保存成功与编译就绪分别反馈。显示名称、地址修改通过原订阅入口重新校验。

“启动 NetFleet”会启动真实核心并完成保护探针与选优；“退出增强”恢复原生 Profile，
仍保留代理。“停止代理”停止核心和调度。显式代理监听地址显示在概览中，应用
可以明确使用它；不遵循系统代理设置的程序需要 TUN。

系统代理和 TUN 在概览“本机流量接入”中选择，点击“应用接入方式”后确认。界面分别显示所选方式和真实接管状态。首次使用需安装本应用的有限特权组件，
并由 macOS 管理员授权建立会话；未安装或未授权时显示原因。安装不等于接管成功。
同一桌面进程的同模式重启复用授权会话；改变接管模式需要重新确认。现有其他客户端
仍运行时，应先在原客户端释放网络接管，不能让两个客户端并行争用路由。

关闭窗口保留运行；退出应用先恢复自身接管并停止核心，失败时保留窗口显示原因。
显式代理核心由独立的父进程观察桌面所有权管道，桌面进程被强制结束时仍能收回核心。
重启也检查持久 PID 与启动身份，不按进程名称批量终止代理。

配置默认位于 `~/Library/Application Support/OPL NetFleet`，目录与文件分别限制为
0700、0600。备份含订阅及节点凭据，应私下保存；应用不会上传这些数据。
导入先完整校验，再通过带恢复日志的文件事务替换；失败或中断恢复原配置。

## 验证

```sh
cd ui
bun run typecheck
bun run test
bun run build:desktop
cd ..
node --test desktop/tests/runtime.test.mjs
NETFLEET_RUNTIME_ROOT="$(python3 scripts/macos/bootstrap.py)" node desktop/tests/qualification.mjs
NETFLEET_RUNTIME_ROOT="$(python3 scripts/macos/bootstrap.py)" node desktop/tests/owner-crash.mjs
NETFLEET_RUNTIME_ROOT="$(python3 scripts/macos/bootstrap.py)" bun desktop/tests/react-client.ts
```

地区选择的界面回归使用 `ui/tests/selection-preview.html`。在 `ui/` 运行
`bunx vite --config vite.desktop.config.ts --host 127.0.0.1` 后打开该路径；测试页明确显示
脱敏数据，只记录确认回调，不连接设备或调用代理。检查地区行预选、出口授权过滤、
Escape 取消与焦点返回，以及“打开确认框后撤销授权”阻止提交。测试入口不进入应用包。

资格脚本启动隔离状态目录和本地 HTTP 代理，再通过真实 Mihomo 访问固定 HTTPS
204 目标；需要网络能访问该目标。它验证共享编译与选优、刷新、恢复、停止、备份、
未授权拒绝、无效导入保留原字节和核心异常退出状态。只使用显式代理，不改系统代理、
DNS 或路由。回执在 `.build/macos/qualification.json`；失败保留私有临时状态便于诊断。

订阅准备由第二个隔离实例单独验证：只包含节点列表的本地订阅必须完成下载、真实核心
校验、地区识别和编译，且核心保持停止；重复地址与下载失败必须拒绝并保留原有来源和
业务策略。该实例与手动导入使用不同状态目录，避免编译产物影响导入路径。

系统代理/TUN 另需授权后的实机验收：启用前后读取系统代理、DNS、路由和 utun；通过
实际应用访问，再分别停止核心、退出应用和切换网络，检查自身接管全部恢复。helper 的
`--self-test` 只验证确定性的状态恢复与身份逻辑，不能代替这项实机验收。
