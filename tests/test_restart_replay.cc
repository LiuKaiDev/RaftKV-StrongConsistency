#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

#include "kv/kv_command.h"
#include "kv/kv_state_machine.h"
#include "storage/wal.h"

namespace {

void Require(bool condition) {
    if (!condition) {
        std::cerr << "test_restart_replay assertion failed" << std::endl;
        std::abort();
    }
}

std::filesystem::path CaseDir(const std::string& name) {
    auto dir = std::filesystem::temp_directory_path() / ("craftkv_test_restart_replay_" + name);
    std::filesystem::remove_all(dir);
    return dir;
}

std::string Command(const std::string& client_id,
                    uint64_t request_id,
                    craftkv::KVOpType op_type,
                    const std::string& key,
                    const std::string& value) {
    return craftkv::SerializeClientRequest({client_id, request_id, op_type, key, value});
}

void ReplayCommitted(craftkv::storage::WAL* wal, int snapshot_index, craftkv::KVStateMachine* state_machine) {
    craftkv::storage::RaftMeta meta;
    std::vector<craftkv::storage::RaftLogRecord> logs;
    Require(wal->LoadMeta(&meta));
    Require(wal->LoadLogs(&logs));

    for (const auto& log : logs) {
        if (log.index <= snapshot_index || log.index > meta.commit_index) {
            continue;
        }
        craftkv::ClientRequest request;
        std::string error;
        Require(craftkv::DeserializeClientRequest(log.command, &request, &error));
        auto result = state_machine->Apply(request);
        Require(result.success);
    }
}

std::string GetValue(craftkv::KVStateMachine* state_machine, const std::string& key) {
    std::string value;
    Require(state_machine->GetLocal(key, &value));
    return value;
}

void TestCommittedButNotAppliedReplaysAfterRestart() {
    auto dir = CaseDir("committed_not_applied");
    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({1, 1, Command("client-a", 1, craftkv::KVOpType::kPut, "name", "chaos")}));
    Require(wal.SaveMeta({1, 1, 1, 0}));

    craftkv::KVStateMachine restored;
    ReplayCommitted(&wal, 0, &restored);
    Require(GetValue(&restored, "name") == "chaos");
    std::filesystem::remove_all(dir);
}

void TestApplyCompletedResponseLostDoesNotDuplicateAppend() {
    auto dir = CaseDir("response_lost_retry");
    craftkv::storage::WAL wal(dir);
    std::string append = Command("client-a", 1, craftkv::KVOpType::kAppend, "name", "_once");
    Require(wal.AppendLog({1, 1, append}));
    Require(wal.AppendLog({2, 1, append}));
    Require(wal.SaveMeta({1, 1, 2, 0}));

    craftkv::KVStateMachine restored;
    ReplayCommitted(&wal, 0, &restored);
    Require(GetValue(&restored, "name") == "_once");

    auto duplicate = restored.Apply({"client-a", 1, craftkv::KVOpType::kAppend, "name", "_again"});
    Require(duplicate.success);
    Require(duplicate.value == "_once");
    Require(GetValue(&restored, "name") == "_once");
    std::filesystem::remove_all(dir);
}

void TestSnapshotBoundaryReplaySkipsEarlierLogs() {
    auto dir = CaseDir("snapshot_boundary");
    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({1, 1, Command("client-old", 1, craftkv::KVOpType::kAppend, "name", "_old1")}));
    Require(wal.AppendLog({2, 1, Command("client-old", 2, craftkv::KVOpType::kAppend, "name", "_old2")}));
    Require(wal.AppendLog({3, 1, Command("client-new", 1, craftkv::KVOpType::kAppend, "name", "_after")}));
    Require(wal.SaveMeta({1, 1, 3, 0}));

    craftkv::KVStateMachine snapshot_state;
    auto put = snapshot_state.Apply({"snapshot-client", 1, craftkv::KVOpType::kPut, "name", "base"});
    Require(put.success);
    std::string snapshot = snapshot_state.SerializeSnapshot();

    craftkv::KVStateMachine restored;
    std::string error;
    Require(restored.LoadSnapshot(snapshot, &error));
    ReplayCommitted(&wal, 2, &restored);
    Require(GetValue(&restored, "name") == "base_after");
    std::filesystem::remove_all(dir);
}

void TestMultipleRestartsStableReplayAndDedup() {
    auto dir = CaseDir("multiple_restarts");
    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({1, 1, Command("client-a", 1, craftkv::KVOpType::kPut, "name", "base")}));
    Require(wal.AppendLog({2, 1, Command("client-a", 2, craftkv::KVOpType::kAppend, "name", "_one")}));
    Require(wal.AppendLog({3, 1, Command("client-a", 2, craftkv::KVOpType::kAppend, "name", "_duplicate")}));
    Require(wal.AppendLog({4, 1, Command("client-b", 1, craftkv::KVOpType::kAppend, "name", "_two")}));
    Require(wal.SaveMeta({1, 1, 4, 0}));

    for (int restart = 0; restart < 3; ++restart) {
        craftkv::storage::WAL recovered_wal(dir);
        craftkv::KVStateMachine restored;
        ReplayCommitted(&recovered_wal, 0, &restored);
        Require(GetValue(&restored, "name") == "base_one_two");

        auto duplicate = restored.Apply({"client-a", 2, craftkv::KVOpType::kAppend, "name", "_again"});
        Require(duplicate.success);
        Require(duplicate.value == "base_one");
        Require(GetValue(&restored, "name") == "base_one_two");
    }

    std::filesystem::remove_all(dir);
}

}  // namespace

int main() {
    TestCommittedButNotAppliedReplaysAfterRestart();
    TestApplyCompletedResponseLostDoesNotDuplicateAppend();
    TestSnapshotBoundaryReplaySkipsEarlierLogs();
    TestMultipleRestartsStableReplayAndDedup();

    std::cout << "test_restart_replay passed" << std::endl;
    return 0;
}
