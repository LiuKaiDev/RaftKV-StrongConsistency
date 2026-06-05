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
- `read_log_total`: 使用 `read.mode: log` 的 Get 请求数。
- `read_index_total`: 进入 ReadIndex 路径的 Get 请求数。
- `read_index_success`: 完成 quorum 确认、等待本地状态机应用并成功读取的 ReadIndex 请求数。
- `read_index_failed`: ReadIndex 路径失败数，包括非 Leader、领导权变化、未满足安全屏障和超时。
- `read_index_timeout`: ReadIndex quorum 确认、本地 apply 等待或当前 term 提交屏障未满足导致的超时/可重试失败。
- `read_index_quorum_confirm_rounds`: Leader 发起 ReadIndex 多数派确认轮数。
- `leader_noop_appended`: 本节点成为 Leader 后追加内部 no-op 屏障日志的次数。
- `leader_noop_committed`: 本节点提交当前 term 内部 no-op 屏障日志的次数。
- `pre_vote_sent`: 本节点发出的 PreVote RPC 次数。
- `pre_vote_granted`: 本节点收到同意票的 PreVote 次数。
- `pre_vote_rejected`: PreVote RPC 失败或收到拒绝票的次数。
- `check_quorum_stepdown_count`: Leader 因 CheckQuorum 无法联系多数派而主动退位的次数。
- `check_quorum_rounds`: Leader 执行 CheckQuorum 检查轮数。
- `check_quorum_success`: CheckQuorum 检查时仍能联系多数派的轮数。
- `check_quorum_failed`: CheckQuorum 检查时未能联系多数派的轮数。
- `append_entries_batch_rpc_count`: 本节点发出的 AppendEntries RPC 批次数，包括空 heartbeat。
- `append_entries_entries_sent`: 本节点通过 AppendEntries 发送的日志条目总数。
- `append_entries_empty_heartbeat_count`: 本节点发出的空 AppendEntries heartbeat 次数。
- `append_entries_max_batch_observed`: 本进程观测到的最大 AppendEntries 日志批次大小。
- `follower_catchup_attempts`: 本节点向 follower 发送非空日志批次的次数。
- `follower_catchup_success`: 非空日志批次成功推进 follower matchIndex 的次数。
- `append_entries_stale_response_ignored`: 未能推进复制状态的旧成功响应或过期失败响应次数。
- `append_entries_inflight_rejected`: 为后续 pipeline 保留；当前 inflight 上限为 1，正常应为 0。

Metrics 默认启用但不持久化，节点重启后从 0 重新开始。它们是低成本核心观测信号，不是完整监控系统；benchmark 可以用 `commit_index`、`last_applied`、`wal_bytes`、客户端请求计数、ReadIndex 计数和 Leader 稳定性计数观察吞吐、积压、读路径切换、选举影响和多数派丢失。

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

## 6.1 ReadIndex 读模式

默认读模式仍是日志读：

```yaml
read:
  mode: log
```

显式启用 ReadIndex：

```yaml
read:
  mode: read_index
```

旧配置不写 `read:` 时等价于 `log`。非法值会导致 `kv_server` 启动时配置加载失败。

当前 `log` 读路径为：`kv_client get` 发送 TCP 请求，Leader 将 GET 序列化后调用 `Raft::submitCommand` 追加 WAL 和 Raft 日志，经 AppendEntries 复制到多数派，commit 后由 apply loop 按日志 index 应用到 `KVStateMachine::Apply`，再唤醒客户端返回。

`read_index` 路径为：Leader 不追加 GET 日志，而是先确认当前 term 已有提交点，再用空 AppendEntries heartbeat 对多数派做一次往返确认，记录 `read_index=commit_index`，等待 KV 层状态机已应用到该 index，最后通过 `KVStateMachine::GetLocal` 本地读取。Follower 直接返回 Leader hint。

不能只判断 `role == LEADER` 后直接读。旧 Leader 在网络分区或选举切换期间可能尚未感知新 term；ReadIndex 必须通过当前 term 的多数派 heartbeat 确认仍拥有领导权。也必须等待 `lastApplied/read_index` 对应的 KV 状态机应用完成，否则会从落后的本地状态机读取旧值。

本项目没有实现 Lease Read。Leader 当选后会追加并提交一条内部 no-op 日志作为当前 term 屏障，因此在没有业务写入的情况下也可以建立 ReadIndex 所需的当前 term 提交点。

ReadIndex 集成验证：

```bash
bash scripts/test_read_index.sh
```

默认 `scripts/test_all.sh` 不运行该慢速测试。需要显式开启：

```bash
RUN_READ_INDEX=1 bash scripts/test_all.sh
```

ReadIndex 模式下运行现有正确性脚本：

```bash
READ_MODE=read_index SEED=20260604 DURATION_SECONDS=60 OPERATION_COUNT=300 CLIENT_COUNT=4 \
  bash scripts/test_seeded_chaos.sh

READ_MODE=read_index SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=40 KEY_COUNT=3 \
  bash scripts/test_concurrent_linearizability.sh
```

## 6.2 Leader 稳定性

Leader 稳定性增强包含 Leader no-op barrier、PreVote 和 CheckQuorum。它们默认保持兼容关闭；在配置中显式启用：

```yaml
raft:
  pre_vote: true
  check_quorum: true
```

Leader no-op barrier 在节点转为 Leader 后立即追加一条内部 `NO_OP` 日志，写入现有 WAL 并通过普通 AppendEntries 复制提交。Apply 阶段识别内部 no-op，只推进 applied index 和等待者通知，不调用 KV 状态机，不写 dedup 表，也不会产生客户端业务响应。WAL frame 格式不变；内部 no-op 通过日志类型和不可由普通客户端构造的二进制命令标记识别，旧 WAL replay 也可以安全识别。

PreVote 在正式选举前发送 `preVoteRPC`，使用与 RequestVote 相同的日志新旧比较。PreVote 不增加本地 `current_term`，不修改 `voted_for`，不持久化 meta；只有获得多数派 PreVote 后才进入正式 Candidate 并增加 term。正式选举前还会重新检查最近 Leader 联系，避免 PreVote 往返期间刚恢复的 Leader 心跳被忽略。

CheckQuorum 只在 Leader 上运行，使用 `steady_clock` 和最近一次成功 AppendEntries/heartbeat 响应维护多数派联系窗口。当前窗口为 `election_timeout_ms_min`。Leader 在一个检查轮中发现最近窗口内无法联系多数派时主动退位为 Follower，停止对外声称自己是 Leader；后续通过正常选举恢复服务。

运行三节点 Leader 稳定性集成测试：

```bash
bash scripts/test_leader_stability.sh
```

默认 `scripts/test_all.sh` 不运行该慢速测试。需要显式开启：

```bash
RUN_LEADER_STABILITY=1 bash scripts/test_all.sh
```

该脚本使用隔离端口和数据目录，覆盖无业务写入时 no-op 屏障后的 ReadIndex、Leader 切换后立即 ReadIndex、Follower 停止恢复时 PreVote term 稳定性、停止两个 Follower 后 CheckQuorum 退位或拒绝成功读写，以及恢复多数派后的收敛。当前脚本通过停止进程模拟故障，不使用 iptables，也不覆盖真实网络分区的所有时序。

## 6.3 AppendEntries 批量复制

AppendEntries 批量复制通过配置限制单个 RPC 最多携带的连续日志条目数：

```yaml
raft:
  max_append_entries_per_rpc: 64
  max_inflight_append_entries_per_peer: 1
```

`max_append_entries_per_rpc` 缺省为 `64`，必须大于 0。`max_inflight_append_entries_per_peer` 当前只支持 `1`；配置为其他值会拒绝启动。本阶段没有实现 pipeline。

Leader 从 `nextIndex[peer]` 开始选择连续日志，单次最多发送 `max_append_entries_per_rpc` 条。批次可以包含普通客户端日志和内部 no-op。成功响应时，Leader 不信任 follower 返回的 `nextLogIndex` 来推进进度，而是使用本次请求上下文：`matchIndex[peer] = prevLogIndex + entries_size`，`nextIndex[peer] = matchIndex[peer] + 1`，并保持 matchIndex 单调不下降。空 heartbeat 成功只记录联系，不推进 matchIndex。

失败响应只允许把 `nextIndex` 向后回退，且不能低于 `snapshot_index + 1` 或已经确认的 `matchIndex + 1`。如果 `nextIndex[peer] <= snapshot_index`，Leader 继续走现有 InstallSnapshot 路径，安装完成后再用批量 AppendEntries 追赶 snapshot 之后的日志。

Follower 接收批次时按 `prevLogIndex/prevLogTerm` 校验，然后从 `prevLogIndex + 1` 起逐条合并。已存在且完全相同的日志保留；发现 term、command 或 type 冲突时从冲突处截断并追加 Leader 条目。空 heartbeat 不会因为没有日志而截断本地后续条目。

运行落后 follower 批量复制集成测试：

```bash
bash scripts/test_batch_replication.sh
```

默认 `scripts/test_all.sh` 不运行该慢速测试。需要显式开启：

```bash
RUN_BATCH_REPLICATION=1 bash scripts/test_all.sh
```

该脚本覆盖普通落后 follower 多批次追赶、Snapshot 边界下先安装 snapshot 再批量追赶、追赶期间 Leader 切换后最终一致，并保存 status、metrics、配置、节点日志和 replay 命令。Leader 切换场景会先等待旧 Leader 进程和端口不可用，再通过各节点 `status` 重新发现唯一 Leader，确认新 Leader 的 no-op barrier 已提交后再写入。若写入命中临时 `NOT_LEADER` 或连接失败，脚本会刷新 Leader 并有限重试；最终失败时会保存 `diagnostics/failure_context.txt`、每次请求的 stdout/stderr、节点状态和日志尾部。

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

## 14. Benchmark v2 性能基线

Benchmark v2 使用常驻 C++ 客户端 `kv_bench`，在一个进程中启动多个 worker 线程，不通过反复启动 shell 或 `kv_client` 进程测性能。

直接运行稳态基线：

```bash
SCENARIO=steady READ_MODE=log THREADS=4 DURATION_SECONDS=30 WARMUP_SECONDS=5 \
  KEY_COUNT=1000 VALUE_SIZE=128 \
  READ_PERCENT=70 PUT_PERCENT=20 APPEND_PERCENT=5 DELETE_PERCENT=5 \
  SEED=20260604 bash scripts/run_benchmark_v2.sh
```

三种场景：

- `SCENARIO=steady`: 三节点稳定运行，测基础吞吐和延迟。
- `SCENARIO=follower_down`: 正式测量中途停止一个 follower，保持多数派可用。
- `SCENARIO=leader_failover`: 正式测量中途停止 leader，等待重新选举，观察错误率、retry、p99 和恢复时间。

报告默认保存到：

```text
/tmp/raftkv-test-reports/<run_id>/benchmark-v2/
```

主要文件：

- `result.json`: 机器信息、参数、吞吐、成功/失败/retry、整体和分操作类型延迟。
- `result.csv`: 与 JSON 对齐的一行 CSV，便于后续画图。
- `status_before.txt`、`status_after.txt`: benchmark 前后三节点 Admin Status。
- `metrics_delta.txt`: Admin Metrics 差值。
- `faults.jsonl`: follower/leader 故障事件。
- `summary.txt`、`config.txt`、`git_commit.txt`、`machine_info.txt`、`node_logs/`: 复现实验所需上下文。

Smoke test 使用保守小参数：

```bash
bash scripts/test_benchmark_smoke.sh
```

默认 `scripts/test_all.sh` 不运行 benchmark smoke。需要显式开启：

```bash
RUN_BENCHMARK_SMOKE=1 bash scripts/test_all.sh
```

延迟指标含义：

- `p50`: 50% 请求延迟不超过该值，代表中位数体验。
- `p95`: 95% 请求延迟不超过该值，代表常见尾延迟。
- `p99`: 99% 请求延迟不超过该值，适合观察 failover、重试和磁盘抖动影响。

不要只看平均延迟。平均值会掩盖少量非常慢的请求，而 Raft 复制、选举、WAL fsync 和 snapshot 都可能主要体现在 p95/p99 上。

`READ_MODE=log` 的 `Get` 仍进入 Raft 日志，是 ReadIndex 优化前基线。`READ_MODE=read_index` 可用于同参数对比：

```bash
READ_MODE=log SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

READ_MODE=read_index SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

对比 `result.json` 中的 throughput、p50、p95、p99，以及 `metrics_delta.txt` 中的 `wal_bytes`、`append_entries_sent`、`snapshot_created_count`、`read_log_total` 和 `read_index_success`。单机阿里云 2 vCPU 小规格结果只用于项目学习和回归比较，不能宣传为生产级性能。

批量复制对比建议使用写入工作负载：

```bash
MAX_APPEND_ENTRIES_PER_RPC=1 \
SCENARIO=steady THREADS=2 READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

MAX_APPEND_ENTRIES_PER_RPC=64 \
SCENARIO=steady THREADS=2 READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

对比 `throughput_ops_per_second`、`latency_us_p50/p95/p99`，以及 `metrics_delta.txt` 中的 `append_entries_batch_rpc_count`、`append_entries_entries_sent`、`append_entries_max_batch_observed`。落后 follower 追赶耗时可用 `scripts/test_batch_replication.sh` 的报告目录和节点日志对比。

## 15. 清理运行时文件

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
