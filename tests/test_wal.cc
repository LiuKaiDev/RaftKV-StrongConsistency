#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

#include "storage/wal.h"

int main() {
    std::filesystem::path dir = std::filesystem::temp_directory_path() / "craftkv_test_wal";
    std::filesystem::remove_all(dir);

    craftkv::storage::WAL wal(dir);
    craftkv::storage::RaftMeta meta;
    assert(wal.LoadMeta(&meta));
    assert(meta.current_term == 0);
    assert(meta.voted_for == -1);

    assert(wal.SaveMeta({3, 2, 10, 9}));
    craftkv::storage::RaftMeta loaded;
    assert(wal.LoadMeta(&loaded));
    assert(loaded.current_term == 3);
    assert(loaded.voted_for == 2);
    assert(loaded.commit_index == 10);
    assert(loaded.last_applied == 9);

    assert(wal.AppendLog({1, 3, "cmd-1"}));
    assert(wal.AppendLog({2, 3, "cmd-2"}));

    std::vector<craftkv::storage::RaftLogRecord> logs;
    assert(wal.LoadLogs(&logs));
    assert(logs.size() == 2);
    assert(logs[0].index == 1);
    assert(logs[1].command == "cmd-2");

    {
        std::ofstream out(wal.LogPath(), std::ios::binary | std::ios::app);
        out << "broken-tail";
    }
    logs.clear();
    assert(wal.LoadLogs(&logs));
    assert(logs.size() == 2);

    assert(wal.TruncatePrefix(1));
    logs.clear();
    assert(wal.LoadLogs(&logs));
    assert(logs.size() == 1);
    assert(logs[0].index == 2);

    std::filesystem::remove_all(dir);
    std::cout << "test_wal passed" << std::endl;
    return 0;
}
