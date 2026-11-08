# OPL NetFleet Connector

此可选连接模块仅向 OPL Mini App 提供本机 NetFleet 状态与打开入口，不安装或管理
NetFleet App。随包 Skill 提供同一读取/打开入口；模块不含凭据、网络设置或常驻服务。通过原生 Codex 插件管理器选择本仓
marketplace 中的 `opl-netfleet-connector`；安装后由 OPL 动态发现 `opl-package.json`。

macOS 的状态来自运行中 NetFleet 的私有 socket，打开动作只使用固定 bundle ID。
未安装时显示不可用；已安装但退出时仍可显式打开，状态读取不会启动 App。
测试入口：仓库根目录运行 `node --test tests/desktop-miniapp.test.mjs`。
