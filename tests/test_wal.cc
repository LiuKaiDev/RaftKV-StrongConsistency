#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

#include "storage/wal.h"

namespace {

void Require(bool condition) {
    if (!condition) {
        std::cerr << "test_wal assertion failed" << std::endl;
        std::abort();
    }
}

std::filesystem::path CaseDir(const std::string& name) {
    auto dir = std::filesystem::temp_directory_path() / ("craftkv_test_wal_" + name);
    std::filesystem::remove_all(dir);
    return dir;
}

std::uintmax_t FileSize(const craftkv::storage::WAL& wal) {
    return std::filesystem::file_size(wal.LogPath());
}

void WriteString(const std::filesystem::path& path, const std::string& value) {
    std::ofstream out(path, std::ios::binary | std::ios::app);
    out.write(value.data(), static_cast<std::streamsize>(value.size()));
}

std::vector<craftkv::storage::RaftLogRecord> LoadLogs(craftkv::storage::WAL* wal) {
    std::vector<craftkv::storage::RaftLogRecord> logs;
    bool loaded = wal->LoadLogs(&logs);
    Require(loaded);
    return logs;
}

void WriteTwoLogs(craftkv::storage::WAL* wal) {
    bool appended = wal->AppendLog({1, 3, "cmd-1"});
    Require(appended);
    appended = wal->AppendLog({2, 3, "cmd-2"});
    Require(appended);
}

void AssertTwoLogs(const std::vector<craftkv::storage::RaftLogRecord>& logs) {
    Require(logs.size() == 2);
    Require(logs[0].index == 1);
    Require(logs[0].command == "cmd-1");
    Require(logs[1].index == 2);
    Require(logs[1].command == "cmd-2");
}

void TestPartialHeaderTail() {
    auto dir = CaseDir("partial_header");
    craftkv::storage::WAL wal(dir);
    WriteTwoLogs(&wal);
    auto valid_size = FileSize(wal);

    WriteString(wal.LogPath(), "CRL1xx");
    Require(FileSize(wal) > valid_size);

    auto logs = LoadLogs(&wal);
    AssertTwoLogs(logs);
    Require(FileSize(wal) == valid_size);
    std::filesystem::remove_all(dir);
}

void TestPartialPayloadTail() {
    auto dir = CaseDir("partial_payload");
    craftkv::storage::WAL wal(dir);
    WriteTwoLogs(&wal);
    auto valid_size = FileSize(wal);

    bool appended = wal.AppendLog({3, 3, "cmd-3"});
    Require(appended);
    std::filesystem::resize_file(wal.LogPath(), valid_size + 16);
    Require(FileSize(wal) > valid_size);

    auto logs = LoadLogs(&wal);
    AssertTwoLogs(logs);
    Require(FileSize(wal) == valid_size);
    std::filesystem::remove_all(dir);
}

void TestChecksumMismatchTail() {
    auto dir = CaseDir("checksum_mismatch");
    craftkv::storage::WAL wal(dir);
    WriteTwoLogs(&wal);
    auto valid_size = FileSize(wal);

    bool appended = wal.AppendLog({3, 3, "cmd-3"});
    Require(appended);
    {
        std::fstream file(wal.LogPath(), std::ios::binary | std::ios::in | std::ios::out);
        file.seekp(static_cast<std::streamoff>(valid_size + 12));
        char byte = 0;
        file.read(&byte, 1);
        file.seekp(static_cast<std::streamoff>(valid_size + 12));
        byte ^= 0x01;
        file.write(&byte, 1);
    }

    auto logs = LoadLogs(&wal);
    AssertTwoLogs(logs);
    Require(FileSize(wal) == valid_size);
    std::filesystem::remove_all(dir);
}

void TestAppendAfterTailRepair() {
    auto dir = CaseDir("append_after_repair");
    craftkv::storage::WAL wal(dir);
    WriteTwoLogs(&wal);
    auto valid_size = FileSize(wal);

    WriteString(wal.LogPath(), "CRL1xx");
    auto logs = LoadLogs(&wal);
    AssertTwoLogs(logs);
    Require(FileSize(wal) == valid_size);

    bool appended = wal.AppendLog({3, 4, "cmd-3"});
    Require(appended);
    logs = LoadLogs(&wal);
    Require(logs.size() == 3);
    Require(logs[2].index == 3);
    Require(logs[2].term == 4);
    Require(logs[2].command == "cmd-3");
    std::filesystem::remove_all(dir);
}

void TestValidWalUnchanged() {
    auto dir = CaseDir("valid");
    craftkv::storage::WAL wal(dir);
    WriteTwoLogs(&wal);
    auto valid_size = FileSize(wal);

    auto logs = LoadLogs(&wal);
    AssertTwoLogs(logs);
    Require(FileSize(wal) == valid_size);
    std::filesystem::remove_all(dir);
}

}  // namespace

int main() {
    std::filesystem::path dir = std::filesystem::temp_directory_path() / "craftkv_test_wal";
    std::filesystem::remove_all(dir);

    craftkv::storage::WAL wal(dir);
    craftkv::storage::RaftMeta meta;
    Require(wal.LoadMeta(&meta));
    Require(meta.current_term == 0);
    Require(meta.voted_for == -1);

    Require(wal.SaveMeta({3, 2, 10, 9}));
    craftkv::storage::RaftMeta loaded;
    Require(wal.LoadMeta(&loaded));
    Require(loaded.current_term == 3);
    Require(loaded.voted_for == 2);
    Require(loaded.commit_index == 10);
    Require(loaded.last_applied == 9);

    Require(wal.AppendLog({1, 3, "cmd-1"}));
    Require(wal.AppendLog({2, 3, "cmd-2"}));

    std::vector<craftkv::storage::RaftLogRecord> logs;
    Require(wal.LoadLogs(&logs));
    Require(logs.size() == 2);
    Require(logs[0].index == 1);
    Require(logs[1].command == "cmd-2");

    {
        std::ofstream out(wal.LogPath(), std::ios::binary | std::ios::app);
        out << "broken-tail";
    }
    logs.clear();
    Require(wal.LoadLogs(&logs));
    Require(logs.size() == 2);
    Require(std::filesystem::file_size(wal.LogPath()) > 0);

    Require(wal.TruncatePrefix(1));
    logs.clear();
    Require(wal.LoadLogs(&logs));
    Require(logs.size() == 1);
    Require(logs[0].index == 2);

    std::filesystem::remove_all(dir);

    TestPartialHeaderTail();
    TestPartialPayloadTail();
    TestChecksumMismatchTail();
    TestAppendAfterTailRepair();
    TestValidWalUnchanged();

    std::cout << "test_wal passed" << std::endl;
    return 0;
}
