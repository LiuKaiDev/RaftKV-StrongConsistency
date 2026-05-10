#include "common/config.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <utility>

namespace craftkv::common {
namespace {

enum class Section {
    kRoot,
    kPeers,
    kSnapshot,
    kRaft,
};

std::string Trim(const std::string& value) {
    std::size_t first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first]))) {
        ++first;
    }
    std::size_t last = value.size();
    while (last > first && std::isspace(static_cast<unsigned char>(value[last - 1]))) {
        --last;
    }
    return value.substr(first, last - first);
}

std::string StripComment(const std::string& value) {
    bool in_quote = false;
    char quote = '\0';
    for (std::size_t i = 0; i < value.size(); ++i) {
        if ((value[i] == '\'' || value[i] == '"') && (i == 0 || value[i - 1] != '\\')) {
            if (!in_quote) {
                in_quote = true;
                quote = value[i];
            } else if (quote == value[i]) {
                in_quote = false;
            }
        }
        if (!in_quote && value[i] == '#') {
            return value.substr(0, i);
        }
    }
    return value;
}

bool SplitKeyValue(const std::string& line, std::string* key, std::string* value) {
    std::size_t pos = line.find(':');
    if (pos == std::string::npos) {
        return false;
    }
    *key = Trim(line.substr(0, pos));
    *value = Trim(line.substr(pos + 1));
    if (value->size() >= 2 &&
        (((*value)[0] == '"' && value->back() == '"') || ((*value)[0] == '\'' && value->back() == '\''))) {
        *value = value->substr(1, value->size() - 2);
    }
    return !key->empty();
}

bool ParseInt(const std::string& value, int* out) {
    if (value.empty()) {
        return false;
    }
    std::istringstream input(value);
    input >> *out;
    return !input.fail();
}

std::string ResolveProjectPath(const std::string& filename, const std::string& value) {
    std::filesystem::path path(value);
    if (path.empty() || path.is_absolute()) {
        return path.string();
    }

    std::filesystem::path config_path(filename);
    std::filesystem::path base = std::filesystem::current_path();
    if (config_path.has_parent_path()) {
        std::filesystem::path parent = config_path.parent_path();
        if (parent.filename() == "config") {
            base = parent.has_parent_path() ? parent.parent_path() : std::filesystem::current_path();
        } else {
            base = parent;
        }
    }
    return (base / path).lexically_normal().string();
}

void ApplyPeerField(PeerConfig* peer, const std::string& key, const std::string& value) {
    if (key == "id") {
        ParseInt(value, &peer->id);
    } else if (key == "addr") {
        peer->addr = value;
    } else if (key == "client_addr") {
        peer->client_addr = value;
    }
}

}  // namespace

std::string DeriveClientAddr(const std::string& raft_addr) {
    std::size_t pos = raft_addr.rfind(':');
    if (pos == std::string::npos) {
        return raft_addr;
    }
    int port = 0;
    if (!ParseInt(raft_addr.substr(pos + 1), &port)) {
        return raft_addr;
    }
    return raft_addr.substr(0, pos + 1) + std::to_string(port + 1000);
}

bool LoadNodeConfig(const std::string& filename, NodeConfig* config, std::string* error_msg) {
    std::ifstream input(filename);
    if (!input) {
        if (error_msg != nullptr) {
            *error_msg = "failed to open config: " + filename;
        }
        return false;
    }

    NodeConfig parsed;
    Section section = Section::kRoot;
    PeerConfig* current_peer = nullptr;

    std::string raw_line;
    while (std::getline(input, raw_line)) {
        std::string line = Trim(StripComment(raw_line));
        if (line.empty()) {
            continue;
        }

        if (line == "peers:") {
            section = Section::kPeers;
            current_peer = nullptr;
            continue;
        }
        if (line == "snapshot:") {
            section = Section::kSnapshot;
            current_peer = nullptr;
            continue;
        }
        if (line == "raft:") {
            section = Section::kRaft;
            current_peer = nullptr;
            continue;
        }

        if (section == Section::kPeers && line.rfind("- ", 0) == 0) {
            parsed.peers.emplace_back();
            current_peer = &parsed.peers.back();
            line = Trim(line.substr(2));
            if (line.empty()) {
                continue;
            }
        }

        std::string key;
        std::string value;
        if (!SplitKeyValue(line, &key, &value)) {
            continue;
        }

        switch (section) {
            case Section::kRoot:
                if (key == "node_id" || key == "id") {
                    ParseInt(value, &parsed.node_id);
                } else if (key == "listen_addr") {
                    parsed.listen_addr = value;
                } else if (key == "client_addr") {
                    parsed.client_addr = value;
                } else if (key == "data_dir") {
                    parsed.data_dir = value;
                }
                break;
            case Section::kPeers:
                if (current_peer != nullptr) {
                    ApplyPeerField(current_peer, key, value);
                }
                break;
            case Section::kSnapshot:
                if (key == "max_log_entries") {
                    ParseInt(value, &parsed.snapshot.max_log_entries);
                } else if (key == "snapshot_dir") {
                    parsed.snapshot.snapshot_dir = value;
                }
                break;
            case Section::kRaft:
                if (key == "election_timeout_ms_min") {
                    ParseInt(value, &parsed.raft.election_timeout_ms_min);
                } else if (key == "election_timeout_ms_max") {
                    ParseInt(value, &parsed.raft.election_timeout_ms_max);
                } else if (key == "heartbeat_interval_ms") {
                    ParseInt(value, &parsed.raft.heartbeat_interval_ms);
                } else if (key == "rpc_timeout_ms") {
                    ParseInt(value, &parsed.raft.rpc_timeout_ms);
                }
                break;
        }
    }

    if (parsed.client_addr.empty() && !parsed.listen_addr.empty()) {
        parsed.client_addr = DeriveClientAddr(parsed.listen_addr);
    }
    for (auto& peer : parsed.peers) {
        if (peer.client_addr.empty() && !peer.addr.empty()) {
            peer.client_addr = DeriveClientAddr(peer.addr);
        }
    }
    if (parsed.snapshot.snapshot_dir.empty() && !parsed.data_dir.empty()) {
        parsed.snapshot.snapshot_dir = parsed.data_dir;
    }

    parsed.data_dir = ResolveProjectPath(filename, parsed.data_dir);
    parsed.snapshot.snapshot_dir = ResolveProjectPath(filename, parsed.snapshot.snapshot_dir);

    if (parsed.node_id <= 0 || parsed.listen_addr.empty() || parsed.data_dir.empty() || parsed.peers.empty()) {
        if (error_msg != nullptr) {
            *error_msg = "config missing node_id/listen_addr/data_dir/peers";
        }
        return false;
    }

    auto self = std::find_if(parsed.peers.begin(), parsed.peers.end(), [&parsed](const PeerConfig& peer) {
        return peer.id == parsed.node_id;
    });
    if (self == parsed.peers.end()) {
        if (error_msg != nullptr) {
            *error_msg = "node_id is not present in peers";
        }
        return false;
    }

    *config = std::move(parsed);
    return true;
}

}  // namespace craftkv::common
