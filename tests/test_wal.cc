#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

#include "storage/file_util.h"
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

void WriteFile(const std::filesystem::path& path, const std::string& value) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(value.data(), static_cast<std::streamsize>(value.size()));
}

std::string MakeFrame(const char* magic, const std::string& payload) {
    std::string frame;
    frame.append(magic, 4);
    craftkv::storage::AppendFixed32(&frame, static_cast<uint32_t>(payload.size()));
    craftkv::storage::AppendFixed32(&frame, craftkv::storage::Checksum32(payload));
    frame.append(payload);
    return frame;
}

std::string MakeMetaPayload(int current_term, int voted_for, int commit_index, int last_applied) {
    std::string payload;
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(current_term));
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(static_cast<int64_t>(voted_for)));
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(commit_index));
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(last_applied));
    return payload;
}

std::string MakeLogPayload(int index, int term, const std::string& command) {
    std::string payload;
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(index));
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(term));
    craftkv::storage::AppendFixed64(&payload, static_cast<uint64_t>(command.size()));
    payload.append(command);
    return payload;
}

std::string MakeLogFrame(int index, int term, const std::string& command) {
    return MakeFrame("CRL1", MakeLogPayload(index, term, command));
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

void TestValidSnapshotSuffixWal() {
    auto dir = CaseDir("valid_snapshot_suffix");
    craftkv::storage::WAL wal(dir);
    Require(wal.AppendLog({5, 3, "cmd-5"}));
    Require(wal.AppendLog({6, 3, "cmd-6"}));
    auto valid_size = FileSize(wal);

    std::vector<craftkv::storage::RaftLogRecord> logs;
    Require(wal.LoadLogs(&logs));
    Require(logs.size() == 2);
    Require(logs[0].index == 5);
    Require(logs[1].index == 6);
    Require(FileSize(wal) == valid_size);
    std::filesystem::remove_all(dir);
}

void ExpectLoadLogsFailsWithoutTruncation(const std::string& name, const std::string& data) {
    auto dir = CaseDir(name);
    craftkv::storage::WAL wal(dir);
    Require(craftkv::storage::EnsureDirectory(dir));
    WriteFile(wal.LogPath(), data);
    auto original_size = FileSize(wal);

    std::vector<craftkv::storage::RaftLogRecord> logs;
    std::string error;
    Require(!wal.LoadLogs(&logs, &error));
    Require(!error.empty());
    Require(FileSize(wal) == original_size);
    std::filesystem::remove_all(dir);
}

void TestMiddleChecksumMismatchFailsClosed() {
    std::string first = MakeLogFrame(1, 1, "cmd-1");
    std::string second = MakeLogFrame(2, 1, "cmd-2");
    std::string third = MakeLogFrame(3, 1, "cmd-3");
    second[12] ^= 0x01;
    ExpectLoadLogsFailsWithoutTruncation("middle_checksum_mismatch", first + second + third);
}

void TestDuplicateIndexFailsClosed() {
    ExpectLoadLogsFailsWithoutTruncation("duplicate_index",
                                         MakeLogFrame(1, 1, "cmd-1") + MakeLogFrame(1, 1, "cmd-dup"));
}

void TestOutOfOrderIndexFailsClosed() {
    ExpectLoadLogsFailsWithoutTruncation("out_of_order_index",
                                         MakeLogFrame(2, 1, "cmd-2") + MakeLogFrame(1, 1, "cmd-1"));
}

void TestIndexGapFailsClosed() {
    ExpectLoadLogsFailsWithoutTruncation("index_gap",
                                         MakeLogFrame(5, 1, "cmd-5") + MakeLogFrame(7, 1, "cmd-7"));
}

void TestInvalidIndexOrTermFailsClosed() {
    ExpectLoadLogsFailsWithoutTruncation("invalid_zero_index", MakeLogFrame(0, 1, "cmd-0"));
    ExpectLoadLogsFailsWithoutTruncation("invalid_negative_term", MakeLogFrame(1, -1, "cmd-1"));
}

void TestInvalidCommandSizeFailsClosed() {
    std::string payload;
    craftkv::storage::AppendFixed64(&payload, 1);
    craftkv::storage::AppendFixed64(&payload, 1);
    craftkv::storage::AppendFixed64(&payload, 32);
    payload.append("short");
    ExpectLoadLogsFailsWithoutTruncation("invalid_command_size", MakeFrame("CRL1", payload));
}

void TestMissingMetaUsesDefaults() {
    auto dir = CaseDir("missing_meta");
    craftkv::storage::WAL wal(dir);
    craftkv::storage::RaftMeta meta{9, 9, 9, 9};
    std::string error;
    Require(wal.LoadMeta(&meta, &error));
    Require(meta.current_term == 0);
    Require(meta.voted_for == -1);
    Require(meta.commit_index == 0);
    Require(meta.last_applied == 0);
    std::filesystem::remove_all(dir);
}

void TestValidMetaRestoresFields() {
    auto dir = CaseDir("valid_meta");
    craftkv::storage::WAL wal(dir);
    Require(wal.SaveMeta({7, 2, 5, 4}));
    craftkv::storage::RaftMeta meta;
    std::string error;
    Require(wal.LoadMeta(&meta, &error));
    Require(meta.current_term == 7);
    Require(meta.voted_for == 2);
    Require(meta.commit_index == 5);
    Require(meta.last_applied == 4);
    Require(!std::filesystem::exists(wal.MetaPath().string() + ".tmp"));
    std::filesystem::remove_all(dir);
}

void ExpectCorruptMetaFails(const std::string& name, const std::string& data) {
    auto dir = CaseDir(name);
    craftkv::storage::WAL wal(dir);
    Require(craftkv::storage::EnsureDirectory(dir));
    WriteFile(wal.MetaPath(), data);
    craftkv::storage::RaftMeta meta{9, 9, 9, 9};
    std::string error;
    Require(!wal.LoadMeta(&meta, &error));
    Require(!error.empty());
    Require(meta.current_term == 0);
    Require(meta.voted_for == -1);
    Require(meta.commit_index == 0);
    Require(meta.last_applied == 0);
    std::filesystem::remove_all(dir);
}

void TestCorruptMetaFailsClosed() {
    ExpectCorruptMetaFails("meta_partial_header", "CRM1xx");

    std::string bad_magic = MakeFrame("BAD1", MakeMetaPayload(1, 2, 3, 4));
    ExpectCorruptMetaFails("meta_bad_magic", bad_magic);

    std::string checksum_mismatch = MakeFrame("CRM1", MakeMetaPayload(1, 2, 3, 4));
    checksum_mismatch[12] ^= 0x01;
    ExpectCorruptMetaFails("meta_checksum_mismatch", checksum_mismatch);

    std::string partial_payload = MakeFrame("CRM1", MakeMetaPayload(1, 2, 3, 4));
    partial_payload.resize(partial_payload.size() - 5);
    ExpectCorruptMetaFails("meta_partial_payload", partial_payload);

    std::string incomplete_payload = MakeFrame("CRM1", std::string(8, '\0'));
    ExpectCorruptMetaFails("meta_incomplete_payload", incomplete_payload);

    std::string invalid_payload_size = MakeFrame("CRM1", MakeMetaPayload(1, 2, 3, 4) + std::string(8, '\0'));
    ExpectCorruptMetaFails("meta_invalid_payload_size", invalid_payload_size);
}

void TestAtomicWriteSuccessAndCleanup() {
    auto dir = CaseDir("atomic_write_success");
    auto file_path = dir / "atomic.dat";
    std::string error;
    Require(craftkv::storage::AtomicWriteStringToFile(file_path, "first", &error));
    std::string data;
    Require(craftkv::storage::ReadFileToString(file_path, &data, &error));
    Require(data == "first");
    Require(!std::filesystem::exists(file_path.string() + ".tmp"));

    Require(craftkv::storage::AtomicWriteStringToFile(file_path, "second", &error));
    Require(craftkv::storage::ReadFileToString(file_path, &data, &error));
    Require(data == "second");
    Require(!std::filesystem::exists(file_path.string() + ".tmp"));
    std::filesystem::remove_all(dir);
}

void TestDirectorySyncFailureReturnsFalse() {
    auto dir = CaseDir("missing_sync_dir");
    auto missing_dir = dir / "missing";
    std::string error;
    Require(!craftkv::storage::FsyncDirectory(missing_dir, &error));
    Require(!error.empty());
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
    TestValidSnapshotSuffixWal();
    TestMiddleChecksumMismatchFailsClosed();
    TestDuplicateIndexFailsClosed();
    TestOutOfOrderIndexFailsClosed();
    TestIndexGapFailsClosed();
    TestInvalidIndexOrTermFailsClosed();
    TestInvalidCommandSizeFailsClosed();
    TestMissingMetaUsesDefaults();
    TestValidMetaRestoresFields();
    TestCorruptMetaFailsClosed();
    TestAtomicWriteSuccessAndCleanup();
    TestDirectorySyncFailureReturnsFalse();

    std::cout << "test_wal passed" << std::endl;
    return 0;
}
