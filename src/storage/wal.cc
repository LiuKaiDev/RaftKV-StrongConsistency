#include "storage/wal.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <system_error>
#include <utility>

#include "storage/file_util.h"

namespace craftkv::storage {
namespace {

constexpr char kMetaMagic[] = "CRM1";
constexpr char kLogMagic[] = "CRL1";

enum class DecodeFrameStatus {
    kOk,
    kEndOfFile,
    kPartialHeader,
    kBadMagic,
    kPartialPayload,
    kChecksumMismatch,
};

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

bool DecodeOneFrame(const std::string& data,
                    std::size_t* offset,
                    const char* magic,
                    std::string* payload,
                    DecodeFrameStatus* status = nullptr) {
    auto set_status = [status](DecodeFrameStatus value) {
        if (status != nullptr) {
            *status = value;
        }
    };
    if (*offset == data.size()) {
        set_status(DecodeFrameStatus::kEndOfFile);
        return false;
    }
    if (*offset + 12 > data.size()) {
        set_status(DecodeFrameStatus::kPartialHeader);
        *offset = data.size();
        return false;
    }
    if (std::memcmp(data.data() + *offset, magic, 4) != 0) {
        set_status(DecodeFrameStatus::kBadMagic);
        *offset = data.size();
        return false;
    }
    *offset += 4;
    uint32_t size = 0;
    uint32_t checksum = 0;
    if (!ReadFixed32(data, offset, &size) || !ReadFixed32(data, offset, &checksum)) {
        set_status(DecodeFrameStatus::kPartialHeader);
        *offset = data.size();
        return false;
    }
    if (*offset + size > data.size()) {
        set_status(DecodeFrameStatus::kPartialPayload);
        *offset = data.size();
        return false;
    }
    payload->assign(data.data() + *offset, size);
    *offset += size;
    if (Checksum32(*payload) != checksum) {
        set_status(DecodeFrameStatus::kChecksumMismatch);
        *offset = data.size();
        return false;
    }
    set_status(DecodeFrameStatus::kOk);
    return true;
}

bool ContainsFrameMagicAfter(const std::string& data, std::size_t offset, const char* magic) {
    for (std::size_t i = offset; i + 4 <= data.size(); ++i) {
        if (std::memcmp(data.data() + i, magic, 4) == 0) {
            return true;
        }
    }
    return false;
}

bool RepairCorruptedTail(const std::filesystem::path& log_path,
                         std::size_t valid_size,
                         std::string* error_msg) {
    std::error_code ec;
    std::filesystem::resize_file(log_path, valid_size, ec);
    if (ec) {
        if (error_msg != nullptr) {
            *error_msg = "failed to truncate corrupted raft log tail: " + ec.message();
        }
        return false;
    }
    return FsyncFile(log_path, error_msg);
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
    std::error_code ec;
    bool meta_exists = std::filesystem::exists(MetaPath(), ec);
    if (ec) {
        if (error_msg != nullptr) {
            *error_msg = "failed to inspect raft meta: " + ec.message();
        }
        return false;
    }
    if (!meta_exists) {
        return true;
    }
    std::string data;
    if (!ReadFileToString(MetaPath(), &data, error_msg)) {
        return false;
    }
    std::size_t offset = 0;
    std::string payload;
    DecodeFrameStatus status = DecodeFrameStatus::kOk;
    if (!DecodeOneFrame(data, &offset, kMetaMagic, &payload, &status) || !DecodeMetaPayload(payload, meta)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid raft meta";
        }
        *meta = RaftMeta{};
        return false;
    }
    if (offset != data.size()) {
        if (error_msg != nullptr) {
            *error_msg = "invalid raft meta: trailing bytes";
        }
        *meta = RaftMeta{};
        return false;
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
    std::size_t last_valid_offset = 0;
    while (offset < data.size()) {
        std::string payload;
        std::size_t before = offset;
        DecodeFrameStatus status = DecodeFrameStatus::kOk;
        if (!DecodeOneFrame(data, &offset, kLogMagic, &payload, &status)) {
            if (before != data.size()) {
                if (ContainsFrameMagicAfter(data, before + 1, kLogMagic)) {
                    if (error_msg != nullptr) {
                        *error_msg = "raft log corruption is not limited to the tail";
                    }
                    return false;
                }
                if (!RepairCorruptedTail(LogPath(), last_valid_offset, error_msg)) {
                    return false;
                }
                if (error_msg != nullptr) {
                    *error_msg = "raft log contains a partial or corrupted tail; valid prefix loaded and tail truncated";
                }
            }
            break;
        }
        RaftLogRecord record;
        if (!DecodeLogRecordPayload(payload, &record)) {
            if (error_msg != nullptr) {
                *error_msg = "raft log record payload is invalid";
            }
            return false;
        }
        logs->push_back(std::move(record));
        last_valid_offset = offset;
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
