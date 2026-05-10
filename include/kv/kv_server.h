#pragma once

#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "common/config.h"
#include "craft/raft.h"
#include "kv/kv_command.h"
#include "kv/kv_state_machine.h"

namespace craftkv {

class KVServer final : public craft::AbstractPersist {
public:
    KVServer(common::NodeConfig config, std::string config_path);
    ~KVServer() override;

    KVServer(const KVServer&) = delete;
    KVServer& operator=(const KVServer&) = delete;

    bool Start();
    void Stop();

    void deserialization(const char* filename) override;
    void serialization() override;

    KVResponse HandleRequest(const ClientRequest& request, int timeout_ms);
    std::string DebugDump() const;

private:
    struct AppliedEntry {
        std::string command;
        CommandResult result;
    };

    void ApplyLoop();
    void ClientListenLoop();
    void HandleConnection(int client_fd);

    std::string LeaderClientAddr() const;
    int ExternalLeaderId() const;

    common::NodeConfig config_;
    std::string config_path_;
    KVStateMachine state_machine_;
    co_chan<ApplyMsg>* apply_ch_ = nullptr;
    std::unique_ptr<craft::Raft> raft_;

    mutable std::mutex pending_mutex_;
    std::condition_variable pending_cv_;
    std::map<int, AppliedEntry> applied_results_;

    std::thread apply_thread_;
    std::thread client_thread_;
    bool stopped_ = false;
    int listen_fd_ = -1;
};

}  // namespace craftkv
