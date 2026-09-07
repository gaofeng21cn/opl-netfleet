# 开发、安装与热替换插件

NetFleet 的功能插件与第三方插件采用相同的发现、调用和安装入口。只安装微内核即可
接入独立插件；`opl-netfleet` 是默认产品组合，不是插件开发的强制依赖。
服务组合与代码生命周期的完整合同见[微内核](../architecture/microkernel.md)，进程接口见
[模块与扩展](../architecture/extensions.md)。

## 选择插件类型

| 类型 | 适合的实现 | 入口 | 示例 |
| --- | --- | --- | --- |
| 服务插件 | UCode 功能、可复用服务、业务动作、页面与调度 | `lib/*.uc` 返回服务工厂，声明依赖和贡献 | [workspace-note](../../examples/plugins/workspace-note/manifest.json)、[host-info](../../examples/plugins/host-info/manifest.json) |
| 进程插件 | 独立程序、不同语言运行时、已有外部服务 | 可执行 `control` 接收动作与私有请求文件 | [device-info](../../examples/plugins/device-info/manifest.json) |

服务插件通过具名接口组合能力，适合继续拆分和扩展 NetFleet 自身功能。进程插件保留
Plugin API v1，可以使用设备已安装的 Shell、Python、UCode 或其他运行时。

开发机需要 Python 3 和 NetFleet 源码；设备需要支持相应接口的 `opl-netfleet-kernel`。
软件包使用匹配目标平台的 OpenWrt SDK 构建。SDK 需要 Linux 的大小写敏感文件系统，
macOS 可使用 Linux 容器的独立卷。Python 仅供开发工具使用。

## 创建完整功能插件

```sh
python3 scripts/netfleet-plugin.py scaffold workspace-note /tmp/workspace-note \
  --kind service --template complete --label "Workspace note"
python3 scripts/netfleet-plugin.py validate /tmp/workspace-note
```

完整模板包含 UCode 服务、CLI 命令、配置读写动作和浏览器 ES 模块页面。生成目录可以
直接成为独立仓库；开发、版本管理和包源码生成不要求把插件加入 NetFleet 源码树。
`manifest.json` 的动作和页面声明就是宿主接入入口，无需修改宿主的 RPC 或导航表。
SDK 排除顶层 `.git`、`.gitignore`、`.gitattributes` 和 `.github` 开发元数据，其余目录
按可安装 payload 校验。前端依赖和构建中间文件放在 payload 外，仅把最终资源输出到
`resources/`；也可以把生成目录作为独立仓库内的 `plugin/` 子目录。

示例 `workspace-note` 管理一份可编辑笔记。服务仅使用 UCode `fs` 模块；存储路径通过
`context.config.data_path` 注入，没有默认 OpenWrt 路径。读取和保存动作共享同一份
JSON，保存校验标题、正文和当前 `generation`，在相邻临时位置写入并验证后原子替换，
再回读最终文件。旧页面提交的 generation 会被拒绝，失败不会用默认数据覆盖损坏文档。
页面通过配置动作读取、编辑、保存，CLI 读取同一份结果。

在管理员已有的私有 `system.json` 中合并配置，保留其他字段。例如 OpenWrt 的默认实例：

```json
{
  "schema": "opl-netfleet-system.v1",
  "config": {
    "workspace-note": {"data_path": "/etc/opl-netfleet/plugin-data/workspace-note.json"}
  }
}
```

先由管理员创建 `data_path` 的父目录，并设置为仅当前宿主用户可写。OpenWrt 可执行：

```sh
mkdir -p /etc/opl-netfleet/plugin-data
chmod 0700 /etc/opl-netfleet/plugin-data
```

配置文件不随软件包安装或升级覆盖。
缺少路径时动作返回 `not_configured`，不会自行选择另一存储位置。macOS 原生 UCode
测试使用临时目录验证同一服务；平台宿主的安装和系统管理仍按其独立合同实现。

## 创建最小服务插件

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

浏览器业务动作声明在 `actions`，与 CLI 命令分开接收参数：

```json
{
  "actions": {
    "config-get": {"service": "workspace-note.document", "method": "read", "access": "read"},
    "config-set": {"service": "workspace-note.document", "method": "save", "access": "write"}
  },
  "configuration": {"read": "config-get", "write": "config-set"},
  "ui": [{"id": "note", "title": "Workspace note", "module": "resources/page.js"}]
}
```

动作方法接收 `params` 对象，返回同样的 `{ok,result}` 响应。动作只能绑定本插件声明的
服务，`configuration` 分别引用已有读动作和写动作。浏览器与 CLI 使用统一
`opl-netfleet.plugins` 对象的 `plugin_read` / `plugin_call`，CLI 为
`plugin-read` / `plugin-call`；写请求需要当前代码
revision 与显式确认，并受网络 mutation 锁保护。`get/load/unload/reload` 留给宿主管理
生命周期，业务动作使用其他名称。插件自己的数据版本与代码 revision 分别校验。

只贡献页面的服务插件可以使用 `services: {}`、`commands: {}` 和非空 `ui`；不需要
创建无实际用途的服务。页面仍按同一插件发现、安装、更新和卸载流程管理。

服务名使用带点号的命名空间，例如 `host-info.reader`；模块路径为 `lib/` 下的 `.uc`
文件。跨插件调用通过服务接口和声明依赖完成，不导入另一插件的私有源码。`fs` 等系统
模块可以正常导入；额外运行包写入 `package_dependencies`。服务依赖和软件包依赖分别
说明调用合同与安装需求，声明外部服务时应同时声明提供者的包依赖。

模块可以拆分为多个文件，额外程序和静态资源可放入 `resources/`。`validate` 检查声明、
模块文件、相对路径和权限，不执行插件逻辑。公开服务接口不兼容时增加其 major；普通
实现更新只增加插件 `version`。接口 major 与软件包版本各自表达不同的兼容关系。

## 贡献浏览器页面

`ui` 中的每页声明唯一 `id`、标题和 `resources/` 下的 `.js` 模块。模块导出
`mount(context)`，可以异步完成并返回清理函数。完整示例的
[page.js](../../examples/plugins/workspace-note/resources/page.js) 使用原生 DOM，可替换为
自己的界面框架与构建产物。

| 页面 context | 用法 |
| --- | --- |
| `container` | 当前页面拥有的挂载节点 |
| `api.read(action, params)` | 调用本插件声明的读动作，返回展开后的 `result` |
| `api.call(action, params)` | 调用本插件写动作；宿主绑定 revision、确认与用户写权限 |
| `configuration.read(params)` / `configuration.write(params)` | 调用 manifest 指定的配置动作，返回展开后的 `result` |
| `readOnly` | 当前宿主写权限；页面据此切换编辑控件，宿主仍校验每次写调用 |
| `signal` | 页面离开、插件卸载或代码 revision 变化时中止 |
| `scope` | 登记资源撤销、事件订阅与子作用域 |

示例将样式链接、DOM 和事件监听绑定到页面作用域和 AbortSignal，异步请求结束后先
检查 signal 再更新页面。相对资源使用 `new URL("./style.css", import.meta.url)`，不把
宿主路径或插件 ID 写死。配置值只通过 DOM 的 `value` / `textContent` 呈现。

宿主按当前插件清单构建导航，并按代码 revision 加载模块；同一实例的调用由宿主自动
绑定。页面退出或插件更新会先撤销旧页面，再挂载当前版本。SDK 把资源同时安装到
`/www/luci-static/resources/netfleet/plugins/<id>/<revision>/resources/`，只有声明 UI 的插件产生
这份公开投影；私有配置、凭据和后端实现文件不能放入 `resources/`。
revision 由完整安装 payload 计算。保持页面的静态 import、样式和其他资源为相对路径，
整套模块图随目录版本一起切换；不需要为每个 import 拼接查询参数。

## 服务绑定

业务插件只声明实际使用的能力，例如读取后端 Profile 时依赖 `platform.profile`，
访问凭据时依赖 `platform.credentials`，读取 JSON 时依赖 `platform.storage`。存储位置
通过 `platform.paths` 获取；policy/evidence 的加载校验使用 `platform.documents`。
接口责任见[平台能力边界](../architecture/microkernel.md#平台能力边界)。

准备跨平台复用时，把算法与流程保留在业务服务，将操作系统调用放入可替换提供者。
例如调度服务调用 `platform.process.run_owner`，OpenWrt 提供者负责 CLI 路径及锁的
继承；业务服务不启动第二个后台循环。开发者可以逐项替换提供者，不必重写选择算法。
本仓 [`portable_services_contract.uc`](../../tests/portable_services_contract.uc) 使用实际
manifest 和服务工厂，在不加载 UCI/ubus/procd 的环境中验证替代存储、编译、选择及调度：

```sh
ucode tests/portable_services_contract.uc
```

这条检查验证共享业务代码及能力接口；平台的文件权限、核心进程、网络接管、锁和软件包
生命周期仍由各平台的真实运行验收证明。选择、编译、策略模型和调度通过能力接口复用；
订阅持久管理、后端设置及维护等 OpenWrt 专用服务仍包含 UCI 和本机操作。移植这些服务
时，应将实际需要的系统操作交给平台提供者，并复用已有业务模型。

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

同一插件需要多份配置或局部提供者组合时，使用 `system.instances`。例如在现有配置中
合并独立的 `review` 实例：

```json
{
  "instances": {
    "review": {
      "config": {
        "workspace-note": {"data_path": "/etc/opl-netfleet/plugin-data/review-note.json"}
      }
    }
  }
}
```

请求携带 `instance: "review"` 选择已配置实例，不能在请求中传入即时绑定或模块路径。
实例继承默认组合，可以覆盖自己的 `bindings`、`enabled` 和 `config`；服务缓存、状态
和作用域按实例隔离。插件可通过 `context.id`、`context.instance`、`context.config`
及 `context.state` 读取当前身份、注入配置和当前上下文状态。跨调用数据应由插件自己的
持久化实现保存，不能把服务缓存或 `state` 当作数据库。

## 管理资源生命周期

服务作用域提供 `effect(cleanup)`、`on(event, handler)`、`emit(event, payload)`、
`scope()` 和 `dispose()`。`effect` / `on` 返回可提前撤销的函数；子作用域共享当前
实例的事件总线，撤销时按资源登记的逆序清理。工厂失败和调用结束同样会关闭作用域，
一个清理函数失败仍会继续清理其余资源。

短时资源直接登记实际清理动作，例如完整模板的文件事务：

```javascript
const transaction = context.scope();
transaction.effect(() => { fs.unlink(temporary); fs.rmdir(directory); });
transaction.effect(() => file.close());
// Complete and read back the operation, then release the transaction resources.
transaction.dispose();
```

这里的路径和文件由实际事务创建；完整的错误处理见
[document.uc](../../examples/plugins/workspace-note/lib/document.uc)。事件订阅、连接和
定时任务也登记其真实取消函数；具体执行机制由平台提供者负责。

两个示例都不持有跨调用资源，因此不需要额外的生命周期方法。
持有进程、监听、连接或网络规则的服务插件，在 manifest 中同时声明 `lifecycle.drain`
和 `lifecycle.resume`；两者分别指定本插件的 `service` 与 `method`。

`lifecycle.scope` 选择资源归属：缺省 `host` 的资源只在默认实例加载，具名实例调用会
返回 `plugin_resource_scope_required`。能独立管理每个实例资源的插件显式声明
`scope: "instance"`，并使用当前 context 的实例身份和配置定位自己的资源；软件包更新
会分别排空和恢复相关实例。不要把 Mihomo 等宿主级资源通过多实例重复启动。
进程插件 Plugin API v1 的生命周期仍按宿主归属处理。

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
`backends: []` 表示后端无关，设备信息示例因此只依赖微内核和其声明的系统包。
需要特定后端时，在数组中填写对应 ID；宿主从系统绑定的 environment 服务取得当前身份。
进程插件也可以声明同样的 `configuration` 和 `ui`，配置引用它已有的读写动作；
其 `actions` 值继续使用 `read` / `write` 字符串，动作执行仍由 `control` 负责。

## 生成与发布软件包

```sh
sdk=/path/to/openwrt-sdk
python3 scripts/netfleet-plugin.py package-source /tmp/workspace-note \
  "$sdk/package/opl-netfleet-plugin-workspace-note" --license Apache-2.0
make -C "$sdk" defconfig
make -C "$sdk" package/opl-netfleet-plugin-workspace-note/compile V=s
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
apk_package="$feed/opl-netfleet-plugin-workspace-note-0.1.0-r1.apk"
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
apk add opl-netfleet-plugin-workspace-note
ucode /usr/libexec/opl-netfleet/main.uc plugins-list
```

通用插件 RPC 由内核自身提供，例如 `ubus call opl-netfleet.plugins plugins_list`。
默认产品业务 RPC 仍位于独立 `opl-netfleet` 对象；第三方插件不需要为使用通用管理入口
额外安装默认网络功能。

组件页和 CLI 使用同一加载入口。CLI 先取得当前 revision，再发送私有写请求：

```sh
umask 077
plugin_work=$(mktemp -d /tmp/netfleet-plugin-cli.XXXXXX)
ucode /usr/libexec/opl-netfleet/main.uc plugins-list >"$plugin_work/list.json"
ucode -e '
import * as fs from "fs";
const rows = json(fs.readfile(ARGV[0])).result.plugins;
const plugin = filter(rows, item => item.id == "workspace-note" && item.instance == "default")[0];
if (type(plugin?.revision) != "string") exit(1);
printf("%J\n", {request: {id: "workspace-note", action: "load", revision: plugin.revision, confirm: true, params: {}}});
' "$plugin_work/list.json" >"$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc plugin-call "$plugin_work/request.json"
ucode /usr/libexec/opl-netfleet/main.uc workspace-note
rm -rf "$plugin_work"
```

load 成功应返回 `loaded:true` 和 `ready:true`。完成前面的存储路径配置后，
`workspace-note` 命令应返回标题、正文和 generation。`host-info` 最小模板使用相同流程，
其命令返回内核版本、运行时间和负载。进程插件使用相同方式 load，再通过 `plugin-read`
调用 get 或其声明的读动作；服务插件的命令直接按 manifest 注册名称调用。

读取完整模板配置的私有请求为：

```json
{"request":{"id":"workspace-note","action":"config-get","params":{}}}
```

把请求文件传给 `plugin-read`；保存则传给 `plugin-call`：

```json
{
  "request": {
    "id": "workspace-note",
    "action": "config-set",
    "revision": "<plugins-list 返回的当前 revision>",
    "confirm": true,
    "params": {"title":"Operations","text":"Current workspace note","generation":0}
  }
}
```

generation 使用刚读取的值；有实例时在 request 中同时传入该实例名。也可直接在新增
页面编辑保存，再用 `ucode /usr/libexec/opl-netfleet/main.uc workspace-note` 回读默认
实例的数据。浏览器页面使用同一动作，无需手工传 revision 或插件 ID。

发布新版本后执行具名升级：

```sh
apk upgrade opl-netfleet-plugin-workspace-note
ucode /usr/libexec/opl-netfleet/main.uc workspace-note
```

已启用的服务插件保留系统绑定，包管理入口完成必要恢复后，下一次调用读取新代码。
进程插件升级后重新取得 revision 并显式 load。卸载运行中的服务插件前，先确认没有
已启用插件依赖它，再以新的 revision 发送 `action:"unload"` 请求；删除软件包使用
`apk del opl-netfleet-plugin-workspace-note`。IPK 对应使用 `opkg install/upgrade/remove`。

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
最小示例工厂、依赖组合和真实 `/proc` 读取。设置 `UCODE=/path/to/ucode` 后，SDK 测试
还会在原生运行时执行完整模板，验证配置写入与回读、重新加载、版本冲突、损坏数据保护
和作用域清理；这部分可在 macOS 上运行，不需要 UCI/ubus 或默认产品插件。

完整插件还要在浏览器验证配置读取、修改保存、错误恢复、页面退出和版本替换后的旧资源
清理，以及只读用户不能执行写动作。最终独立安装、签名、升级和卸载由 OpenWrt 软件包
流程验收；包源码生成、源测试和浏览器测试分别证明各自的行为。
