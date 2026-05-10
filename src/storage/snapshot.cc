#include "storage/snapshot.h"

#include <cstring>
#include <utility>

#include "storage/file_util.h"

namespace craftkv::storage {
namespace {

constexpr char kSnapshotMagic[] = "CRS1";

std::string EncodeFrame(const std::string& payload) {
    std::string frame;
    frame.append(kSnapshotMagic, 4);
    AppendFixed32(&frame, static_cast<uint32_t>(payload.size()));
    AppendFixed32(&frame, Checksum32(payload));
    frame.append(payload);
    return frame;
}

bool DecodeFrame(const std::string& data, std::string* payload) {
    if (data.empty()) {
        return false;
    }
    if (data.size() < 12 || std::memcmp(data.data(), kSnapshotMagic, 4) != 0) {
        return false;
    }
    std::size_t offset = 4;
    uint32_t size = 0;
    uint32_t checksum = 0;
    if (!ReadFixed32(data, &offset, &size) || !ReadFixed32(data, &offset, &checksum) ||
        offset + size > data.size()) {
        return false;
    }
    payload->assign(data.data() + offset, size);
    return Checksum32(*payload) == checksum;
}

}  // namespace

SnapshotManager::SnapshotManager(std::filesystem::path snapshot_path) : snapshot_path_(std::move(snapshot_path)) {}

bool SnapshotManager::Save(const SnapshotMeta& meta, const std::string& payload, std::string* error_msg) const {
    return AtomicWriteStringToFile(snapshot_path_, EncodeFrame(EncodeSnapshotPayload(meta, payload)), error_msg);
}

bool SnapshotManager::Load(SnapshotData* snapshot, std::string* error_msg) const {
    *snapshot = SnapshotData{};
    std::string data;
    if (!ReadFileToString(snapshot_path_, &data, error_msg)) {
        return false;
    }
    if (data.empty()) {
        return true;
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
    if (offset + payload_size > encoded.size()) {
        return false;
    }
    meta->last_included_index = static_cast<int>(index);
    meta->last_included_term = static_cast<int>(term);
    payload->assign(encoded.data() + offset, static_cast<std::size_t>(payload_size));
    offset += static_cast<std::size_t>(payload_size);
    return offset == encoded.size();
}

}  // namespace craftkv::storage
