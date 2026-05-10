# 项目状态

本项目定位为基于 Raft 的强一致分布式 KV 存储系统，重点验证 Raft 在 KV 存储场景下的核心链路，包括日志复制、状态机应用、WAL 持久化、节点重启恢复、基础 Snapshot 和多节点故障恢复。

## 已完成内容

- KV 状态机：支持 Put / Get / Append / Delete
- Raft 多节点运行：支持三节点启动和 Leader 选举
- Leader 重定向：Follower 返回 Leader 地址，客户端自动重试
- 客户端请求去重：基于 client_id + request_id 避免重复执行
- WAL 持久化：保存 currentTerm、votedFor、Raft 日志和 commitIndex
- 节点重启恢复：启动时加载 Snapshot 和 WAL，回放已提交日志
- 基础 Snapshot：保存 KV 数据和客户端去重表，支持日志压缩
- 故障测试脚本：支持 Leader 宕机、Follower 掉线、节点重启和一致性校验

## 已验证场景

- Core tests 全部通过
- 完整 Raft server 构建通过
- 三节点集群启动成功
- Put / Get / Append / Delete 正常
- Leader 宕机后多数派继续服务
- 旧 Leader 重启后追赶日志并恢复一致
- Follower 掉线期间集群继续写入
- Follower 重启后追赶日志并恢复一致
- 全量集群重启后数据不丢失
- Snapshot 触发后生成 snapshot.dat
- Snapshot + WAL 重启恢复成功
- check_consistency.sh 验证三节点最终一致

## 暂不实现内容

当前版本重点保证一致性和恢复链路，不追求工业级数据库能力，暂不实现：

- 动态节点扩缩容
- 分片 KV
- 事务
- MVCC
- SQL 层
- ReadIndex / Lease Read
- RocksDB / LevelDB 存储引擎
- Kubernetes 部署
- 工业级完整 InstallSnapshot
