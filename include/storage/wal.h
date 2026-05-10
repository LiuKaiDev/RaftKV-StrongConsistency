#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace craftkv::storage {

struct RaftMeta {
    int current_term = 0;
    int voted_for = -1;
    int commit_index = 0;
    int last_applied = 0;
};

struct RaftLogRecord {
    int index = 0;
    int term = 0;
    std::string command;
};

class WAL {
public:
    explicit WAL(std::filesystem::path data_dir);

    bool LoadMeta(RaftMeta* meta, std::string* error_msg = nullptr) const;
    bool SaveMeta(const RaftMeta& meta, std::string* error_msg = nullptr) const;

    bool LoadLogs(std::vector<RaftLogRecord>* logs, std::string* error_msg = nullptr) const;
    bool AppendLog(const RaftLogRecord& log, std::string* error_msg = nullptr) const;
    bool RewriteLogs(const std::vector<RaftLogRecord>& logs, std::string* error_msg = nullptr) const;
    bool TruncatePrefix(int last_included_index, std::string* error_msg = nullptr) const;

    const std::filesystem::path& data_dir() const { return data_dir_; }
    std::filesystem::path MetaPath() const;
    std::filesystem::path LogPath() const;

private:
    std::filesystem::path data_dir_;
};

std::string EncodeLogRecordPayload(const RaftLogRecord& log);
bool DecodeLogRecordPayload(const std::string& payload, RaftLogRecord* log);

}  // namespace craftkv::storage
