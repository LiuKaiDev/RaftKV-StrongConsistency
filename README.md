- # 基于 Raft 的强一致分布式 KV 存储系统

  本项目实现了一个基于 Raft 共识算法的强一致分布式 KV 存储系统，通过日志复制和多数派提交保证多副本数据一致性。系统支持 `Put`、`Get`、`Append`、`Delete` 等基础 KV 操作，并实现了 Leader 重定向、客户端请求去重、WAL 持久化、节点重启恢复、基础 Snapshot 日志压缩和多节点故障测试脚本。

  项目重点关注 Raft 在 KV 存储场景下的核心链路，包括 Leader 选举、日志复制、提交与状态机应用、崩溃恢复、快照压缩和故障恢复验证。当前版本以一致性、恢复能力和工程可运行性为主要目标，不追求工业级数据库的完整能力。

  ---

  ## 技术栈

  - **语言**：C++17
  - **通信**：gRPC / Protobuf
  - **协程库**：libgo
  - **日志库**：spdlog
  - **一致性协议**：Raft
  - **持久化**：本地文件 WAL + Snapshot
  - **构建工具**：CMake
  - **测试脚本**：Bash

  ---

  ## 核心功能

  ### KV 状态机

  系统提供基础 KV 操作：

  - `Put(key, value)`
  - `Get(key)`
  - `Append(key, value)`
  - `Delete(key)`

  客户端请求会被封装为 Raft 日志条目，在日志被多数派复制并提交后，由 Apply 流程按日志 index 顺序应用到 KV 状态机，从而保证多副本执行顺序一致。

  ### Raft 日志复制

  系统基于 Raft 实现多节点日志复制，支持：

  - Leader 选举
  - 心跳维护
  - AppendEntries 日志复制
  - 多数派提交
  - `commitIndex` 推进
  - `lastApplied` 顺序应用
  - Follower 落后后的日志追赶

  ### Leader 重定向

  客户端可能请求到 Follower 节点。此时 Follower 会返回 `NOT_LEADER` 和当前 Leader 地址，客户端根据返回信息自动重试 Leader 节点。

  ### 客户端请求去重

  客户端请求携带：

  ```text
  client_id
  request_id
  ```

  KV 状态机维护每个客户端最近一次执行结果：

  ```text
  client_id -> {max_request_id, last_result}
  ```

  当客户端超时重试时，如果请求已经执行过，状态机会直接返回缓存结果，避免重复执行写请求。该机制可以处理 `Append` 这类非幂等操作的重复提交问题。

  请求去重表会写入 Snapshot，避免节点重启或快照恢复后丢失去重状态。

  ### WAL 持久化

  每个节点会持久化 Raft 关键状态和日志：

  ```text
  currentTerm
  votedFor
  commitIndex
  raft log entries
  ```

  节点数据目录示例：

  ```text
  data/node1/
    raft_meta.dat
    raft_log.wal
    snapshot.dat
  ```

  WAL 采用追加写方式保存日志记录，节点重启后可以加载 WAL 恢复 Raft 状态和已提交日志。

  ### 节点重启恢复

  节点重启恢复流程：

  1. 加载 Snapshot，恢复 KV 数据和客户端去重表。
  2. 加载 Raft meta 和 WAL 日志。
  3. 从 Snapshot 覆盖的最后日志 index 之后开始回放已提交日志。
  4. 将已提交但尚未进入 Snapshot 的日志重新应用到 KV 状态机。
  5. 恢复节点对外服务。

  该流程避免了“日志已提交但尚未进入 Snapshot，节点重启后 KV 数据丢失”的问题。

  ### 基础 Snapshot 日志压缩

  当日志数量超过配置阈值后，节点会生成 Snapshot。Snapshot 保存内容包括：

  - KV 数据
  - 客户端请求去重表
  - `lastIncludedIndex`
  - `lastIncludedTerm`

  Snapshot 用于压缩历史日志，并降低节点重启恢复成本。

  ---

  ## 项目架构

  ```mermaid
  flowchart LR
      Client["kv_client"] --> KVServer["KVServer"]
  
      KVServer --> Raft["Raft Node"]
  
      Raft --> WAL["WAL<br/>raft_meta.dat / raft_log.wal"]
      Raft --> RPC["Raft RPC<br/>RequestVote / AppendEntries"]
      RPC --> Peers["Peer Nodes"]
  
      Raft --> Apply["Apply Loop"]
      Apply --> KVSM["KVStateMachine"]
  
      KVSM --> Snapshot["Snapshot<br/>snapshot.dat"]
  ```

  ---

  ## 目录结构

  ```text
  RaftKV-StrongConsistency/
  ├── client/                 # kv_client 客户端入口
  ├── config/                 # 三节点配置文件
  ├── docs/                   # 设计文档、构建说明、故障恢复说明
  ├── include/                # KV、Storage、Common 公共头文件
  ├── proto/                  # Proto 目录说明
  ├── scripts/                # 构建、启动、停止、故障测试脚本
  ├── src/
  │   ├── common/             # 配置与公共工具
  │   ├── craft/              # Raft 框架相关头文件与工具
  │   ├── kv/                 # KVServer、KVStateMachine、命令封装
  │   ├── protos/             # Raft RPC proto 定义
  │   ├── raft/               # Raft 核心实现
  │   ├── rpc/                # Protobuf / gRPC 生成代码
  │   └── storage/            # WAL、Snapshot、文件工具
  ├── tests/                  # 核心模块测试
  ├── server.cc               # kv_server 入口
  ├── CMakeLists.txt
  ├── common.cmake
  ├── PROJECT_STATUS.md
  └── README.md
  ```

  ---

  ## Proto 说明

  当前实际构建使用的 Raft RPC 定义位于：

  ```text
  src/protos/raft.proto
  ```

  生成代码保存在：

  ```text
  src/rpc/
    raft.pb.h
    raft.pb.cc
    raft.grpc.pb.h
    raft.grpc.pb.cc
  ```

  根目录 `proto/` 仅保留说明文件，避免和实际构建流程混淆。

  ---

  ## 构建说明

  ### 依赖

  完整构建需要以下依赖：

  - GCC / G++ 10+
  - CMake 3.16+
  - Protobuf
  - gRPC
  - libgo
  - spdlog
  - absl

  项目已在以下环境完成验证：

  ```text
  Alibaba Cloud Linux 3.2104 U11 OpenAnolis Edition
  GCC / G++ 10.2.1
  Protobuf 25.0
  gRPC 1.60.0
  ```

  详细依赖安装说明见：

  ```text
  docs/build_alinux3.md
  ```

  ### 构建核心模块

  如果本地暂未安装 gRPC、Protobuf、libgo 等完整依赖，可以只构建核心模块：

  ```bash
  BUILD_RAFT=OFF bash scripts/build.sh
  ```

  该模式会构建并运行：

  - `test_kv_state_machine`
  - `test_wal`
  - `test_snapshot`
  - `test_raft_log`
  - `test_restart_replay`

  ### 完整构建

  完整构建会生成 `kv_server` 和 `kv_client`：

  ```bash
  bash scripts/build.sh
  ```

  如果依赖安装在自定义目录，例如 `/opt/grpc`，可以使用：

  ```bash
  cmake -S . -B build-raft-full \
    -DCRAFTKV_BUILD_RAFT=ON \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_PREFIX_PATH=/opt/grpc
  
  cmake --build build-raft-full -j1
  ```

  小内存服务器建议使用 `-j1` 编译，避免编译过程中出现：

  ```text
  cc1plus: fatal error: Killed signal terminated program cc1plus
  ```

  ---

  ## 快速启动

  启动三节点集群：

  ```bash
  bash scripts/start_cluster.sh
  ```

  查看当前 Leader：

  ```bash
  ./bin/kv_client leader
  ```

  执行 KV 操作：

  ```bash
  ./bin/kv_client put name chaos
  ./bin/kv_client get name
  
  ./bin/kv_client append name _raft
  ./bin/kv_client get name
  
  ./bin/kv_client delete name
  ./bin/kv_client get name
  ```

  检查三节点数据一致性：

  ```bash
  bash scripts/check_consistency.sh
  ```

  停止集群：

  ```bash
  bash scripts/stop_cluster.sh
  ```

  ---

  ## 配置说明

  三节点配置位于：

  ```text
  config/node1.yaml
  config/node2.yaml
  config/node3.yaml
  ```

  配置示例：

  ```yaml
  node_id: 1
  listen_addr: 127.0.0.1:9001
  data_dir: ./data/node1
  
  peers:
    - id: 1
      addr: 127.0.0.1:9001
    - id: 2
      addr: 127.0.0.1:9002
    - id: 3
      addr: 127.0.0.1:9003
  
  snapshot:
    max_log_entries: 10000
  
  raft:
    election_timeout_ms_min: 300
    election_timeout_ms_max: 600
    heartbeat_interval_ms: 100
  ```

  ---

  ## 故障测试

  ### Leader 宕机恢复

  ```bash
  bash scripts/kill_leader.sh
  sleep 5
  
  ./bin/kv_client put after_leader_kill ok
  ./bin/kv_client get after_leader_kill
  ```

  重启旧 Leader：

  ```bash
  bash scripts/restart_node.sh 1
  sleep 5
  
  bash scripts/check_consistency.sh
  ```

  验证目标：

  - Leader 宕机后剩余多数派节点继续服务。
  - 旧 Leader 重启后追赶日志。
  - 三节点最终数据一致。

  ### Follower 掉线恢复

  先查看 Leader：

  ```bash
  ./bin/kv_client leader
  ```

  杀掉一个 Follower，例如 node3：

  ```bash
  kill $(cat run/node3.pid)
  ```

  继续写入数据：

  ```bash
  ./bin/kv_client put follower_down_key value1
  ./bin/kv_client get follower_down_key
  ```

  重启 Follower：

  ```bash
  bash scripts/restart_node.sh 3
  sleep 5
  
  bash scripts/check_consistency.sh
  ```

  验证目标：

  - Follower 掉线期间集群仍可继续写入。
  - Follower 重启后追赶缺失日志。
  - 三节点最终数据一致。

  ### 全量重启恢复

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

  验证目标：

  - 全量集群重启后数据不丢失。
  - WAL + Snapshot 可以恢复已提交数据。
  - 重启后三节点状态一致。

  ### Snapshot 触发与恢复

  可以临时调小 `config/node*.yaml` 中的 `max_log_entries`，例如设置为 `20`，然后写入多条数据触发 Snapshot：

  ```bash
  for i in $(seq 1 100); do
    ./bin/kv_client put "snap_key_$i" "snap_value_$i" >/dev/null
  done
  
  find data -type f | grep -i snapshot
  ./bin/kv_client get snap_key_100
  bash scripts/check_consistency.sh
  ```

  验证目标：

  - 各节点生成 `snapshot.dat`。
  - Snapshot 之后数据仍可读取。
  - 集群重启后 Snapshot + WAL 可以恢复数据。

  ---

  ## 测试结果

  项目已在 Alibaba Cloud Linux 3 环境完成完整构建和三节点功能验证。

  已验证内容包括：

  - Core tests 全部通过
  - 三节点集群启动成功
  - `Put / Get / Append / Delete` 正常
  - Leader 宕机后多数派继续服务
  - 旧 Leader 重启后追赶日志并恢复一致
  - Follower 掉线期间集群继续写入
  - Follower 重启后追赶日志并恢复一致
  - 全量集群重启后数据不丢失
  - Snapshot 触发后生成 `snapshot.dat`
  - Snapshot + WAL 重启恢复成功
  - `check_consistency.sh` 显示 `all nodes are consistent`

  完整测试记录见：

  ```text
  docs/test_result.md
  ```

  ---

  ## 当前边界

  当前版本重点验证 Raft KV 的核心链路，暂不实现以下能力：

  - 动态节点扩缩容
  - 分片 KV
  - 事务
  - MVCC
  - SQL 层
  - ReadIndex / Lease Read
  - RocksDB / LevelDB 存储引擎
  - Kubernetes 部署
  - 工业级完整 InstallSnapshot

  这些能力可以作为后续优化方向。

  ---

  ## 项目来源与许可

  本项目基于开源项目 [cq-cdy/cRaft](https://github.com/cq-cdy/cRaft) 进行二次开发，并保留原项目 LICENSE。

  原项目提供了基于 C++20、libgo、gRPC、Protobuf 的 Raft 共识框架。本项目在原有框架基础上补充了 KV 状态机、客户端请求去重、WAL 持久化、节点重启恢复、基础 Snapshot 日志压缩、Leader 重定向、多节点故障测试和服务器验证文档。

  本项目仅用于学习、实践和项目展示，不作为工业级分布式数据库使用。
