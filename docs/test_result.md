# 测试结果记录

## 测试环境

- 系统：Alibaba Cloud Linux 3.2104 U11 OpenAnolis Edition
- 编译器：GCC / G++ 10.2.1
- CMake：已安装
- Protobuf：25.0
- gRPC：1.60.0
- libgo：源码安装
- spdlog：源码安装
- absl：随 gRPC 安装

## Core Tests

执行命令：

```bash
ctest --test-dir build-raft-full --output-on-failure
```

测试结果：

| 测试项 | 结果 |
| --- | --- |
| `test_kv_state_machine` | Passed |
| `test_wal` | Passed |
| `test_snapshot` | Passed |
| `test_raft_log` | Passed |
| `test_restart_replay` | Passed |

## 三节点功能测试

已验证：

- 三节点集群启动成功
- `Put / Get / Append / Delete` 正常
- Leader 宕机后，多数派节点继续提供服务
- 旧 Leader 重启后追赶日志并恢复一致
- Follower 掉线期间集群继续写入
- Follower 重启后追赶日志并恢复一致
- 全量集群重启后数据不丢失
- Snapshot 触发后生成 `snapshot.dat`
- Snapshot + WAL 重启恢复成功
- `check_consistency.sh` 显示 `all nodes are consistent`

## 关键验证过程

### 1. 三节点启动

执行：

```bash
bash scripts/start_cluster.sh
```

验证结果：

- `node1`
- `node2`
- `node3`

均成功启动，并完成 Leader 选举。

---

### 2. 基础 KV 操作

执行：

```bash
./bin/kv_client put name chaos
./bin/kv_client get name

./bin/kv_client append name _raft
./bin/kv_client get name

./bin/kv_client delete name
./bin/kv_client get name
```

验证结果：

- `Put` 返回 `OK`
- `Get` 返回正确 value
- `Append` 后 value 正确追加
- `Delete` 后再次读取返回 `KEY_NOT_FOUND`

---

### 3. Leader 宕机恢复

执行：

```bash
bash scripts/kill_leader.sh
sleep 5

./bin/kv_client put after_leader_kill ok
./bin/kv_client get after_leader_kill
```

验证结果：

- Leader 宕机后，剩余多数派节点重新选主
- 集群仍可继续处理写请求
- 旧 Leader 重启后可以追赶日志
- `check_consistency.sh` 验证三节点最终一致

---

### 4. Follower 掉线恢复

执行：

```bash
kill $(cat run/node3.pid)

./bin/kv_client put follower_down_key value1
./bin/kv_client get follower_down_key

bash scripts/restart_node.sh 3
sleep 5

bash scripts/check_consistency.sh
```

验证结果：

- Follower 掉线期间，集群仍可继续写入
- Follower 重启后可以追赶缺失日志
- 三节点最终数据一致

---

### 5. 全量重启恢复

执行：

```bash
./bin/kv_client put restart_key restart_value
./bin/kv_client get restart_key

bash scripts/stop_cluster.sh
sleep 3

bash scripts/start_cluster.sh
sleep 5

./bin/kv_client get restart_key
bash scripts/check_consistency.sh
```

验证结果：

- 全量集群重启后，已提交数据不丢失
- WAL + Snapshot 可以恢复 KV 状态
- 三节点最终一致

---

### 6. Snapshot 触发与恢复

临时调小 `config/node*.yaml` 中的 `max_log_entries` 后执行：

```bash
for i in $(seq 1 100); do
  ./bin/kv_client put "snap_key_$i" "snap_value_$i" >/dev/null
done

find data -type f | grep -i snapshot

./bin/kv_client get snap_key_100
bash scripts/check_consistency.sh
```

验证结果：

- 三个节点均生成 `snapshot.dat`
- Snapshot 后数据仍可读取
- 集群重启后仍可通过 Snapshot + WAL 恢复数据

## 验证结论

当前版本已完成以下核心链路验证：

1. Raft 三节点启动与 Leader 选举。
2. KV 状态机读写流程。
3. Leader 重定向与客户端自动重试。
4. `client_id + request_id` 请求去重。
5. WAL 持久化与节点重启恢复。
6. 基础 Snapshot 日志压缩与恢复。
7. Leader 宕机后的重新选主和多数派继续服务。
8. Follower 掉线后的日志追赶和最终一致性。
9. 全量集群重启后的数据恢复。
