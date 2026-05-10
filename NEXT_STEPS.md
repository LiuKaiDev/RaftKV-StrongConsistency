# NEXT_STEPS

当前项目目标是校招简历可控版，不继续扩展大功能。下一阶段建议只围绕“能稳定构建、能跑脚本、能讲清楚”推进。

## 优先级 1：Linux 环境构建闭环

- 在 Alibaba Cloud Linux 3 上安装/确认 GCC、CMake、gRPC、Protobuf、libgo、spdlog。
- 先运行 `BUILD_RAFT=OFF bash scripts/build.sh` 验证 core tests。
- 依赖齐全后运行 `bash scripts/build.sh` 验证完整 server/client/tests。

## 优先级 2：三节点功能验证

详细命令见 `docs/server_validation.md`。


- `scripts/start_cluster.sh`
- `./bin/kv_client put name chaos`
- `./bin/kv_client get name`
- `scripts/kill_leader.sh`
- 等待重新选主后继续写入。
- `scripts/check_consistency.sh`

## 优先级 3：恢复场景验证

- follower 掉线后重启追赶日志。
- leader 宕机后重新选主。
- 节点重启后从 Snapshot + WAL replay 恢复状态。
- 日志超过阈值后生成 Snapshot 并截断旧日志。

## 暂不做

- ReadIndex / Lease Read
- 动态节点扩缩容
- 分片 KV
- 事务 / MVCC / SQL 层
