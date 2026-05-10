#include "craft/persist/abstractPersist.h"

#include <algorithm>
#include <filesystem>

namespace craft {
namespace {

std::filesystem::path ResolveSnapshotPath(const std::string& dataDir, const std::string& snapshotName) {
    std::filesystem::path snapshot_path(snapshotName);
    if (snapshot_path.is_absolute() || snapshot_path.has_parent_path()) {
        return snapshot_path;
    }
    return std::filesystem::path(dataDir) / snapshot_path;
}

}  // namespace

AbstractPersist::AbstractPersist(std::string absPersistPath, std::string snapshotFileName)
    : absPersistPath_(std::move(absPersistPath)),
      snapshotFileName_(std::move(snapshotFileName)),
      wal_(absPersistPath_),
      snapshotManager_(ResolveSnapshotPath(absPersistPath_, snapshotFileName_)) {
    std::string error;
    craftkv::storage::RaftMeta meta;
    if (!wal_.LoadMeta(&meta, &error)) {
        spdlog::warn("load raft meta failed: {}", error);
    }
    currentTerm_ = meta.current_term;
    votedFor_ = meta.voted_for;
    commitIndex_ = meta.commit_index;
    lastApplied_ = meta.last_applied;

    craftkv::storage::SnapshotMeta snapshot_meta;
    error.clear();
    if (!snapshotManager_.LoadMeta(&snapshot_meta, &error) && !error.empty()) {
        spdlog::warn("load snapshot meta failed: {}", error);
    }
    lastSnapshotIndex_ = snapshot_meta.last_included_index;
    lastSnapshotTerm_ = snapshot_meta.last_included_term;
    lastlogindex_ = lastSnapshotIndex_;

    std::vector<craftkv::storage::RaftLogRecord> records;
    error.clear();
    if (!wal_.LoadLogs(&records, &error) && !error.empty()) {
        spdlog::warn("load raft log failed: {}", error);
    }
    if (!error.empty()) {
        spdlog::warn("raft log load warning: {}", error);
    }
    for (const auto& record : records) {
        if (record.index <= lastSnapshotIndex_) {
            continue;
        }
        logEntry_.emplace_back(record.term, record.command);
        lastlogindex_ = record.index;
    }
}

int AbstractPersist::getLastLogIndex() const {
    return lastlogindex_;
}

int AbstractPersist::getVotedFor() const {
    return votedFor_;
}

int AbstractPersist::getCommitIndex() const {
    return commitIndex_;
}

int AbstractPersist::getCurrentTerm() const {
    return currentTerm_;
}

int AbstractPersist::getLastApplied() const {
    return lastApplied_;
}

int AbstractPersist::getLastSnapshotTerm() const {
    return lastSnapshotTerm_;
}

int AbstractPersist::getLastSnapshotIndex() const {
    return lastSnapshotIndex_;
}

std::vector<std::pair<int, std::string>> AbstractPersist::getLogEntries() {
    return logEntry_;
}

bool AbstractPersist::saveRaftMeta(int currentTerm, int votedFor, int commitIndex, int lastApplied) {
    currentTerm_ = currentTerm;
    votedFor_ = votedFor;
    commitIndex_ = commitIndex;
    lastApplied_ = lastApplied;
    craftkv::storage::RaftMeta meta{currentTerm_, votedFor_, commitIndex_, lastApplied_};
    std::string error;
    if (!wal_.SaveMeta(meta, &error)) {
        spdlog::error("save raft meta failed: {}", error);
        return false;
    }
    return true;
}

bool AbstractPersist::appendLogEntry(int index, int term, const std::string& command) {
    std::string error;
    if (!wal_.AppendLog({index, term, command}, &error)) {
        spdlog::error("append raft WAL failed: {}", error);
        return false;
    }
    if (index > lastSnapshotIndex_) {
        if (index == lastSnapshotIndex_ + static_cast<int>(logEntry_.size()) + 1) {
            logEntry_.emplace_back(term, command);
        }
        lastlogindex_ = std::max(lastlogindex_, index);
    }
    return true;
}

bool AbstractPersist::rewriteLogEntries(int firstLogIndex,
                                        const std::vector<std::pair<int, std::string>>& entries) {
    std::vector<craftkv::storage::RaftLogRecord> records;
    records.reserve(entries.size());
    for (std::size_t i = 0; i < entries.size(); ++i) {
        records.push_back({firstLogIndex + static_cast<int>(i), entries[i].first, entries[i].second});
    }
    std::string error;
    if (!wal_.RewriteLogs(records, &error)) {
        spdlog::error("rewrite raft WAL failed: {}", error);
        return false;
    }
    logEntry_ = entries;
    lastlogindex_ = entries.empty() ? firstLogIndex - 1 : firstLogIndex + static_cast<int>(entries.size()) - 1;
    if (lastlogindex_ < lastSnapshotIndex_) {
        lastlogindex_ = lastSnapshotIndex_;
    }
    return true;
}

void AbstractPersist::setSnapshotMeta(int lastIncludedIndex, int lastIncludedTerm) {
    lastSnapshotIndex_ = lastIncludedIndex;
    lastSnapshotTerm_ = lastIncludedTerm;
}

std::string AbstractPersist::snapshotPath() const {
    return ResolveSnapshotPath(absPersistPath_, snapshotFileName_).string();
}

std::vector<std::string> AbstractPersist::readLines(const std::string& filename) {
    std::vector<std::string> lines;
    std::ifstream file(filename);
    if (file.is_open()) {
        std::string line;
        while (getline(file, line)) {
            lines.push_back(line);
        }
    }
    return lines;
}

AbstractPersist::~AbstractPersist() = default;

}  // namespace craft
