#include <cassert>
#include <filesystem>
#include <iostream>
#include <vector>

#include "kv/kv_command.h"
#include "kv/kv_state_machine.h"
#include "storage/wal.h"

int main() {
    std::filesystem::path dir = std::filesystem::temp_directory_path() / "craftkv_test_restart_replay";
    std::filesystem::remove_all(dir);

    craftkv::storage::WAL wal(dir);
    craftkv::ClientRequest put{"client-a", 1, craftkv::KVOpType::kPut, "name", "chaos"};
    assert(wal.AppendLog({1, 1, craftkv::SerializeClientRequest(put)}));
    assert(wal.SaveMeta({1, 1, 1, 1}));

    craftkv::storage::RaftMeta meta;
    std::vector<craftkv::storage::RaftLogRecord> logs;
    assert(wal.LoadMeta(&meta));
    assert(wal.LoadLogs(&logs));

    const int snapshot_index = 0;
    craftkv::KVStateMachine restored;
    for (const auto& log : logs) {
        if (log.index <= snapshot_index || log.index > meta.commit_index) {
            continue;
        }
        craftkv::ClientRequest request;
        std::string error;
        assert(craftkv::DeserializeClientRequest(log.command, &request, &error));
        auto result = restored.Apply(request);
        assert(result.success);
    }

    std::string value;
    assert(restored.GetLocal("name", &value));
    assert(value == "chaos");

    std::filesystem::remove_all(dir);
    std::cout << "test_restart_replay passed" << std::endl;
    return 0;
}
