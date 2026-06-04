#include "storage/snapshot.h"

#include <cstring>
#include <limits>
#include <system_error>
#include <utility>

#include "storage/file_util.h"

namespace craftkv::storage {
namespace {

constexpr char kSnapshotMagic[] = "CRS1";
constexpr std::size_t kMaxSnapshotPayloadBytes = 256 * 1024 * 1024;

std::string EncodeFrame(const std::string& payload) {
    std::string frame;
    frame.append(kSnapshotMagic, 4);
    AppendFixed32(&frame, static_cast<uint32_t>(payload.size()));
    AppendFixed32(&frame, Checksum32(payload));
    frame.append(payload);
    return frame;
}

bool DecodeFrame(const std::string& data, std::string* payload) {
    if (data.size() < 12 || std::memcmp(data.data(), kSnapshotMagic, 4) != 0) {
        return false;
    }
    std::size_t offset = 4;
    uint32_t size = 0;
    uint32_t checksum = 0;
    if (!ReadFixed32(data, &offset, &size) || !ReadFixed32(data, &offset, &checksum) ||
        size > kMaxSnapshotPayloadBytes || offset + size > data.size() ||
        offset + size != data.size()) {
        return false;
    }
    payload->assign(data.data() + offset, size);
    return Checksum32(*payload) == checksum;
}

}  // namespace

SnapshotManager::SnapshotManager(std::filesystem::path snapshot_path) : snapshot_path_(std::move(snapshot_path)) {}

bool SnapshotManager::Save(const SnapshotMeta& meta, const std::string& payload, std::string* error_msg) const {
    if (meta.last_included_index < 0 || meta.last_included_term < 0 ||
        payload.size() > kMaxSnapshotPayloadBytes) {
        if (error_msg != nullptr) {
            *error_msg = "invalid snapshot metadata or payload size";
        }
        return false;
    }
    return AtomicWriteStringToFile(snapshot_path_, EncodeFrame(EncodeSnapshotPayload(meta, payload)), error_msg);
}

bool SnapshotManager::Load(SnapshotData* snapshot, std::string* error_msg) const {
    *snapshot = SnapshotData{};
    std::error_code ec;
    bool snapshot_exists = std::filesystem::exists(snapshot_path_, ec);
    if (ec) {
        if (error_msg != nullptr) {
            *error_msg = "failed to inspect snapshot file: " + ec.message();
        }
        return false;
    }
    if (!snapshot_exists) {
        return true;
    }
    std::string data;
    if (!ReadFileToString(snapshot_path_, &data, error_msg)) {
        return false;
    }
    std::string encoded_payload;
    if (!DecodeFrame(data, &encoded_payload) ||
        !DecodeSnapshotPayload(encoded_payload, &snapshot->meta, &snapshot->payload)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid snapshot file: " + snapshot_path_.string();
        }
        return false;
    }
    snapshot->exists = true;
    return true;
}

bool SnapshotManager::LoadMeta(SnapshotMeta* meta, std::string* error_msg) const {
    SnapshotData snapshot;
    if (!Load(&snapshot, error_msg)) {
        *meta = SnapshotMeta{};
        return false;
    }
    *meta = snapshot.exists ? snapshot.meta : SnapshotMeta{};
    return true;
}

std::string EncodeSnapshotPayload(const SnapshotMeta& meta, const std::string& payload) {
    std::string encoded;
    AppendFixed64(&encoded, static_cast<uint64_t>(meta.last_included_index));
    AppendFixed64(&encoded, static_cast<uint64_t>(meta.last_included_term));
    AppendFixed64(&encoded, static_cast<uint64_t>(payload.size()));
    encoded.append(payload);
    return encoded;
}

bool DecodeSnapshotPayload(const std::string& encoded, SnapshotMeta* meta, std::string* payload) {
    std::size_t offset = 0;
    uint64_t index = 0;
    uint64_t term = 0;
    uint64_t payload_size = 0;
    if (!ReadFixed64(encoded, &offset, &index) || !ReadFixed64(encoded, &offset, &term) ||
        !ReadFixed64(encoded, &offset, &payload_size)) {
        return false;
    }
    if (index > static_cast<uint64_t>(std::numeric_limits<int>::max()) ||
        term > static_cast<uint64_t>(std::numeric_limits<int>::max()) ||
        payload_size > kMaxSnapshotPayloadBytes ||
        payload_size > static_cast<uint64_t>(encoded.size() - offset)) {
        return false;
    }
    meta->last_included_index = static_cast<int>(index);
    meta->last_included_term = static_cast<int>(term);
    payload->assign(encoded.data() + offset, static_cast<std::size_t>(payload_size));
    offset += static_cast<std::size_t>(payload_size);
    return offset == encoded.size();
}

}  // namespace craftkv::storage
