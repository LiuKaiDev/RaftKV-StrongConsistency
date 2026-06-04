#include "craft/public.h"
#include "craft/startRpcService.h"
#include "storage/file_util.h"

#include <cstdlib>
#include <filesystem>
#include <string>

namespace craft {
    namespace {
        int TestAbortAfterChunks() {
            const char* value = std::getenv("CRAFTKV_TEST_ABORT_SNAPSHOT_INSTALL_AFTER_CHUNKS");
            if (value == nullptr || *value == '\0') {
                return 0;
            }
            char* end = nullptr;
            long parsed = std::strtol(value, &end, 10);
            if (end == value || parsed <= 0) {
                return 1;
            }
            return static_cast<int>(parsed);
        }
    }  // namespace

    Status
    RpcServiceImpl::TransferSnapShotFile(::grpc::ServerContext *context,
                                         ::grpc::ServerReader<::TransferSnapShotFileArgs> *reader,
                                         ::TransferSnapShotFileReply *response) {
        response->set_isinstallsnapfile(false);
        std::filesystem::path snapshotFilePath = m_rf_->m_persister_->snapshotPath();
        std::string error;
        if (!craftkv::storage::EnsureParentDirectory(snapshotFilePath, &error)) {
            spdlog::error("create snapshot parent directory failed: {}", error);
            *m_rf_->isCompleteSnapFileInstallCh_ << RETURN_TYPE::INSTALL_SNAPSHOT_FILE_FAILED;
            return Status(grpc::StatusCode::INTERNAL, error);
        }

        TransferSnapShotFileArgs arg;

        spdlog::info("receiving snapshot file");
        std::string snapshot_data;
        int chunks = 0;
        int abort_after_chunks = TestAbortAfterChunks();
        while (reader->Read(&arg)) {
            snapshot_data.append(arg.data());
            ++chunks;
            if (abort_after_chunks > 0 && chunks >= abort_after_chunks) {
                spdlog::warn("test abort snapshot install after {} chunk(s)", chunks);
                *m_rf_->isCompleteSnapFileInstallCh_ << RETURN_TYPE::INSTALL_SNAPSHOT_FILE_FAILED;
                return Status(grpc::StatusCode::CANCELLED, "test abort snapshot install");
            }
        }
        if (!craftkv::storage::AtomicWriteStringToFile(snapshotFilePath, snapshot_data, &error)) {
            spdlog::error("atomic snapshot file install failed: {}", error);
            *m_rf_->isCompleteSnapFileInstallCh_ << RETURN_TYPE::INSTALL_SNAPSHOT_FILE_FAILED;
            return Status(grpc::StatusCode::INTERNAL, error);
        }
        response->set_isinstallsnapfile(true);
        *m_rf_->isCompleteSnapFileInstallCh_ << RETURN_TYPE::INSTALL_SNAPSHOT_META;
        spdlog::info("received snapshot file OK to [{}]", snapshotFilePath.string());
        return Status::OK;
    }
}
