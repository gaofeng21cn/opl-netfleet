# 开发、安装与热替换插件

NetFleet 的功能插件与第三方插件采用相同的发现、调用和安装入口。只安装微内核即可
接入独立插件；`opl-netfleet` 是默认产品组合，不是插件开发的强制依赖。
服务组合与代码生命周期的完整合同见[微内核](../architecture/microkernel.md)，进程接口见
[模块与扩展](../architecture/extensions.md)。

## 选择插件类型

| 类型 | 适合的实现 | 入口 | 示例 |
| --- | --- | --- | --- |
| 服务插件 | UCode 功能、可复用服务、业务命令与调度 | `lib/*.uc` 返回服务工厂，声明服务依赖 | [host-info](../../examples/plugins/host-info/manifest.json) |
| 进程插件 | 独立程序、不同语言运行时、已有外部服务 | 可执行 `control` 接收动作与私有请求文件 | [device-info](../../examples/plugins/device-info/manifest.json) |

服务插件通过具名接口组合能力，适合继续拆分和扩展 NetFleet 自身功能。进程插件保留
Plugin API v1，可以使用设备已安装的 Shell、Python、UCode 或其他运行时。

开发机需要 Python 3 和 NetFleet 源码；设备需要支持相应接口的 `opl-netfleet-kernel`。
软件包使用匹配目标平台的 OpenWrt SDK 构建。SDK 需要 Linux 的大小写敏感文件系统，
macOS 可使用 Linux 容器的独立卷。Python 仅供开发工具使用。

## 创建服务插件

```sh
python3 scripts/netfleet-plugin.py scaffold host-info /tmp/host-info --kind service --label "Host information"
python3 scripts/netfleet-plugin.py validate /tmp/host-info
```

生成目录包含 `manifest.json`、`lib/reader.uc`、`lib/summary.uc` 和 Apache 2.0 `LICENSE`。
示例读取本机 `/proc` 中的运行时间、内核版本和系统负载，不修改网络，不依赖其他功能包。
`host-info.reader` 提供系统读取接口，`host-info.summary` 声明依赖 reader，并向 CLI 提供
`host-info` 命令。替换示例逻辑时保留这条可运行调用链，再逐步增加所需能力。

每个模块返回工厂，工厂接收当前调用的 `context` 并返回服务对象。例如：

```javascript
return function(context) {
    const reader = context.use("host-info.reader");
    function inspect(argv) {
        if (length(argv) != 1) return { ok: false, error: "unexpected_arguments" };
        return reader.snapshot();
    };
    return { inspect };
};
```

`context.use()` 只解析该服务在 `requires` 中声明的接口，并检查所需 major。
`commands` 将命令绑定到本插件的服务方法；方法接收包括命令名在内的 `argv` 数组，
返回 `{"ok":true,"result":{...}}` 或 `{"ok":false,"error":"reason"}`，由内核输出。
普通服务方法可以返回自身业务数据，再由命令方法组织对外结果。

服务名使用带点号的命名空间，例如 `host-info.reader`；模块路径为 `lib/` 下的 `.uc`
文件。跨插件调用通过服务接口和声明依赖完成，不导入另一插件的私有源码。`fs` 等系统
模块可以正常导入；额外运行包写入 `package_dependencies`。服务依赖和软件包依赖分别
说明调用合同与安装需求，声明外部服务时应同时声明提供者的包依赖。

模块可以拆分为多个文件，额外程序和静态资源可放入 `resources/`。`validate` 检查声明、
模块文件、相对路径和权限，不执行插件逻辑。公开服务接口不兼容时增加其 major；普通
实现更新只增加插件 `version`。接口 major 与软件包版本各自表达不同的兼容关系。

## 服务绑定

首次安装只交付代码。显式 load 会启用插件，并为尚未占用的服务建立绑定；已有提供者
绑定不会因安装另一个包而被覆盖。默认组合在 `/usr/share/opl-netfleet/system.json` 中
声明，设备私有覆盖位于 `/etc/opl-netfleet/system.json`，例如：

```json
{
  "schema": "opl-netfleet-system.v1",
  "bindings": {
    "host-info.reader": "host-info",
    "host-info.summary": "host-info"
  },
  "enabled": {"host-info": true}
}
```

日常加载由内核维护这些字段。需要替换服务提供者时，新插件应提供相同服务名与兼容的
接口 major，再针对相关 `bindings` 做结构化配置更新并验证调用。上面是局部覆盖示例，
已有私有配置需要合并保留。覆盖文件由 root 持有，权限为 `0600`。

`scheduler` 可以指定服务和方法作为常驻调度入口；具体调度规则归服务插件。单纯增加
诊断或业务命令无需新增调度入口，也无需安装默认产品的其他功能包。

## 管理资源生命周期

示例服务仅在调用期间读取系统信息，不持有跨调用资源，因此不需要生命周期方法。
持有进程、监听、连接或网络规则的服务插件，在 manifest 中同时声明 `lifecycle.drain`
和 `lifecycle.resume`；两者分别指定本插件的 `service` 与 `method`。

`drain` 先停止接收新工作，再完成必要排空和资源回读，成功时返回
`{"ok":true,"result":{...}}`。内核保留结果并将其作为参数交给 `resume`，后者恢复原先
需要恢复的状态并回读结果。两种方法都应支持重试。业务数据迁移、配置版本检查和失败
恢复由对应插件实现；仅返回退出成功不能代替真实资源已释放。

包替换由内核按依赖关系排空受影响的资源 owner，并等待在途代码调用结束。后续调用
读取完整的新版本。选优算法等不在 Mihomo 长期依赖链中的插件更新不会重启 Mihomo；
资源插件自身或其依赖更新时，由该资源插件执行排空与恢复。

## 保留进程入口

不指定 `--kind` 时继续生成进程插件，也可以显式选择：

```sh
python3 scripts/netfleet-plugin.py scaffold device-info /tmp/device-info --kind process
python3 scripts/netfleet-plugin.py validate /tmp/device-info
```

宿主调用 `control <action> <private-request-file>`，请求文件内容例如：

```json
{"request":{"api_version":1,"id":"device-info","action":"inspect","params":{}}}
```

标准输出只返回一个 JSON 响应，日志写标准错误。成功使用退出码 0，失败使用非零退出码。
`get` 返回布尔 `loaded` 和 `ready`；`load/unload` 应可重复执行，`reload` 由宿主完成
卸载、回读、加载、回读。自定义动作声明在 `actions` 中，值为 `read` 或 `write`。

单次进程调用应在 30 秒内完成，响应不超过 64 KiB。长时工作交给插件自己的受管服务，
入口返回实际状态。运行依赖填入 `dependencies`，额外文件放在 `resources/` 中。
安装或升级后使用显式 load 启用进程插件。

## 生成与发布软件包

```sh
sdk=/path/to/openwrt-sdk
python3 scripts/netfleet-plugin.py package-source /tmp/host-info \
  "$sdk/package/opl-netfleet-plugin-host-info" --license Apache-2.0
make -C "$sdk" defconfig
make -C "$sdk" package/opl-netfleet-plugin-host-info/compile V=s
```

生成器输出标准 OpenWrt `Makefile` 和 `files/`，由 SDK 生成 APK 或 IPK。服务插件依赖
`opl-netfleet-kernel` 与声明的 `package_dependencies`；进程插件依赖微内核、API v1
虚拟包及声明的 `dependencies`。SDK 不强制引入 `opl-netfleet` 默认产品组合。

`--license` 必须与插件实际许可证一致。同一软件版本重新打包可增加 `--release`；输出
目录已存在时生成器拒绝覆盖。默认包适用于解释型代码，使用 `PKGARCH:=all`；本地
二进制插件在标准 Makefile 中实现 `Build/Compile`，并使用实际目标架构。

所有插件包的 preinst/postinst/prerm/postrm 都委托
`/usr/libexec/opl-netfleet-plugin-package <id> <phase>`。该入口由微内核提供，负责排空、
代码替换准入和恢复。插件包不复制另一套锁、安装器或网络恢复逻辑。

APK 发布前，将构建产物放入自己的 feed 目录，并使用 SDK 工具签名。下面的公钥目录
需要包含与私钥对应、供使用者核验的公钥：

```sh
apk_tool="$sdk/staging_dir/host/bin/apk"
signing_key=/secure/plugin-signing-private.pem
feed=/path/to/plugin-feed
apk_package="$feed/opl-netfleet-plugin-host-info-0.1.0-r1.apk"
"$apk_tool" adbsign --allow-untrusted --reset-signatures --sign-key "$signing_key" "$apk_package"
"$apk_tool" mkndx --root "$sdk" --keys-dir /path/to/trusted-public-keys \
  --output "$feed/packages.adb" --sign "$signing_key" "$apk_package"
"$apk_tool" verify --keys-dir /path/to/trusted-public-keys "$apk_package"
```

将软件包、公钥和索引发布到自己的 HTTPS 包源。管理员核对公钥指纹后，将公钥放入
设备 `/etc/apk/keys/`，并将源加入 `/etc/apk/repositories.d/` 的 `.list` 文件。IPK 使用
对应 OpenWrt 版本的 opkg 索引与签名流程。插件代码以设备管理员权限运行，选用第三方
来源时采用与其他 OpenWrt 软件包相同的信任标准。

## 独立安装与热替换

以下命令在已获授权的设备执行，设备只需安装微内核及插件声明的依赖：

```sh
apk update
apk add opl-netfleet-plugin-host-info
ucode /usr/libexec/opl-netfleet/main.uc plugins-list
```

组件页和 CLI 使用同一加载入口。CLI 先取得当前 revision，再发送私有写请求：

```sh
umask 077
plugin_work=$(mktemp -d /tmp/netfleet-plugin-cli.XXXXXX)
ucode /usr/libexec/opl-netfleet/main.uc plugins-list >"$plugin_work/list.json"
ucode -e '
import * as fs from "fs";
const rows = json(fs.readfile(ARGV[0])).result.plugins;
const plugin = filter(rows, item => item.id == "host-info")[0];
if (type(plugin?.revision) != "string") exit(1);
printf("%J\n", {request: {id: "host-info", action: "load", revision: plugin.revision, confirm: true, params: {}}});
' "$plugin_work/list.json" >"$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc plugin-call "$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc host-info
rm -rf "$plugin_work"
```

load 成功应返回 `loaded:true` 和 `ready:true`，`host-info` 命令应返回当前内核版本、
运行时间和负载。进程插件使用相同方式 load，再通过 `plugin-read` 调用 get 或其声明的
读动作；服务插件的命令直接按 manifest 注册名称调用。

发布新版本后执行具名升级：

```sh
apk upgrade opl-netfleet-plugin-host-info
ucode /usr/libexec/opl-netfleet/main.uc host-info
```

已启用的服务插件保留系统绑定，包管理入口完成必要恢复后，下一次调用读取新代码。
进程插件升级后重新取得 revision 并显式 load。卸载运行中的服务插件前，先确认没有
已启用插件依赖它，再以新的 revision 发送 `action:"unload"` 请求；删除软件包使用
`apk del opl-netfleet-plugin-host-info`。IPK 对应使用 `opkg install/upgrade/remove`。

包操作未完成时，先处理其报告的排空、依赖或恢复原因，再重试同一具名操作。保留
`/var/run/opl-netfleet-plugin-maintenance/<id>` 中的恢复状态，避免清理尚需继续退出或
恢复的旧文件。涉及设备数据面的插件仍按[设备准入](../architecture/overview.md#准入证据)
取得真实验收。

## 验证插件

发布前在隔离 OpenWrt 中完成独立安装、加载、业务命令、升级、卸载与删除，并覆盖缺失
依赖、接口 major 不匹配、提供者冲突、在途调用和生命周期失败。服务插件还需验证调用
实际来自绑定的提供者；包安装成功不能代替业务命令成功。

SDK 的开发机检查入口为 `python3 -m unittest discover -s tests -p test_plugin_sdk.py`。
Linux/OpenWrt 上可用 `ucode tests/plugin_sdk_service.uc examples/plugins/host-info` 执行
示例工厂、依赖组合和真实 `/proc` 读取；最终安装与热替换仍由 OpenWrt 软件包流程验收。
