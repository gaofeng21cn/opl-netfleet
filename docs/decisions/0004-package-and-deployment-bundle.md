# 0004：版本化 package 与 deployment bundle 分离

## 上下文

代码与每台设备的 policy、订阅、Nikki mixin、平台参数和秘密变化频率不同。每次部署都重建并
传输完整 bundle 浪费时间，把实例配置打进软件包又会泄漏秘密并破坏同一 artifact 的可复制性。

## 决定

版本化 OpenWrt package 只包含 runtime、supervisor、rpcd、init 和 LuCI 字节，并绑定精确
source 身份。private OPL Instance 是用户 desired configuration 的唯一权威；deployment bundle
只是从它生成的四文件投影，由部署器消费，不进入 package 或 Git。

## 后果

代码未变化时无需重建软件包，实例输入未变化时无需重复更新配置；同一 canonical artifact 可
在单独授权的目标间推广，同时每个目标仍必须独立验收。

## 未采用

- 把 policy、订阅 URL/token、节点或 mixin 打入公共 package；
- 手工维护 deployment bundle，并把它称为第二个 Instance；
- package 安装时绕过 staged/activate 合同自动替换数据面。

## 重审条件

若 OpenWrt 原生配置系统未来成为 private Instance 的真实 owner，必须先证明秘密边界、跨目标
overlay 和回滚语义，再调整 renderer；代码与实例配置仍保持独立分发。
