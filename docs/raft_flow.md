# Raft 流程

## Leader 选举

节点启动为 follower。选举计时器超时后切换为 candidate，增加 term，投票给自己，并向其他节点发送 RequestVote。多数派同意后成为 leader，开始周期性发送 AppendEntries 心跳。

## 日志复制

leader 为每个 follower 维护 `nextIndex` 和 `matchIndex`。AppendEntries 中包含 `prevLogIndex`、`prevLogTerm` 和新增日志。follower 校验前一条日志匹配后追加日志；冲突时返回下一个可尝试的 index。

## Commit 与 Apply

leader 发现某条当前 term 日志已复制到多数派后推进 `commitIndex`。Apply 协程严格从 `lastApplied + 1` 到 `commitIndex` 顺序发送 `ApplyMsg`，KV 状态机只从 Apply 通道执行命令。

## Snapshot

日志数量超过阈值后，状态机生成 Snapshot，Raft 截断 `last_included_index` 之前的日志。当前只要求基础 Snapshot 落盘、日志压缩和重启恢复；完整工业级 InstallSnapshot 作为后续优化方向。
