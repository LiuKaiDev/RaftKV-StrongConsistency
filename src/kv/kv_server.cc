#include "kv/kv_server.h"

#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <utility>

#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace craftkv {
namespace {

CommandResult InternalError(const std::string& message) {
    return {false, KVErrorCode::kInternalError, "", message};
}

bool ParseHostPort(const std::string& addr, std::string* host, int* port) {
    std::size_t pos = addr.rfind(':');
    if (pos == std::string::npos) {
        return false;
    }
    *host = addr.substr(0, pos);
    try {
        *port = std::stoi(addr.substr(pos + 1));
    } catch (...) {
        return false;
    }
    return *port > 0 && *port <= 65535;
}

#ifndef _WIN32
bool SendAll(int fd, const std::string& data) {
    const char* ptr = data.data();
    std::size_t left = data.size();
    while (left > 0) {
        ssize_t written = send(fd, ptr, left, 0);
        if (written <= 0) {
            return false;
        }
        ptr += written;
        left -= static_cast<std::size_t>(written);
    }
    return true;
}

bool ReadLine(int fd, std::string* line) {
    line->clear();
    char ch = 0;
    while (true) {
        ssize_t n = recv(fd, &ch, 1, 0);
        if (n <= 0) {
            return !line->empty();
        }
        if (ch == '\n') {
            return true;
        }
        if (ch != '\r') {
            line->push_back(ch);
        }
        if (line->size() > 8 * 1024 * 1024) {
            return false;
        }
    }
}
#endif

}  // namespace

KVServer::KVServer(common::NodeConfig config, std::string config_path)
    : craft::AbstractPersist(config.data_dir,
                             (std::filesystem::path(config.snapshot.snapshot_dir) / "snapshot.dat").string()),
      config_(std::move(config)),
      config_path_(std::move(config_path)) {}

KVServer::~KVServer() {
    Stop();
}

bool KVServer::Start() {
    deserialization(snapshotPath().c_str());
    apply_ch_ = new co_chan<ApplyMsg>(100000);
    raft_ = std::make_unique<craft::Raft>(this, apply_ch_, config_path_);
    raft_->launch();

    apply_thread_ = std::thread([this] { ApplyLoop(); });
    client_thread_ = std::thread([this] { ClientListenLoop(); });
    return true;
}

void KVServer::Stop() {
    stopped_ = true;
#ifndef _WIN32
    if (listen_fd_ >= 0) {
        close(listen_fd_);
        listen_fd_ = -1;
    }
#endif
    if (client_thread_.joinable()) {
        client_thread_.detach();
    }
    if (apply_thread_.joinable()) {
        apply_thread_.detach();
    }
}

void KVServer::deserialization(const char* filename) {
    (void)filename;
    craftkv::storage::SnapshotData snapshot;
    std::string error;
    if (!snapshotManager_.Load(&snapshot, &error)) {
        spdlog::warn("load KV snapshot failed: {}", error);
        return;
    }
    if (!snapshot.exists) {
        return;
    }
    if (!state_machine_.LoadSnapshot(snapshot.payload, &error)) {
        spdlog::warn("restore KV state machine failed: {}", error);
        return;
    }
    setSnapshotMeta(snapshot.meta.last_included_index, snapshot.meta.last_included_term);
    spdlog::info("restore KV snapshot index={}, term={}, keys={}",
                 snapshot.meta.last_included_index, snapshot.meta.last_included_term, state_machine_.Size());
}

void KVServer::serialization() {
    craftkv::storage::SnapshotMeta meta{getLastSnapshotIndex(), getLastSnapshotTerm()};
    std::string error;
    if (!snapshotManager_.Save(meta, state_machine_.SerializeSnapshot(), &error)) {
        spdlog::error("save KV snapshot failed: {}", error);
    }
}

KVResponse KVServer::HandleRequest(const ClientRequest& request, int timeout_ms) {
    if (raft_ == nullptr || !raft_->isLeader()) {
        return {false, KVErrorCode::kNotLeader, ExternalLeaderId(), LeaderClientAddr(), "", "not leader"};
    }

    std::string command = SerializeClientRequest(request);
    ServerCallResult submit_result = raft_->submitCommand(command);
    if (!submit_result.isLeader) {
        return {false, KVErrorCode::kNotLeader, ExternalLeaderId(), LeaderClientAddr(), "", "not leader"};
    }
    if (submit_result.index < 0) {
        return {false, KVErrorCode::kInternalError, ExternalLeaderId(), LeaderClientAddr(), "",
                "failed to append raft log"};
    }

    std::unique_lock<std::mutex> lock(pending_mutex_);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    bool applied = pending_cv_.wait_until(lock, deadline, [this, &submit_result] {
        return applied_results_.find(submit_result.index) != applied_results_.end();
    });
    if (!applied) {
        return {false, KVErrorCode::kTimeout, ExternalLeaderId(), LeaderClientAddr(), "", "request timeout"};
    }

    AppliedEntry entry = applied_results_[submit_result.index];
    applied_results_.erase(submit_result.index);
    if (entry.command != command) {
        return {false, KVErrorCode::kInternalError, ExternalLeaderId(), LeaderClientAddr(), "",
                "applied log does not match submitted command"};
    }
    return {entry.result.success, entry.result.error_code, ExternalLeaderId(), LeaderClientAddr(),
            entry.result.value, entry.result.error_msg};
}

std::string KVServer::DebugDump() const {
    return state_machine_.DumpKVText();
}

void KVServer::ApplyLoop() {
    while (!stopped_) {
        ApplyMsg msg;
        *apply_ch_ >> msg;
        if (!msg.commandValid) {
            continue;
        }

        ClientRequest request;
        std::string error;
        CommandResult result;
        if (!DeserializeClientRequest(msg.command.content, &request, &error)) {
            result = InternalError(error);
        } else {
            result = state_machine_.Apply(request);
        }

        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            applied_results_[msg.commandIndex] = AppliedEntry{msg.command.content, result};
        }
        pending_cv_.notify_all();

        if (raft_ != nullptr && config_.snapshot.max_log_entries > 0 &&
            raft_->getLogCountAfterSnapshot() >= config_.snapshot.max_log_entries) {
            raft_->saveSnapShot(msg.commandIndex);
        }
    }
}

void KVServer::ClientListenLoop() {
#ifdef _WIN32
    spdlog::error("KV TCP server is only implemented for POSIX sockets in this project");
    return;
#else
    std::string host;
    int port = 0;
    if (!ParseHostPort(config_.client_addr, &host, &port)) {
        spdlog::error("invalid client_addr: {}", config_.client_addr);
        return;
    }

    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
        spdlog::error("failed to create KV listen socket");
        return;
    }
    int on = 1;
    setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        spdlog::error("invalid KV listen host: {}", host);
        return;
    }
    if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        spdlog::error("failed to bind KV client address {}", config_.client_addr);
        return;
    }
    if (listen(listen_fd_, 128) != 0) {
        spdlog::error("failed to listen on KV client address {}", config_.client_addr);
        return;
    }
    spdlog::info("KV client API listening on {}", config_.client_addr);

    while (!stopped_) {
        int client_fd = accept(listen_fd_, nullptr, nullptr);
        if (client_fd < 0) {
            if (!stopped_) {
                spdlog::warn("accept KV client failed");
            }
            continue;
        }
        std::thread([this, client_fd] { HandleConnection(client_fd); }).detach();
    }
#endif
}

void KVServer::HandleConnection(int client_fd) {
#ifndef _WIN32
    std::string line;
    KVResponse response;
    if (!ReadLine(client_fd, &line)) {
        close(client_fd);
        return;
    }

    if (line == "LOCAL_DUMP") {
        response = {true, KVErrorCode::kOK, ExternalLeaderId(), LeaderClientAddr(), DebugDump(), ""};
    } else if (line == "LEADER") {
        response = {true, KVErrorCode::kOK, ExternalLeaderId(), LeaderClientAddr(), "", ""};
    } else {
        ClientRequest request;
        std::string error;
        if (!DeserializeClientRequest(line, &request, &error)) {
            response = {false, KVErrorCode::kBadRequest, ExternalLeaderId(), LeaderClientAddr(), "", error};
        } else {
            response = HandleRequest(request, config_.raft.rpc_timeout_ms * 20);
        }
    }

    std::string encoded = SerializeKVResponse(response);
    encoded.push_back('\n');
    SendAll(client_fd, encoded);
    close(client_fd);
#else
    (void)client_fd;
#endif
}

std::string KVServer::LeaderClientAddr() const {
    if (raft_ == nullptr) {
        return "";
    }
    int leader = raft_->getLeaderId();
    if (leader >= 0 && leader < static_cast<int>(config_.peers.size())) {
        return config_.peers[leader].client_addr;
    }
    return "";
}

int KVServer::ExternalLeaderId() const {
    if (raft_ == nullptr) {
        return -1;
    }
    return raft_->getExternalLeaderId();
}

}  // namespace craftkv
