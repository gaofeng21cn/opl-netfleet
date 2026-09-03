# 0001：单一运行与 mutation owner

## 上下文

NetFleet 同时面对 CLI、rpcd/LuCI、supervisor 和部署器。若这些入口分别实现编译、选择或
恢复逻辑，会产生并行 writer、不同判断口径和无法解释的设备状态。

## 决定

`main.uc` 是唯一 one-shot activation owner。CLI、rpcd、supervisor 和部署器只调用它并共用
一个短生命周期 mutation lock。compiler、comparator 和 activation helper 保持纯计算或窄
适配职责；UI 只投影状态和转发有限命令。

## 后果

所有写入可以由同一事务、manifest 和 owner readback 验证，但新增入口必须复用现有动作，
不能为了方便复制一条选择或恢复路径。

## 未采用

- 为 UI、后台调度和部署分别建立 worker 或 operation queue；
- 让 supervisor 自己排序、写 selector 或清理数据面；
- 以浏览器缓存或 evidence 作为第二运行事实源。

## 重审条件

只有出现单进程无法满足且可被真实 caller 证明的并发或持久任务需求，并且仍能维持唯一
mutation owner、故障恢复和 target-local readback 时，才重新评估执行模型。
