# 服务器验证清单

本文用于在 Alibaba Cloud Linux 3 上验证完整 Raft KV 服务是否真正跑通。Windows 本地阶段只建议做代码整理和 core tests，完整 Raft server 需要在 Linux 上验证。

## 1. 环境检查

```bash
uname -a
cat /etc/os-release
gcc --version
g++ --version
cmake --version
protoc --version
which grpc_cpp_plugin || true
```

如果 `protoc`、`grpc_cpp_plugin`、gRPC CMake config、libgo、spdlog 或 absl 不存在，先按 `docs/build_alinux3.md` 安装依赖，再继续。

## 2. Core tests

core tests 不依赖 gRPC/libgo，先验证 KV、WAL、Snapshot 和重启 replay：

```bash
BUILD_RAFT=OFF bash scripts/build.sh
```

期望通过：

- `test_kv_state_machine`
- `test_wal`
- `test_snapshot`
- `test_raft_log`
- `test_restart_replay`

## 3. 完整构建

```bash
bash scripts/build.sh
```

如果 CMake 找不到 Protobuf/gRPC，优先检查 `CMAKE_PREFIX_PATH`、`Protobuf_DIR`、`gRPC_DIR` 是否指向正确安装路径。

## 4. 三节点启动

```bash
bash scripts/start_cluster.sh
```

确认 `run/node1.pid`、`run/node2.pid`、`run/node3.pid` 存在，并查看 leader：

```bash
./bin/kv_client leader
```

## 5. Admin Status 与核心 Metrics

查询单节点只读状态：

```bash
./bin/kv_client --servers=127.0.0.1:9001 status
```

输出为稳定 `key=value` 文本，便于脚本解析。状态查询只读取节点本地内存和 WAL 文件大小，不进入 Raft 日志，不触发复制，不要求当前节点是 leader。节点不可用时 `kv_client status` 返回非零退出码，并在 stderr 输出连接错误。

展示三节点状态：

```bash
bash scripts/show_cluster_status.sh 127.0.0.1:9001 127.0.0.1:9002 127.0.0.1:9003
```

单节点不可用时表格中显示 `UNAVAILABLE`，脚本继续查询其他节点。

运行 Admin Status 集成测试：

```bash
bash scripts/test_admin_status.sh
```

默认批量测试不运行该慢速集成测试。需要纳入 `test_all` 时显式开启：

```bash
RUN_ADMIN_STATUS=1 bash scripts/test_all.sh
```

状态字段含义：

- `node_id`: 配置中的外部节点 id。
- `role`: 当前 Raft 角色，稳定文本为 `FOLLOWER`、`CANDIDATE` 或 `LEADER`。
- `current_term`: 当前任期。
- `leader_id`: 当前已知 leader 的外部节点 id；未知为 `-1`。
- `commit_index`: 当前已提交的最高日志 index。
- `last_applied`: 已应用到 KV 状态机的最高日志 index。
- `last_log_index`: 本地日志中可见的最高日志 index，包括 snapshot index。
- `snapshot_index`: 本地 snapshot 的 last included index。
- `snapshot_term`: 本地 snapshot 的 last included term。
- `log_entry_count`: snapshot 之后仍保留在内存日志中的条目数，不包含占位条目。
- `wal_bytes`: 当前 Raft WAL 日志文件大小；文件不存在时为 `0`。

Metrics 字段含义：

- `election_count`: 本节点进入 candidate 并启动选举的次数。
- `leader_change_count`: 本节点成功成为 leader 的次数。
- `append_entries_sent`: 本节点发出的 AppendEntries RPC 次数。
- `append_entries_success`: 对端成功接受的 AppendEntries RPC 次数。
- `append_entries_failed`: RPC 失败或对端拒绝的 AppendEntries 次数。
- `request_vote_sent`: 本节点发出的 RequestVote RPC 次数。
- `request_vote_granted`: 收到同意票的 RequestVote 次数。
- `request_vote_rejected`: RPC 失败或收到拒绝票的 RequestVote 次数。
- `install_snapshot_sent`: 本节点发出的 InstallSnapshot 元数据 RPC 次数。
- `install_snapshot_success`: 对端允许继续传输 snapshot 文件的次数。
- `install_snapshot_failed`: InstallSnapshot RPC 失败或对端不允许传输的次数。
- `snapshot_created_count`: 本节点本地创建 snapshot 成功次数。
- `wal_recovery_truncated_tail_count`: 本进程启动期间 WAL 恢复截断损坏尾部的次数。
- `client_request_total`: TCP KV 客户端 Put/Get/Append/Delete 请求总数。
- `client_request_success`: TCP KV 客户端请求成功数。
- `client_request_failed`: TCP KV 客户端请求失败数，包括 NotLeader、BadRequest、Timeout 和业务失败。

Metrics 默认启用但不持久化，节点重启后从 0 重新开始。它们是低成本核心观测信号，不是完整监控系统；后续 benchmark 可以用 `commit_index`、`last_applied`、`wal_bytes` 和客户端请求计数观察吞吐与积压，ReadIndex 阶段可以用 leader/term/commit/apply 指标排查只读路径是否落后或经历选举。

## 6. KV 基础功能

当前 KV API 契约：

- `Put`: 覆盖或创建 key，成功返回 `OK`。
- `Get`: key 存在时返回当前 value；key 不存在时返回 `KEY_NOT_FOUND`。
- `Append`: key 存在时追加到当前 value；key 不存在时以空字符串为初始值创建 key；成功返回追加后的新 value。
- `Delete`: key 存在时删除并返回 `OK`；key 不存在时返回 `KEY_NOT_FOUND`。

```bash
./bin/kv_client put name chaos
./bin/kv_client get name
./bin/kv_client append name _raft
./bin/kv_client get name
./bin/kv_client delete name
./bin/kv_client get name || true
```

期望：`get name` 先返回 `chaos`，append 后返回 `chaos_raft`，delete 后返回 `KEY_NOT_FOUND`。

## 7. Leader 故障

```bash
old_leader=$(./bin/kv_client leader | awk '{print $1}')
bash scripts/kill_leader.sh
sleep 3
./bin/kv_client leader
./bin/kv_client put after_leader_kill ok
./bin/kv_client get after_leader_kill
bash scripts/restart_node.sh "$old_leader"
sleep 3
bash scripts/check_consistency.sh
```

期望：旧 leader 被 kill 后集群重新选主，继续写入成功，旧 leader 重启后最终数据一致。

## 8. Follower 掉线恢复

```bash
leader=$(./bin/kv_client leader | awk '{print $1}')
follower=1
if [ "$follower" = "$leader" ]; then follower=2; fi
kill "$(cat run/node${follower}.pid)"
rm -f "run/node${follower}.pid"
./bin/kv_client put follower_down_key ok
bash scripts/restart_node.sh "$follower"
sleep 5
bash scripts/check_consistency.sh
```

期望：follower 重启后追上 leader，三个节点 dump 一致。

## 9. 节点重启恢复

```bash
./bin/kv_client put restart_key restart_value
bash scripts/stop_cluster.sh
bash scripts/start_cluster.sh
./bin/kv_client get restart_key
```

期望：重启后仍返回 `restart_value`。

## 10. 基础 Snapshot 验证

可以临时把 `config/node*.yaml` 中的 `snapshot.max_log_entries` 调小，例如 20，然后写入一批数据：

```bash
for i in $(seq 1 100); do
  ./bin/kv_client put "snap${i}" "value${i}" >/dev/null
done
find data -name snapshot.dat -ls
bash scripts/stop_cluster.sh
bash scripts/start_cluster.sh
./bin/kv_client get snap100
bash scripts/check_consistency.sh
```

期望：生成 `snapshot.dat`，重启后数据仍可读取。

## 11. 三节点 Snapshot 集成验证

三节点 Snapshot 集成脚本会使用独立端口、独立数据目录和独立报告目录，验证严重落后的 follower 通过 InstallSnapshot 恢复、继续追日志、重启后通过本地 Snapshot + WAL 恢复，以及重复请求不会被二次执行：

```bash
bash scripts/test_snapshot_cluster.sh
```

验证脚本稳定性时建议在普通 SSH 终端重复运行：

```bash
for i in {1..5}; do
  echo "===== snapshot integration round $i ====="
  RUN_ID="snapshot-repeat-$i-$(date +%Y%m%d-%H%M%S)" \
    bash scripts/test_snapshot_cluster.sh || break
done
```

默认 `scripts/test_all.sh` 不运行该慢速集成测试。需要纳入完整批量测试时显式开启：

```bash
RUN_SNAPSHOT_CLUSTER=1 bash scripts/test_all.sh
```

测试数据默认保存到 `/tmp/raftkv-test-data/<run_id>/snapshot-cluster`，报告默认保存到 `/tmp/raftkv-test-reports/<run_id>/snapshot-cluster`，节点日志在测试数据目录的 `logs/` 下。失败时优先查看报告目录中的 `last_error.txt`、`failure_context.txt`、`client_attempts.log`，以及数据目录中的 `logs/node*.log`。可以通过 `TEST_DATA_ROOT`、`TEST_REPORT_ROOT` 和 `RUN_ID` 覆盖。

## 12. Seeded chaos 集成验证

seeded chaos 脚本会启动独立三节点集群，用固定 seed 生成随机 KV 请求和节点停止/重启事件，并保存请求历史、故障历史和失败现场。本阶段做基础一致性校验，不声称完成形式化线性一致性证明。

```bash
SEED=20260604 DURATION_SECONDS=60 OPERATION_COUNT=300 CLIENT_COUNT=4 \
  bash scripts/test_seeded_chaos.sh
```

验证稳定性时建议在普通 SSH 终端重复运行：

```bash
for i in {1..10}; do
  echo "===== seeded chaos round $i ====="
  RUN_ID="seeded-chaos-$i-$(date +%Y%m%d-%H%M%S)" \
    SEED=20260604 DURATION_SECONDS=60 OPERATION_COUNT=300 CLIENT_COUNT=4 \
    bash scripts/test_seeded_chaos.sh || break
done
```

默认 `scripts/test_all.sh` 不运行 chaos。需要纳入完整批量测试时显式开启：

```bash
RUN_SEEDED_CHAOS=1 bash scripts/test_all.sh
```

测试报告默认保存到 `/tmp/raftkv-test-reports/<run_id>/seeded-chaos/`，数据默认保存到 `/tmp/raftkv-test-data/<run_id>/seeded-chaos/`。报告中包含 `summary.txt`、`run_info.txt`、`history.jsonl`、`faults.jsonl`、`client_attempts.log`、`last_error.txt`、`failure_context.txt`、最终节点 dump、生成配置、PID 文件和节点日志。失败时 `summary.txt` 中的 `replay_command` 可直接复制重放同一 seed。

## 13. Concurrent linearizability 集成验证

并发线性一致性脚本会启动独立三节点集群和多个后台 worker。每个 worker 使用独立 `client_id`、单调递增 `request_id`，并发随机执行 `put/get/append/delete`。脚本记录每个操作的调用开始和完成时间、最终响应、重试次数，并在 workload 期间依次停止一个 follower、恢复该 follower、停止当前 leader、等待重新选举、恢复 leader，最后检查三个节点 dump 一致并运行独立 checker。

```bash
SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=40 KEY_COUNT=3 \
  bash scripts/test_concurrent_linearizability.sh
```

checker 读取 `history.jsonl`，按 key 分开搜索满足单 key KV API 模型和实时顺序约束的串行顺序。该模型与上文 KV API 契约一致，包括 `Append` 对不存在 key 的创建语义。输出 `LINEARIZABILITY PASSED`、`LINEARIZABILITY FAILED` 或 `LINEARIZABILITY INCONCLUSIVE`。该结果只说明当前测试历史通过了有界搜索检查，不是对所有执行的形式化证明。

可以用 `FAULT_MODE` 分层复现：

```bash
SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=15 KEY_COUNT=2 FAULT_MODE=none \
  bash scripts/test_concurrent_linearizability.sh

SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=15 KEY_COUNT=2 FAULT_MODE=follower_restart \
  bash scripts/test_concurrent_linearizability.sh

SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=15 KEY_COUNT=2 FAULT_MODE=leader_restart \
  bash scripts/test_concurrent_linearizability.sh

SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=15 KEY_COUNT=2 FAULT_MODE=full \
  bash scripts/test_concurrent_linearizability.sh
```

`CHECKER_TIMEOUT_SECONDS` 控制 checker 搜索超时。`SAVE_NORMALIZED_HISTORY=1` 时报告目录会额外保存 `normalized_history.jsonl`。

默认 `scripts/test_all.sh` 不运行该慢速集成测试。需要纳入批量测试时显式开启：

```bash
RUN_LINEARIZABILITY=1 bash scripts/test_all.sh
```

测试报告默认保存到 `/tmp/raftkv-test-reports/<run_id>/linearizability/`，数据默认保存到 `/tmp/raftkv-test-data/<run_id>/linearizability/`。报告中包含 `summary.txt`、`run_info.txt`、`history.jsonl`、`normalized_history.jsonl`、`faults.jsonl`、`checker_output.txt`、`client_attempts.log`、`linearizability_failure.json`、`linearizability_failure.txt`、生成配置、PID 文件、节点日志、worker traceback、失败片段和可复制的 `replay_command`。如果 checker 通过，failure 文件可以不存在。

## 14. 清理运行时文件

验证完成后，如需提交 GitHub，请不要提交：

```text
build/
bin/
lib/
data/
.data/
logs/
run/
*.pid
*.log
```
