# 开发与安装插件

NetFleet 的插件接口让能力以独立 OpenWrt 软件包交付，安装后即被宿主发现，加载、
卸载和替换插件无需重启核心。脚手架提供可直接运行的 UCode 示例；插件也可以使用
设备已安装的 Shell、Python 或其他运行时。微内核方向、宿主职责与生命周期合同统一由
[模块与扩展](../architecture/extensions.md)定义。

## 创建插件

在开发机准备 Python 3、NetFleet 源码和匹配设备平台的 OpenWrt SDK。设备需要安装支持
Plugin API v1 的 NetFleet；生成包依赖宿主提供的 `netfleet-plugin-api-v1` 虚拟包，包管理器
会拒绝不兼容的旧宿主。Python 是开发工具依赖，UCode 示例不要求设备安装 Python。
SDK 构建在 Linux 的大小写敏感文件系统内完成；macOS 可使用 Linux 容器的独立卷。

```sh
python3 scripts/netfleet-plugin.py scaffold link-health /tmp/link-health --label "Link health"
python3 scripts/netfleet-plugin.py validate /tmp/link-health
```

生成目录包含 `manifest.json`、可执行 `control` 和 Apache 2.0 `LICENSE`。脚手架以
[device-info 示例](../../examples/plugins/device-info/control)为起点，已实现完整生命周期
和 `inspect` 诊断动作，通过 ubus 读取系统发行版、运行时间、内存和负载。先运行这条链，
再把诊断逻辑替换为所需能力。插件各自使用 `/var/run/opl-netfleet-plugin-<id>` 保存示例
加载状态；实际插件可以使用自己拥有的私有目录和服务保存配置及运行状态。

插件 ID 使用小写字母、数字和单个连接号，首字符为字母，最多 48 个字符。
`https-compat` 和 `zashboard` 已属于内置模块。软件包名称必须为
`opl-netfleet-plugin-<id>`。新增业务动作写入 manifest 的 `actions`，值为 `read` 或
`write`；`get`、`load`、`unload`、`reload` 已由宿主定义，无需重复声明。

`dependencies` 填写运行时的实际 OpenWrt 包名称。额外模块、程序和静态文件放在
`resources/` 内，打包时保留相对路径和执行权限。发布前将 manifest 的 `version` 与
软件包版本一同更新。`validate` 检查声明、安装路径、权限和文件类型，不执行插件代码。

## 实现入口

宿主在独立进程中调用 `control <action> <private-request-file>`。第二个参数指向临时
JSON 文件，例如：

```json
{"request":{"api_version":1,"id":"link-health","action":"inspect","params":{}}}
```

成功时标准输出只返回一个 JSON 对象，并以退出码 0 结束；日志写标准错误。业务结果放在
`result` 中，例如 `{"ok":true,"result":{"uptime_seconds":120}}`。失败返回
`{"ok":false,"error":"reason"}` 及非零退出码。宿主向调用者返回统一错误分类。

`get` 必须读取真实状态并返回布尔 `loaded` 与 `ready`。`load`、`unload` 应可重复调用；
插件卸载时先停止接收新工作，再释放自身进程、监听、规则及其他资源。`unload` 完成且
回读 `loaded=false` 后，宿主才会执行 reload 的 load 阶段。对于连接处理插件，加载状态
不能代替连接排空证据。业务配置变更所需的版本检查、迁移与回滚由插件自己的状态 owner
实现，版本参数通过 `params` 传入。

单次调用应在 30 秒内完成，响应不超过 64 KiB。长时任务交给插件自己的受管服务运行，
入口返回当前进度；卸载未完成时应返回失败，保留后续继续排空所需状态。插件以设备 root
权限运行，权限声明用于管理员审阅和接口准入；选择第三方插件来源时采用与其他 OpenWrt
软件包相同的信任标准。

## 生成与编译软件包

```sh
sdk=/path/to/openwrt-sdk
python3 scripts/netfleet-plugin.py package-source /tmp/link-health \
  "$sdk/package/opl-netfleet-plugin-link-health" --license Apache-2.0
make -C "$sdk" defconfig
make -C "$sdk" package/opl-netfleet-plugin-link-health/compile V=s
```

生成器输出标准 OpenWrt `Makefile` 和 `files/`，由 SDK 生成 APK 或 IPK。
`--license` 必须与插件实际许可证一致；同一软件版本重新打包可增加 `--release`。
输出目录已存在时生成器会拒绝覆盖，使用新的输出目录或先审阅原目录。

默认包适用于解释型入口及跨平台资源，使用 `PKGARCH:=all`。需要本地二进制的插件可
直接扩展生成的标准 Makefile，增加真实 `Build/Compile` 并使用目标架构，随后按 OpenWrt
SDK 的正常流程构建。插件源码、依赖和生成包的版本应一起进入项目版本管理。

APK 发布使用 SDK 的签名工具。以下命令在构建机执行，私钥只留在构建环境：

```sh
apk_tool="$sdk/staging_dir/host/bin/apk"
signing_key=/secure/plugin-signing-private.pem
feed=/path/to/plugin-feed
apk_package="$feed/opl-netfleet-plugin-link-health-0.1.0-r1.apk"
"$apk_tool" adbsign --allow-untrusted --reset-signatures --sign-key "$signing_key" "$apk_package"
"$apk_tool" mkndx --root "$sdk" --keys-dir /path/to/trusted-public-keys \
  --output "$feed/packages.adb" --sign "$signing_key" "$apk_package"
"$apk_tool" verify --keys-dir /path/to/trusted-public-keys "$apk_package"
```

将构建得到的 APK 放入上述 feed 目录，公钥与 feed 索引一并发布到自己的 HTTPS 包源；
管理员核对公钥指纹后，将公钥放入设备 `/etc/apk/keys/`，并将包源加入
`/etc/apk/repositories.d/` 中的 `.list` 文件。IPK 使用目标 OpenWrt 版本的 opkg feed
索引与签名流程。公钥可信来源与软件包签名验证都属于安装流程，安装时保留签名检查。

## 安装、加载与更新

以下命令在已获授权的目标设备执行。先确认 package 名称、目标版本和所需依赖，再进行
具名操作；数据面插件部署前按[准入证据](../architecture/overview.md#准入证据)完成验证。

```sh
apk update
apk add opl-netfleet-plugin-link-health
ucode /usr/libexec/opl-netfleet/main.uc plugins-list
```

安装后插件保持未加载。组件页可直接查看并加载、重载或卸载插件；CLI 则先取得当前
revision，写入私有请求，再调用宿主：

```sh
umask 077
plugin_work=$(mktemp -d /tmp/netfleet-plugin-cli.XXXXXX)
ucode /usr/libexec/opl-netfleet/main.uc plugins-list >"$plugin_work/list.json"
ucode -e '
import * as fs from "fs";
const rows = json(fs.readfile(ARGV[0])).result.plugins;
const plugin = filter(rows, item => item.id == "link-health")[0];
if (type(plugin?.revision) != "string") exit(1);
printf("%J\n", {request: {id: "link-health", action: "load", revision: plugin.revision, confirm: true, params: {}}});
' "$plugin_work/list.json" >"$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc plugin-call "$plugin_work/request.json"
```

成功结果应同时包含 `loaded:true` 和 `ready:true`。随后执行插件自己的诊断动作：

```sh
ucode -e 'printf("%J\n", {request: {id: "link-health", action: "inspect", params: {}}});' \
  >"$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc plugin-read "$plugin_work/request.json"
rm -rf "$plugin_work"
```

重载或卸载时重新取得清单，将请求的 `action` 改为 `reload` 或 `unload`。宿主使用现有
全局写锁串行调用，插件不能在入口外再持有这把锁并回调宿主。

```sh
apk upgrade opl-netfleet-plugin-link-health
apk del opl-netfleet-plugin-link-health
```

上述两条命令分别用于升级和删除，按当前操作选择执行。IPK 设备对应使用 `opkg update`、
`opkg install <package>`、`opkg upgrade <package>` 和 `opkg remove <package>`。

生成包的 preinst/prerm 先进入插件维护状态，再通过 root CLI `plugin-drain` 调用旧版
unload 并回读 get。宿主在同一把写锁内完成排空与 `replacing` 标记写入，随后拒绝所有
插件代码执行，包管理器才开始替换或删除旧文件。排空阶段仍可执行 get 和 unload；
`plugin-drain` 可重复调用且不向浏览器开放。postinst/postrm 完成后清除维护状态，升级
完成后重新取得 revision 并显式 load，新版入口立即生效。首次安装也经过同一入口，宿主
在锁内确认旧插件不存在后直接进入 replacing，避免执行尚未完整安装的代码。

若旧插件仍在排空，包操作会等待并输出原因，修复插件的退出条件后会继续。包操作中断后，
`/var/run/opl-netfleet-plugin-maintenance/<id>` 可能保留；优先重试原包操作完成恢复。
只有确认没有正在进行的包操作、旧实例已退出且安装文件完整后，才可手动移除对应目录中
的 `replacing` 标记和空目录，并重新读取清单、显式加载。不要删除仍在工作的插件文件
来解除等待。

## 验证与发布

自有及第三方插件采用同一条验证路径：开发机校验声明并编译包，在隔离 OpenWrt 中完成
安装、get、load、业务动作、reload、unload、升级与删除。覆盖调用超时、load 失败后的
退出、重复卸载及旧 revision 请求。设备真实服务、流量或规则由相应插件回读验收。

可运行示例位于 [examples/plugins/device-info](../../examples/plugins/device-info/manifest.json)。
SDK 自身验证入口为 `python3 -m unittest discover -s tests -p test_plugin_sdk.py`；它证明
脚手架和包生成行为，实际运行与包管理器验收由 OpenWrt 环境完成。
