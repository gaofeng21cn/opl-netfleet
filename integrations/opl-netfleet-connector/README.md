# OPL NetFleet Connector

此可选连接模块仅向 OPL Mini App 提供本机 NetFleet 状态与打开入口，不安装或管理
NetFleet App。随包 Skill 提供同一读取/打开入口；模块不含凭据、网络设置或常驻服务。
Framework 通过原生 Codex 插件管理器承载内部模块，安装后动态发现 `opl-package.json`。
`headless_internal` 模块必须关闭交互式插件曝光，仍由 Framework 调用；直接手工执行
`codex plugin add` 会默认启用曝光，需在同一隔离作用域运行
`opl packages disable opl-netfleet-connector --json` 对齐已有内部模块合同。

macOS 的状态来自运行中 NetFleet 的私有 socket，打开动作只使用固定 bundle ID。
未安装时显示不可用；已安装但退出时仍可显式打开，状态读取不会启动 App。
`installed` 只表示固定 App 可以打开；`owner_available` 与 `freshness` 表示本次 owner
观测是否可用。过期观测不显示为当前网络状态，刷新仍调用原 owner。该模块的载体资格
保持 `development_only`；本地隔离安装与调用通过不能替代正式发行或真实网络验收。
测试入口：仓库根目录运行 `node --test tests/desktop-miniapp.test.mjs`。
原生隔离载体验收见[开发验证](../../docs/development/validation.md#miniapp-连接模块)。
