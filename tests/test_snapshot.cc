#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "kv/kv_command.h"
#include "kv/kv_state_machine.h"
#include "storage/file_util.h"
#include "storage/snapshot.h"
#include "storage/wal.h"

namespace {

void Require(bool condition) {
    if (!condition) {
        std::cerr << "test_snapshot assertion failed" << std::endl;
        std::abort();
    }
}

std::filesystem::path CaseDir(const std::string& name) {
    auto dir = std::filesystem::temp_directory_path() / ("craftkv_test_snapshot_" + name);
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

void WriteFile(const std::filesystem::path& path, const std::string& data) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(data.data(), static_cast<std::streamsize>(data.size()));
}

std::string MakeFrame(const std::string& payload, const char* magic = "CRS1") {
    std::string frame;
    frame.append(magic, 4);
    craftkv::storage::AppendFixed32(&frame, static_cast<uint32_t>(payload.size()));
    craftkv::storage::AppendFixed32(&frame, craftkv::storage::Checksum32(payload));
    frame.append(payload);
    return frame;
}

std::string Command(const std::string& client_id,
                    uint64_t request_id,
                    craftkv::KVOpType op_type,
                    const std::string& key,
                    const std::string& value) {
    return craftkv::SerializeClientRequest({client_id, request_id, op_type, key, value});
}

std::string GetValue(craftkv::KVStateMachine* state_machine, const std::string& key) {
    std::string value;
    Require(state_machine->GetLocal(key, &value));
    return value;
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
        Require(state_machine->Apply(request).success);
    }
}

void TestMissingSnapshotStartsEmpty() {
    auto dir = CaseDir("missing");
    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    craftkv::storage::SnapshotData data;
    std::string error;
    Require(manager.Load(&data, &error));
    Require(!data.exists);
    Require(data.meta.last_included_index == 0);
    Require(data.meta.last_included_term == 0);
    std::filesystem::remove_all(dir);
}

void TestValidSnapshotRestoresDataAndDedup() {
    auto dir = CaseDir("valid");
    craftkv::KVStateMachine sm;
    Require(sm.Apply({"client-a", 1, craftkv::KVOpType::kPut, "k1", "v1"}).success);
    Require(sm.Apply({"client-a", 2, craftkv::KVOpType::kAppend, "k1", "_v2"}).success);

    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    Require(manager.Save({2, 7}, sm.SerializeSnapshot()));

    craftkv::storage::SnapshotData data;
    Require(manager.Load(&data));
    Require(data.exists);
    Require(data.meta.last_included_index == 2);
    Require(data.meta.last_included_term == 7);

    craftkv::KVStateMachine restored;
    std::string error;
    Require(restored.LoadSnapshot(data.payload, &error));
    Require(restored.Apply({"client-a", 3, craftkv::KVOpType::kGet, "k1", ""}).value == "v1_v2");

    auto duplicate = restored.Apply({"client-a", 2, craftkv::KVOpType::kAppend, "k1", "_bad"});
    Require(duplicate.success);
    Require(GetValue(&restored, "k1") == "v1_v2");
    std::filesystem::remove_all(dir);
}

void ExpectSnapshotLoadFails(const std::string& name, const std::string& bytes) {
    auto dir = CaseDir(name);
    auto path = dir / "snapshot.dat";
    WriteFile(path, bytes);
    craftkv::storage::SnapshotManager manager(path);
    craftkv::storage::SnapshotData data;
    std::string error;
    Require(!manager.Load(&data, &error));
    Require(!error.empty());
    Require(!data.exists);
    std::filesystem::remove_all(dir);
}

void TestCorruptSnapshotFilesFailClosed() {
    ExpectSnapshotLoadFails("partial_header", "CRS1xx");

    std::string valid_payload = craftkv::storage::EncodeSnapshotPayload({2, 7}, "payload");
    ExpectSnapshotLoadFails("bad_magic", MakeFrame(valid_payload, "BAD1"));

    std::string checksum_mismatch = MakeFrame(valid_payload);
    checksum_mismatch[12] ^= 0x01;
    ExpectSnapshotLoadFails("checksum_mismatch", checksum_mismatch);

    std::string partial_payload = MakeFrame(valid_payload);
    partial_payload.resize(partial_payload.size() - 3);
    ExpectSnapshotLoadFails("partial_payload", partial_payload);

    ExpectSnapshotLoadFails("incomplete_encoded_payload", MakeFrame(std::string(8, '\0')));

    std::string trailing = MakeFrame(valid_payload + "trailing");
    ExpectSnapshotLoadFails("payload_length_mismatch", trailing);
}

void TestInvalidSnapshotMetadataRejected() {
    auto dir = CaseDir("invalid_meta");
    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    std::string error;
    Require(!manager.Save({-1, 1}, "payload", &error));
    Require(!manager.Save({1, -1}, "payload", &error));

    std::string huge_index_payload;
    craftkv::storage::AppendFixed64(&huge_index_payload, static_cast<uint64_t>(std::numeric_limits<int>::max()) + 1);
    craftkv::storage::AppendFixed64(&huge_index_payload, 1);
    craftkv::storage::AppendFixed64(&huge_index_payload, 0);
    ExpectSnapshotLoadFails("huge_snapshot_index", MakeFrame(huge_index_payload));
    std::filesystem::remove_all(dir);
}

void TestInterruptedWriteDoesNotReplaceOldSnapshot() {
    auto dir = CaseDir("interrupted_write");
    auto path = dir / "snapshot.dat";
    craftkv::storage::SnapshotManager manager(path);

    craftkv::KVStateMachine old_state;
    Require(old_state.Apply({"client-a", 1, craftkv::KVOpType::kPut, "k1", "old"}).success);
    Require(manager.Save({2, 7}, old_state.SerializeSnapshot()));

    WriteFile(path.string() + ".tmp", "CRS1partial");

    craftkv::storage::SnapshotData data;
    Require(manager.Load(&data));
    craftkv::KVStateMachine restored;
    std::string error;
    Require(restored.LoadSnapshot(data.payload, &error));
    Require(GetValue(&restored, "k1") == "old");
    Require(std::filesystem::exists(path.string() + ".tmp"));
    std::filesystem::remove_all(dir);
}

void TestSnapshotWalCombinationRecovery() {
    auto dir = CaseDir("wal_combo");
    craftkv::KVStateMachine snapshot_state;
    Require(snapshot_state.Apply({"snapshot-client", 1, craftkv::KVOpType::kPut, "k1", "base"}).success);

    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    Require(manager.Save({2, 7}, snapshot_state.SerializeSnapshot()));

    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({1, 7, Command("old-client", 1, craftkv::KVOpType::kAppend, "k1", "_old1")}));
    Require(wal.AppendLog({2, 7, Command("old-client", 2, craftkv::KVOpType::kAppend, "k1", "_old2")}));
    Require(wal.AppendLog({3, 8, Command("new-client", 1, craftkv::KVOpType::kAppend, "k1", "_new")}));
    Require(wal.SaveMeta({8, 1, 3, 0}));

    craftkv::storage::SnapshotData data;
    Require(manager.Load(&data));
    craftkv::KVStateMachine restored;
    std::string error;
    Require(restored.LoadSnapshot(data.payload, &error));
    ReplayCommitted(&wal, data.meta.last_included_index, &restored);
    Require(GetValue(&restored, "k1") == "base_new");

    auto duplicate = restored.Apply({"snapshot-client", 1, craftkv::KVOpType::kAppend, "k1", "_again"});
    Require(duplicate.success);
    Require(GetValue(&restored, "k1") == "base_new");

    for (int i = 0; i < 3; ++i) {
        craftkv::storage::SnapshotManager restart_manager(dir / "snapshot.dat");
        craftkv::storage::WAL restart_wal(dir);
        craftkv::storage::SnapshotData restart_data;
        Require(restart_manager.Load(&restart_data));
        craftkv::KVStateMachine restarted;
        Require(restarted.LoadSnapshot(restart_data.payload, &error));
        ReplayCommitted(&restart_wal, restart_data.meta.last_included_index, &restarted);
        Require(GetValue(&restarted, "k1") == "base_new");
    }

    std::filesystem::remove_all(dir);
}

struct InstallState {
    int snapshot_index = 0;
    int snapshot_term = 0;
    int commit_index = 0;
    int last_applied = 0;
    craftkv::KVStateMachine state_machine;
};

bool InstallSnapshotLocal(const craftkv::storage::SnapshotData& snapshot,
                          craftkv::storage::WAL* wal,
                          InstallState* state) {
    if (!snapshot.exists) {
        return false;
    }
    if (snapshot.meta.last_included_index <= state->snapshot_index) {
        return true;
    }
    std::string error;
    if (!wal->TruncatePrefix(snapshot.meta.last_included_index)) {
        return false;
    }
    if (!state->state_machine.LoadSnapshot(snapshot.payload, &error)) {
        return false;
    }
    state->snapshot_index = snapshot.meta.last_included_index;
    state->snapshot_term = snapshot.meta.last_included_term;
    if (state->commit_index < state->snapshot_index) {
        state->commit_index = state->snapshot_index;
    }
    if (state->last_applied < state->snapshot_index) {
        state->last_applied = state->snapshot_index;
    }
    return true;
}

craftkv::storage::SnapshotData MakeSnapshotData(int index, int term, const std::string& value) {
    craftkv::KVStateMachine sm;
    Require(sm.Apply({"client-a", static_cast<uint64_t>(index), craftkv::KVOpType::kPut, "k1", value}).success);
    return {true, {index, term}, sm.SerializeSnapshot()};
}

void TestInstallSnapshotSemantics() {
    auto dir = CaseDir("install_semantics");
    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({3, 8, "after-snapshot-3"}));
    Require(wal.AppendLog({4, 8, "after-snapshot-4"}));

    InstallState state;
    state.snapshot_index = 2;
    state.snapshot_term = 7;
    state.commit_index = 2;
    state.last_applied = 2;
    Require(state.state_machine.Apply({"client-a", 2, craftkv::KVOpType::kPut, "k1", "current"}).success);

    auto same = MakeSnapshotData(2, 7, "same");
    Require(InstallSnapshotLocal(same, &wal, &state));
    Require(state.snapshot_index == 2);
    Require(state.commit_index == 2);
    Require(state.last_applied == 2);
    Require(GetValue(&state.state_machine, "k1") == "current");

    auto older = MakeSnapshotData(1, 6, "old");
    Require(InstallSnapshotLocal(older, &wal, &state));
    Require(state.snapshot_index == 2);
    Require(GetValue(&state.state_machine, "k1") == "current");

    auto newer = MakeSnapshotData(3, 8, "new");
    Require(InstallSnapshotLocal(newer, &wal, &state));
    Require(state.snapshot_index == 3);
    Require(state.snapshot_term == 8);
    Require(state.commit_index == 3);
    Require(state.last_applied == 3);
    Require(GetValue(&state.state_machine, "k1") == "new");

    std::vector<craftkv::storage::RaftLogRecord> logs;
    Require(wal.LoadLogs(&logs));
    Require(logs.size() == 1);
    Require(logs[0].index == 4);
    std::filesystem::remove_all(dir);
}

void TestInstallSnapshotThenRestart() {
    auto dir = CaseDir("install_restart");
    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    craftkv::storage::WAL wal(dir);

    auto snapshot = MakeSnapshotData(3, 8, "snap");
    Require(manager.Save(snapshot.meta, snapshot.payload));
    Require(wal.AppendLog({4, 8, Command("client-b", 1, craftkv::KVOpType::kAppend, "k1", "_tail")}));
    Require(wal.SaveMeta({8, 1, 4, 0}));

    craftkv::storage::SnapshotData loaded;
    Require(manager.Load(&loaded));
    craftkv::KVStateMachine restored;
    std::string error;
    Require(restored.LoadSnapshot(loaded.payload, &error));
    ReplayCommitted(&wal, loaded.meta.last_included_index, &restored);
    Require(GetValue(&restored, "k1") == "snap_tail");
    std::filesystem::remove_all(dir);
}

}  // namespace

int main() {
    TestMissingSnapshotStartsEmpty();
    TestValidSnapshotRestoresDataAndDedup();
    TestCorruptSnapshotFilesFailClosed();
    TestInvalidSnapshotMetadataRejected();
    TestInterruptedWriteDoesNotReplaceOldSnapshot();
    TestSnapshotWalCombinationRecovery();
    TestInstallSnapshotSemantics();
    TestInstallSnapshotThenRestart();

    std::cout << "test_snapshot passed" << std::endl;
    return 0;
}
