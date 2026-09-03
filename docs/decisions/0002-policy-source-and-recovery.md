# 0002：策略来源与恢复配置分离

## 上下文

正常编译需要规则、策略组和 DNS 输入；退出或事务失败需要一份已经独立验证的原生配置。
让同一个 `base_profile` 同时承担两种角色，会把正常策略来源、机场属性和灾难恢复错误耦合。

## 决定

使用两个独立身份：`PolicySource` 只作为 compiler 输入，`RecoveryProfileRef` 只用于 enable
前置、rollback、disable 和 recover。manifest 分别绑定两者，UI 分别解释正常配置与恢复目标。

## 后果

策略来源可以从迁移期 Nikki Profile 演进到机场无关 bundle，而不改变恢复目标；恢复配置
必须单独验证，不能从 provider、订阅名称或买断属性推断。

## 未采用

- 从 provider 自动合成恢复 Profile；
- 把主用或备用机场角色当作恢复身份；
- 继续保留一个兼容 `base_profile` 字段承载两个 owner。

## 重审条件

只有未来 native backend 已完整拥有正常运行与网络直通恢复，且原生 Profile 不再是任何真实
恢复路径时，才重新设计 Recovery Profile 的产品表达；正常输入与恢复 owner 仍不得合并。
