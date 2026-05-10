#include <cassert>
#include <filesystem>
#include <iostream>

#include "kv/kv_state_machine.h"
#include "storage/snapshot.h"
#include "storage/wal.h"

int main() {
    std::filesystem::path dir = std::filesystem::temp_directory_path() / "craftkv_test_snapshot";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);

    craftkv::KVStateMachine sm;
    sm.Apply({"client-a", 1, craftkv::KVOpType::kPut, "k1", "v1"});
    sm.Apply({"client-a", 2, craftkv::KVOpType::kAppend, "k1", "_v2"});

    craftkv::storage::SnapshotManager manager(dir / "snapshot.dat");
    assert(manager.Save({2, 7}, sm.SerializeSnapshot()));

    craftkv::storage::SnapshotData data;
    assert(manager.Load(&data));
    assert(data.exists);
    assert(data.meta.last_included_index == 2);
    assert(data.meta.last_included_term == 7);

    craftkv::KVStateMachine restored;
    std::string error;
    assert(restored.LoadSnapshot(data.payload, &error));
    auto get = restored.Apply({"client-a", 3, craftkv::KVOpType::kGet, "k1", ""});
    assert(get.success);
    assert(get.value == "v1_v2");

    auto duplicate = restored.Apply({"client-a", 2, craftkv::KVOpType::kAppend, "k1", "_bad"});
    assert(duplicate.success);
    auto final_get = restored.Apply({"client-a", 4, craftkv::KVOpType::kGet, "k1", ""});
    assert(final_get.value == "v1_v2");

    craftkv::storage::WAL wal(dir);
    assert(wal.AppendLog({1, 7, "old"}));
    assert(wal.AppendLog({2, 7, "snap"}));
    assert(wal.AppendLog({3, 8, "new"}));
    assert(wal.TruncatePrefix(2));
    std::vector<craftkv::storage::RaftLogRecord> logs;
    assert(wal.LoadLogs(&logs));
    assert(logs.size() == 1);
    assert(logs[0].index == 3);

    std::filesystem::remove_all(dir);
    std::cout << "test_snapshot passed" << std::endl;
    return 0;
}
