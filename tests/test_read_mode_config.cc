#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#include "common/config.h"

namespace {

std::string WriteConfig(const std::string& name,
                        const std::string& raft_extra,
                        const std::string& read_section) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / name;
    std::ofstream out(path);
    out << "node_id: 1\n"
        << "listen_addr: 127.0.0.1:18001\n"
        << "client_addr: 127.0.0.1:19001\n"
        << "data_dir: /tmp/raftkv-read-mode-test/node1\n\n"
        << "peers:\n"
        << "  - id: 1\n"
        << "    addr: 127.0.0.1:18001\n"
        << "    client_addr: 127.0.0.1:19001\n"
        << "  - id: 2\n"
        << "    addr: 127.0.0.1:18002\n"
        << "    client_addr: 127.0.0.1:19002\n"
        << "  - id: 3\n"
        << "    addr: 127.0.0.1:18003\n"
        << "    client_addr: 127.0.0.1:19003\n\n"
        << "snapshot:\n"
        << "  max_log_entries: 10000\n"
        << "  snapshot_dir: /tmp/raftkv-read-mode-test/node1\n\n"
        << "raft:\n"
        << "  election_timeout_ms_min: 300\n"
        << "  election_timeout_ms_max: 600\n"
        << "  heartbeat_interval_ms: 100\n"
        << "  rpc_timeout_ms: 300\n";
    out << raft_extra;
    out << read_section;
    return path.string();
}

}  // namespace

int main() {
    craftkv::common::NodeConfig config;
    std::string error;

    std::string default_path = WriteConfig("raftkv_read_mode_default.yaml", "", "");
    assert(craftkv::common::LoadNodeConfig(default_path, &config, &error));
    assert(config.read.mode == "log");

    std::string read_index_path =
        WriteConfig("raftkv_read_mode_read_index.yaml", "", "\nread:\n  mode: read_index\n");
    assert(craftkv::common::LoadNodeConfig(read_index_path, &config, &error));
    assert(config.read.mode == "read_index");
    assert(!config.raft.pre_vote);
    assert(!config.raft.check_quorum);

    std::string stability_path =
        WriteConfig("raftkv_read_mode_stability.yaml",
                    "  pre_vote: true\n"
                    "  check_quorum: true\n",
                    "\nread:\n  mode: read_index\n");
    assert(craftkv::common::LoadNodeConfig(stability_path, &config, &error));
    assert(config.raft.pre_vote);
    assert(config.raft.check_quorum);

    std::string invalid_path =
        WriteConfig("raftkv_read_mode_invalid.yaml", "", "\nread:\n  mode: lease\n");
    assert(!craftkv::common::LoadNodeConfig(invalid_path, &config, &error));
    assert(error.find("invalid read.mode") != std::string::npos);

    std::string invalid_bool_path =
        WriteConfig("raftkv_read_mode_invalid_bool.yaml", "  pre_vote: maybe\n", "");
    assert(!craftkv::common::LoadNodeConfig(invalid_bool_path, &config, &error));
    assert(error.find("invalid raft.pre_vote") != std::string::npos);

    std::cout << "test_read_mode_config passed" << std::endl;
    return 0;
}
