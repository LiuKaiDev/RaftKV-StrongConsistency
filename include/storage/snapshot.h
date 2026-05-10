#pragma once

#include <filesystem>
#include <string>

namespace craftkv::storage {

struct SnapshotMeta {
    int last_included_index = 0;
    int last_included_term = 0;
};

struct SnapshotData {
    bool exists = false;
    SnapshotMeta meta;
    std::string payload;
};

class SnapshotManager {
public:
    explicit SnapshotManager(std::filesystem::path snapshot_path);

    bool Save(const SnapshotMeta& meta, const std::string& payload, std::string* error_msg = nullptr) const;
    bool Load(SnapshotData* snapshot, std::string* error_msg = nullptr) const;
    bool LoadMeta(SnapshotMeta* meta, std::string* error_msg = nullptr) const;

    const std::filesystem::path& snapshot_path() const { return snapshot_path_; }

private:
    std::filesystem::path snapshot_path_;
};

std::string EncodeSnapshotPayload(const SnapshotMeta& meta, const std::string& payload);
bool DecodeSnapshotPayload(const std::string& encoded, SnapshotMeta* meta, std::string* payload);

}  // namespace craftkv::storage
