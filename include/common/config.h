#pragma once

#include <string>
#include <vector>

namespace craftkv::common {

struct PeerConfig {
    int id = 0;
    std::string addr;
    std::string client_addr;
};

struct RaftConfig {
    int election_timeout_ms_min = 300;
    int election_timeout_ms_max = 600;
    int heartbeat_interval_ms = 100;
    int rpc_timeout_ms = 300;
};

struct SnapshotConfig {
    int max_log_entries = 10000;
    std::string snapshot_dir;
};

struct NodeConfig {
    int node_id = 0;
    std::string listen_addr;
    std::string client_addr;
    std::string data_dir;
    std::vector<PeerConfig> peers;
    SnapshotConfig snapshot;
    RaftConfig raft;
};

bool LoadNodeConfig(const std::string& filename, NodeConfig* config, std::string* error_msg = nullptr);
std::string DeriveClientAddr(const std::string& raft_addr);

}  // namespace craftkv::common
