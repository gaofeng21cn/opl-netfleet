# 0004：版本化 package 与 deployment bundle 分离

## 上下文

代码与每台设备的 policy、订阅、Nikki mixin、平台参数和秘密变化频率不同。每次部署都重建并
传输完整 bundle 浪费时间，把实例配置打进软件包又会泄漏秘密并破坏同一 artifact 的可复制性。

## 决定

OpenWrt 代码交付采用「薄系统包壳 + 签名纯源码 Release Bundle + 原子符号链接切换」架构，并与实例配置彻底分离：

- **薄系统包壳（`opl-netfleet`、`luci-app-netfleet`）**：只声明系统依赖、稳定 init/rpcd/LuCI 入口及 Bundle 验签公钥；跨版本发布纯解释型 `noarch` `.apk`（OpenWrt 25.12+）与零 SDK 确定性构建的 `all` `.ipk`（OpenWrt 24.10 / iStoreOS）。原生二进制与内核依赖（如 `mihomo-meta`、`opl-netfleet-https-compat`、`opl-netfleet-device-identity`）及第三方扩展包继续由系统包管理器独立拥有。
- **签名纯源码 Release Bundle**：纯 `.uc`/`.js`/配置模板与默认服务插件打入单一签名归档（`opl-netfleet-bundle-<ver>.tar.gz` + `release-manifest.json` + `.sig`），绑定精确源码身份与 `min_shell_version`，在设备 `/usr/share/opl-netfleet/releases/<ver>/` 下解压校验，并通过 `current` / `previous` POSIX 原子符号链接在 `apk` 与 `opkg` 设备上共用同一更新、预检、即时回滚与崩溃恢复引擎。
- **配置权威分离**：private OPL Instance 是用户 desired configuration 的唯一权威；deployment bundle 只是从它生成的四文件投影，由部署器消费，不进入软件包、Release Bundle 或 Git。

## 后果

- 纯脚本默认产品升级与回退收敛为单归档验签和符号链接原子切换，消除跨分支 `ucode -c` 字节码 ABI 绑定及多微包链式钩子脆弱性，也无需为每个 OpenWrt `opkg` 分支维护独立 SDK。
- 代码未变化时无需重建 Release Bundle，实例输入未变化时无需重复更新配置；同一 canonical artifact 可在单独授权的目标间推广，同时每个目标仍必须独立验收。

## 未采用

- 把 policy、订阅 URL/token、节点或 mixin 打入公共软件包或 Release Bundle；
- 手工维护 deployment bundle，并把它称为第二个 Instance；
- 长期保留构建期跨分支 `ucode` 字节码预编译，或把默认产品拆分为二十余个微包并让包钩子依赖旧代字节码执行 `prerm`；
- 软件包或 Bundle 切换时绕过 staged/activate 合同自动替换数据面。

## 重审条件

- 若 OpenWrt 原生配置系统未来成为 private Instance 的真实 owner，必须先证明秘密边界、跨目标 overlay 和回滚语义，再调整 renderer；代码与实例配置仍保持独立分发；
- 若低算力硬件实测证实纯源码加载成为控制面瓶颈，可在设备端按当前解释器指纹在本地旁路生成只读字节码缓存并在解释器升级时自动失效回退源码，仍不得恢复跨设备构建期字节码分发。
