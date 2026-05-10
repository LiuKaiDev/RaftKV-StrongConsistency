#include "storage/wal.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <utility>

#include "storage/file_util.h"

namespace craftkv::storage {
namespace {

constexpr char kMetaMagic[] = "CRM1";
constexpr char kLogMagic[] = "CRL1";

std::string EncodeMetaPayload(const RaftMeta& meta) {
    std::string payload;
    AppendFixed64(&payload, static_cast<uint64_t>(meta.current_term));
    AppendFixed64(&payload, static_cast<uint64_t>(static_cast<int64_t>(meta.voted_for)));
    AppendFixed64(&payload, static_cast<uint64_t>(meta.commit_index));
    AppendFixed64(&payload, static_cast<uint64_t>(meta.last_applied));
    return payload;
}

bool DecodeMetaPayload(const std::string& payload, RaftMeta* meta) {
    std::size_t offset = 0;
    uint64_t current_term = 0;
    uint64_t voted_for = 0;
    uint64_t commit_index = 0;
    uint64_t last_applied = 0;
    if (!ReadFixed64(payload, &offset, &current_term) || !ReadFixed64(payload, &offset, &voted_for) ||
        !ReadFixed64(payload, &offset, &commit_index) || !ReadFixed64(payload, &offset, &last_applied) ||
        offset != payload.size()) {
        return false;
    }
    meta->current_term = static_cast<int>(current_term);
    meta->voted_for = static_cast<int>(static_cast<int64_t>(voted_for));
    meta->commit_index = static_cast<int>(commit_index);
    meta->last_applied = static_cast<int>(last_applied);
    return true;
}

std::string EncodeFrame(const char* magic, const std::string& payload) {
    std::string frame;
    frame.append(magic, 4);
    AppendFixed32(&frame, static_cast<uint32_t>(payload.size()));
    AppendFixed32(&frame, Checksum32(payload));
    frame.append(payload);
    return frame;
}

bool DecodeOneFrame(const std::string& data, std::size_t* offset, const char* magic, std::string* payload) {
    if (*offset == data.size()) {
        return false;
    }
    if (*offset + 12 > data.size()) {
        *offset = data.size();
        return false;
    }
    if (std::memcmp(data.data() + *offset, magic, 4) != 0) {
        *offset = data.size();
        return false;
    }
    *offset += 4;
    uint32_t size = 0;
    uint32_t checksum = 0;
    if (!ReadFixed32(data, offset, &size) || !ReadFixed32(data, offset, &checksum)) {
        *offset = data.size();
        return false;
    }
    if (*offset + size > data.size()) {
        *offset = data.size();
        return false;
    }
    payload->assign(data.data() + *offset, size);
    *offset += size;
    if (Checksum32(*payload) != checksum) {
        *offset = data.size();
        return false;
    }
    return true;
}

}  // namespace

WAL::WAL(std::filesystem::path data_dir) : data_dir_(std::move(data_dir)) {}

std::filesystem::path WAL::MetaPath() const {
    return data_dir_ / "raft_meta.dat";
}

std::filesystem::path WAL::LogPath() const {
    return data_dir_ / "raft_log.wal";
}

bool WAL::LoadMeta(RaftMeta* meta, std::string* error_msg) const {
    *meta = RaftMeta{};
    std::string data;
    if (!ReadFileToString(MetaPath(), &data, error_msg)) {
        return false;
    }
    if (data.empty()) {
        return true;
    }
    std::size_t offset = 0;
    std::string payload;
    if (!DecodeOneFrame(data, &offset, kMetaMagic, &payload) || !DecodeMetaPayload(payload, meta)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid raft meta, using defaults";
        }
        *meta = RaftMeta{};
        return true;
    }
    return true;
}

bool WAL::SaveMeta(const RaftMeta& meta, std::string* error_msg) const {
    if (!EnsureDirectory(data_dir_, error_msg)) {
        return false;
    }
    return AtomicWriteStringToFile(MetaPath(), EncodeFrame(kMetaMagic, EncodeMetaPayload(meta)), error_msg);
}

bool WAL::LoadLogs(std::vector<RaftLogRecord>* logs, std::string* error_msg) const {
    logs->clear();
    std::string data;
    if (!ReadFileToString(LogPath(), &data, error_msg)) {
        return false;
    }
    std::size_t offset = 0;
    while (offset < data.size()) {
        std::string payload;
        std::size_t before = offset;
        if (!DecodeOneFrame(data, &offset, kLogMagic, &payload)) {
            if (before != data.size() && error_msg != nullptr) {
                *error_msg = "raft log contains a partial or corrupted tail; valid prefix loaded";
            }
            break;
        }
        RaftLogRecord record;
        if (!DecodeLogRecordPayload(payload, &record)) {
            if (error_msg != nullptr) {
                *error_msg = "raft log record payload is invalid; valid prefix loaded";
            }
            break;
        }
        logs->push_back(std::move(record));
    }
    std::sort(logs->begin(), logs->end(), [](const auto& left, const auto& right) {
        return left.index < right.index;
    });
    return true;
}

bool WAL::AppendLog(const RaftLogRecord& log, std::string* error_msg) const {
    if (!EnsureDirectory(data_dir_, error_msg)) {
        return false;
    }
    std::string frame = EncodeFrame(kLogMagic, EncodeLogRecordPayload(log));
    return AppendAndSync(LogPath(), frame, error_msg);
}

bool WAL::RewriteLogs(const std::vector<RaftLogRecord>& logs, std::string* error_msg) const {
    if (!EnsureDirectory(data_dir_, error_msg)) {
        return false;
    }
    std::string data;
    for (const auto& log : logs) {
        data.append(EncodeFrame(kLogMagic, EncodeLogRecordPayload(log)));
    }
    return AtomicWriteStringToFile(LogPath(), data, error_msg);
}

bool WAL::TruncatePrefix(int last_included_index, std::string* error_msg) const {
    std::vector<RaftLogRecord> logs;
    if (!LoadLogs(&logs, error_msg)) {
        return false;
    }
    logs.erase(std::remove_if(logs.begin(), logs.end(), [last_included_index](const RaftLogRecord& record) {
                   return record.index <= last_included_index;
               }),
               logs.end());
    return RewriteLogs(logs, error_msg);
}

std::string EncodeLogRecordPayload(const RaftLogRecord& log) {
    std::string payload;
    AppendFixed64(&payload, static_cast<uint64_t>(log.index));
    AppendFixed64(&payload, static_cast<uint64_t>(log.term));
    AppendFixed64(&payload, static_cast<uint64_t>(log.command.size()));
    payload.append(log.command);
    return payload;
}

bool DecodeLogRecordPayload(const std::string& payload, RaftLogRecord* log) {
    std::size_t offset = 0;
    uint64_t index = 0;
    uint64_t term = 0;
    uint64_t command_size = 0;
    if (!ReadFixed64(payload, &offset, &index) || !ReadFixed64(payload, &offset, &term) ||
        !ReadFixed64(payload, &offset, &command_size)) {
        return false;
    }
    if (offset + command_size > payload.size()) {
        return false;
    }
    log->index = static_cast<int>(index);
    log->term = static_cast<int>(term);
    log->command.assign(payload.data() + offset, static_cast<std::size_t>(command_size));
    offset += static_cast<std::size_t>(command_size);
    return offset == payload.size();
}

}  // namespace craftkv::storage
