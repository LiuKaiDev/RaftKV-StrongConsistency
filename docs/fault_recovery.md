# 故障恢复

## follower 掉线恢复

follower 掉线期间会错过 leader 的 AppendEntries。重启后先从本地 `snapshot.dat` 和 WAL 恢复状态，再等待 leader 继续发送 AppendEntries。如果 follower 的 `next_index` 落后到 leader 的 snapshot index 之前，leader 会发送 InstallSnapshot。

## leader 宕机重选

leader 宕机后，其他节点选举计时器超时并发起 RequestVote。获得多数派投票的 candidate 切换为 leader，继续对外服务。客户端请求旧 leader 或 follower 时会收到 `NOT_LEADER` 或连接失败，并重试其他 server。

## 旧 leader 重启

旧 leader 重启时从 WAL 恢复自己的 term、vote、commit 和日志。收到新 leader 更高 term 的 AppendEntries 后会退回 follower，并按日志匹配规则追赶最新日志。

## snapshot 安装

当前只做基础 Snapshot 恢复和日志压缩。原 cRaft 中已有 InstallSnapshot RPC 雏形，本项目保留基础路径，但不追求工业级流式分片、断点续传、并发安装保护等完整能力。

当 follower 缺失的日志已经被 leader 压缩，leader 可以发送 Snapshot 帮助 follower 恢复。follower 安装后更新：

- `last_included_index`
- `last_included_term`
- `commit_index`
- `last_applied`
- KV 状态机
- 客户端去重表

随后 follower 从 snapshot 之后的日志继续接收 AppendEntries。

## 节点重启恢复流程

1. 加载 `snapshot.dat`，恢复 KV 数据和去重表。
2. 加载 `raft_meta.dat`，恢复 term、vote、commit。
3. 加载 `raft_log.wal`，跳过 snapshot index 之前的日志。
4. 启动 Raft RPC 和 KV 客户端服务。
5. 不直接信任持久化的 `last_applied`，从 `snapshotIndex + 1` replay 到 `commitIndex`。
6. 通过 leader 的 AppendEntries 继续追赶最新状态。
