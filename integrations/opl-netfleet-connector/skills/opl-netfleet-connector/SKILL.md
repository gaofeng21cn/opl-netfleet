---
name: opl-netfleet-connector
description: Read the local NetFleet app status or open its independent macOS window when the user asks for NetFleet.
---

# NetFleet 本机连接

优先使用已发现的 OPL Mini App `opl-netfleet.status` 查看本机摘要。
如当前宿主无 Mini App，从此 Skill 所在目录运行
`printf '{}' | node ../../connector.mjs status`，保留不可用状态，不读取私有状态文件。

用户明确要求打开 NetFleet 时，使用 `opl.netfleet.connector.v1#open` 或
`printf '{}' | node ../../connector.mjs open`。`accepted` 只表示系统接受请求。
网络、订阅和运行模式操作在独立 NetFleet App 中完成；此连接模块不控制设备或代理。
