# HTTPS 兼容模块

HTTPS 兼容是原生后端的可选增强，不改变应用 URL、业务鉴权或原有出口策略。
设备一次性信任私有 CA，代理按需签发目标证书；CA 属于设备私有状态，不能随普通
更新重新生成。私钥不进入 Git、UI 或普通诊断导出，公开证书可通过认证 RPC 下载。

独立配置拥有总开关、已接入设备和目标规则。设备使用稳定 ID、显示名和明确 IP
地址；规则拥有 ID、显示名、设备引用、精确域名或域名后缀、目标端口、开关和
`h2|bypass` 策略。精确匹配优先于后缀，较长后缀优先于较短后缀；同一设备、
端口和匹配目标的重复规则拒绝。未登记设备、未知 TLS 域名和未匹配目标不解密。

`mitmdump` 负责 TLS 和 HTTP，NetFleet 策略适配器选择目标并启用双向流式传输。
上游证书验证必须开启；默认不保存请求、响应、密钥或原始异常文本。
普通 HTTP 按规则协商上游 HTTP/2；WebSocket 使用独立 HTTP/1.1 上游连接。
客户端已经通过 ALPN 提供 HTTP/2 时保留原始 TLS 连接，不解密，不要求该运行时
额外信任兼容 CA。协议转换只接管未提供 HTTP/2 的客户端；内部健康探针验证完整转换链。
除显式代理探针外，接管准入还要求 IPv4、IPv6 回环连接通过内核 NAT、生产透明
监听端口、原始目标地址读取以及 H1→H2 请求往返。探针仅匹配带专用 socket mark 的
回环连接，不接管 LAN 流量；它不能替代真实 LAN 入站、防火墙与应用验收。
业务状态码原样返回，不能用 401、429 等业务响应触发模块故障恢复。
客户端取消必须释放活动请求；失败 POST 不自动重放。

控制入口、gateway 接管和设备私有配置分别拥有自己的限定写集，共用现有 mutation
锁，不通过全局 disable/compile/enable 应用兼容配置。用户开关与实际接管状态分开。
关闭先撤销新连接接管，再排空现有连接；进程崩溃时不能恢复原 TCP/SSE 流。

接管许可使用内核到期机制，最长十秒；健康检查每两秒执行，失联不续期。
故障恢复后连续健康三十秒才重新接管，十分钟内第三次故障暂停自动恢复。
旁路恢复原有 NetFleet 选路，不等于关闭 NetFleet 或强制直连。用户关闭优先于
自动恢复。代理出站不得再次进入兼容接管，无法证明选路等价时不能启用。
原生路由器的服务排除规则只有在实际兼容进程的 UID、GID 和 cgroup 均不匹配时
才不影响准入；身份缺失、未知账户或可能匹配的规则继续旁路。

生产启用要求协议实测、OpenWrt 软件包和 QEMU 故障演练通过；源码或本机协议测试
不能替代目标设备的接管、旁路和应用验收。

## 运行入口与接入

`opl-netfleet-https-compat` 是独立可选包，使用固定的 mitmproxy 12.2.3、Python 3.13
和 ARM64/musl 依赖。构建入口是 `scripts/https-compat/build-package.sh`，参数依次为
OpenWrt SDK、依赖目录、APK 签名私钥、输出目录和源码 ref。依赖由同目录 Dockerfile
构建。组件包安装验证与基础 NetFleet qualification 分开，二者都不能替代网络验收。

`compatibility_get/apply/enable/disable/probe/ca` 经 rpcd、`main.uc` 和专属 controller
到达唯一实现。所有 mutation 使用当前 revision；revision 同时绑定配置和信任记录。
`probe` 的 `trust_record`、`trust_revoke`、`recover` 操作分别记录接入工具证明、撤销
设备接管和人工解除故障锁定。`ca` 只返回公开 PEM 及 SHA-256，不接受任意文件路径。

私有配置和稳定 CA 位于 `/etc/opl-netfleet/compatibility`，运行状态与有效规则位于
`/var/run/opl-netfleet-compat`。原生 gateway 的现有观察进程每两秒调用 tick；引擎由
procd 托管。nftables 租约只存在于 `inet netfleet_compat`，不修改基础 NetFleet 表。
原生 gateway 合同保留 conntrack mark 的 `0x01000000` 位标识兼容连接归属；它与
Mihomo 的 packet mark 分开。兼容模块在 conntrack 后、TPROXY 前，仅为未确认的
首个 TCP SYN 按有效租约设置该位。原生 LAN TPROXY 跳过这类连接，兼容 NAT 完成
重定向；连接归属不会随租约失效而改变。没有有效租约的新连接不带该位，走原路径。
精确域名仅为当前 DNS 解析出的候选 IP 建立许可，解析失败撤销该规则许可，不能
扩为全部目标地址。共享 IP 仍须在 TLS 阶段确认域名；域名后缀规则需要候选端口
范围的 TLS 筛选，因此其接管范围比精确规则大。
接管前读取内核实际的 LAN mangle 链，确认首条规则按上述归属位返回；旧核心、
规则丢失或顺序不匹配时保持旁路，不能仅凭安装版本或服务 ready 状态准入。
停止命令先进入维护旁路，最多等待三十秒排空，健康连接未排空则停止操作失败。
APK 会忽略包钩子的失败退出码，因此升级、卸载钩子必须等待排空才能返回，不能
用报错退出阻止文件替换。管理员可先执行 `control.py drain` 做有界排空，再运行
包操作。维护旁路保留用户开启意图，验证组件后通过人工恢复重新接管。
ARM64 依赖安装约占 80 MiB；安装和重装还需要包管理器的临时空间，不能只按压缩包
大小评估设备可用空间。兼容模块的 QEMU 验证使用 512 MiB 根分区。

LuCI 的“配置 → HTTPS 兼容”独立保存规则，不调用全局配置应用。概览与诊断只投影
摘要，React 是参考界面。macOS 工具通过已验证主机身份的 SSH 获取公开 CA，使用
系统 `security` 安装、验证或撤销信任。工具不会改应用 URL。下载后可执行：

```sh
python3 netfleet-macos-trust.py install --target router-admin --device mac
python3 netfleet-macos-trust.py verify --target router-admin --device mac
python3 netfleet-macos-trust.py revoke --target router-admin --device mac
```

系统信任证明只证明系统证书库，Codex App、CLI 和图片运行时分别显示实际验证状态。
未实际验证的运行时保持“待实际验证”，不能由系统证书安装成功推导为应用已经可用。
设备地址变更使旧信任接入记录失效。撤销接管后，工具确认连接排空才移除系统信任。

设备管理员通过 `control.py private-backup /root/netfleet-compat-private.tar.gz` 生成
包含配置、接入记录和 CA 私钥的私有备份。目标目录必须仅管理员可访问，备份文件
使用 0600 权限；此动作不暴露给 rpcd 或浏览器。普通诊断导出不包含这份备份。
