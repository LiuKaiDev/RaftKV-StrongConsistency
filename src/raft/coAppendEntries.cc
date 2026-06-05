#include "libgo/coroutine.h"
#include "craft/public.h"
#include "craft/raft.h"
#include "raft/raft_correctness.h"

#include <chrono>
#include <cstdint>

namespace craft {

    bool sendToAppendEntries(Raft *rf, int serverId,
                             const std::shared_ptr<AppendEntriesArgs> &args,
                             const std::shared_ptr<AppendEntriesReply> &reply);

    void handleAppendSuccess(Raft *rf, int serverId, const std::shared_ptr<AppendEntriesArgs> &args,
                             const std::shared_ptr<AppendEntriesReply> &reply);

    void handleAppendFaild(Raft *rf, int serverId, const std::shared_ptr<AppendEntriesArgs> &args,
                           const std::shared_ptr<AppendEntriesReply> &reply);

    void sendInstallSnapshotToPeer(Raft *rf, int serverId);

    bool toTransferSnapShotFiles(Raft *rf, int serverId);

    void Raft::co_appendAentries() {
        go [this] {
            for (; !m_iskilled_;) {
                RETURN_TYPE X;
                m_appendEntriesTimer->m_chan_ >> X;
                m_appendEntriesTimer->reset(m_heatBeatInterVal);
                co_mtx_.lock();
                if (m_state_ == STATE::LEADER && m_checkQuorumEnabled_) {
                    m_metrics_.IncrementCheckQuorumRounds();
                    if (recentlyContactedQuorum(std::chrono::steady_clock::now())) {
                        m_metrics_.IncrementCheckQuorumSuccess();
                    } else {
                        m_metrics_.IncrementCheckQuorumFailed();
                        m_metrics_.IncrementCheckQuorumStepdown();
                        spdlog::warn("[{}]:{} step down because CheckQuorum lost majority",
                                     m_me_, m_clusterAddress_[m_me_]);
                        changeToState(STATE::FOLLOWER);
                        m_leaderId_ = -1;
                        m_electionTimer->reset(getElectionTimeOut(m_leaderEelectionTimeOut_));
                        persist();
                    }
                }
                co_mtx_.unlock();
                if (m_state_ == STATE::LEADER) {
                    spdlog::debug("in co_appendAentries state:[{}],my term is [{}]",
                                  stringState(m_state_), m_current_term_);
                    for (int i = 0; i < this->m_peers_->numPeers(); i++) {
                        if (i == this->m_me_) {
                            continue;
                        }
                        go [this, i] {
                            co_mtx_.lock();
                            if (m_state_ != STATE::LEADER) {
                                co_mtx_.unlock();
                                return;
                            }
                            if (raft_correctness::NeedsInstallSnapshot(m_nextIndex_[i], m_snapShotIndex)) {
                                sendInstallSnapshotToPeer(this, i);
                                co_mtx_.unlock();
                                return;
                            }
                            std::shared_ptr<AppendEntriesArgs> args(
                                    new AppendEntriesArgs);
                            args->set_term(m_current_term_);
                            args->set_leaderid(m_me_);
                            args->set_leadercommit(m_commitIndex_);
                            auto argsPack = getAppendLogs(i);
                            args->set_prevlogindex(std::get<0>(argsPack));
                            args->set_prevlogterm(std::get<1>(argsPack));
                            for (const auto& m: std::get<2>(argsPack)) {
                                auto a = args->add_entries();
                                a->set_term(m.term());
                                a->set_command(m.command());
                                a->set_type(m.type());
                            }
                            std::shared_ptr<AppendEntriesReply> reply(
                                    new AppendEntriesReply);
                            bool isCallOk = sendToAppendEntries(this, i, args, reply);
                            if (!isCallOk) {
                                co_mtx_.unlock();
                                return;
                            }
                            if (reply->term() > m_current_term_) {
                                m_current_term_ = reply->term();
                                changeToState(STATE::FOLLOWER);
                                m_electionTimer->reset(getElectionTimeOut(m_leaderEelectionTimeOut_));
                                co_mtx_.unlock();
                                persist();
                                return;
                            }
                            if (m_state_ == STATE::LEADER) {
                                if (reply->success()) {
                                    spdlog::debug("reply->success");
                                    handleAppendSuccess(this, i, args, reply);
                                } else {
                                    spdlog::debug("reply->faild");
                                    handleAppendFaild(this, i, args, reply);
                                }
                            }
                            co_mtx_.unlock();
                        };
                    }
                } else {
                    RETURN_TYPE a;
                    *m_StateChangedCh_ >> a;
                    spdlog::debug(
                            "recvive state changed state:[{}],my term is [{}]",
                            stringState(m_state_), m_current_term_);
                }
            }
        };
    }

    bool sendToAppendEntries(Raft *rf, int serverId,
                             const std::shared_ptr<AppendEntriesArgs> &args,
                             const std::shared_ptr<AppendEntriesReply> &reply) {
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_,
                                                 static_cast<int>(rf->m_clusterAddress_.size()))) {
            spdlog::error("serverId:{} invalid in sendToAppendEntries!", serverId);
            return false;
        }
        static std::vector<std::unique_ptr<RaftRPC::Stub>> &stubs =
                rf->m_peers_->getPeerStubs();
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_, static_cast<int>(stubs.size()))) {
            spdlog::error("serverId:{} invalid in sendToAppendEntries!", serverId);
            return false;
        }
        bool isCallok = false;
        ClientContext context;
        std::chrono::system_clock::time_point deadline =
                std::chrono::system_clock::now() +
                std::chrono::milliseconds(rf->m_rpcTimeOut_);
        context.set_deadline(deadline);
        Status ok = stubs[serverId]->appendEntries(&context, *args, reply.get());
        rf->m_metrics_.IncrementAppendEntriesSent();
        rf->m_metrics_.IncrementAppendEntriesBatchRpc();
        rf->m_metrics_.AddAppendEntriesEntriesSent(static_cast<std::uint64_t>(args->entries_size()));
        rf->m_metrics_.ObserveAppendEntriesBatchSize(static_cast<std::uint64_t>(args->entries_size()));
        if (args->entries_size() == 0) {
            rf->m_metrics_.IncrementAppendEntriesEmptyHeartbeat();
        } else {
            rf->m_metrics_.IncrementFollowerCatchupAttempts();
        }
        if (ok.ok()) {
            if (reply->success()) {
                rf->m_metrics_.IncrementAppendEntriesSuccess();
                rf->recordPeerContact(serverId, std::chrono::steady_clock::now());
            } else {
                rf->m_metrics_.IncrementAppendEntriesFailed();
            }
            isCallok = true;
        } else {
            spdlog::error("disconnect to FOLLOWER [{}]:{}", serverId, rf->m_clusterAddress_[serverId]);
            rf->m_metrics_.IncrementAppendEntriesFailed();
        }
        return isCallok;
    }

    void handleAppendSuccess(Raft *rf, int serverId, const std::shared_ptr<AppendEntriesArgs> &args,
                             const std::shared_ptr<AppendEntriesReply> &reply) {
        (void)reply;
        if (args->entries_size() > 0) {
            bool advanced = raft_correctness::AdvanceReplicationOnAppendSuccess(
                serverId, args->prevlogindex(), args->entries_size(), &rf->m_nextIndex_, &rf->m_matchIndex_);
            if (advanced) {
                rf->m_metrics_.IncrementFollowerCatchupSuccess();
            } else {
                rf->m_metrics_.IncrementAppendEntriesStaleResponseIgnored();
            }
        }
        if (args->entries_size() > 0 && args->entries(args->entries_size() - 1).term() == rf->m_current_term_) {
            rf->tryCommitLog();
        }
        rf->persist();
    }

    void handleAppendFaild(Raft *rf, int serverId, const std::shared_ptr<AppendEntriesArgs> &args,
                           const std::shared_ptr<AppendEntriesReply> &reply) {
        (void)args;
        if (reply->nextlogindex() != 0) {
            if (reply->nextlogindex() > rf->m_snapShotIndex) {
                if (raft_correctness::BackoffReplicationOnAppendFailure(
                        serverId, reply->nextlogindex(), rf->m_snapShotIndex,
                        &rf->m_nextIndex_, rf->m_matchIndex_)) {
                    rf->m_appendEntriesTimer->reset(0); //right now send appendEntries again
                } else {
                    rf->m_metrics_.IncrementAppendEntriesStaleResponseIgnored();
                }
            } else {
                sendInstallSnapshotToPeer(rf,serverId);
            }
        }
    }

    void sendInstallSnapshotToPeer(Raft *rf, int serverId) {
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_,
                                                 static_cast<int>(rf->m_clusterAddress_.size()))) {
            spdlog::error("serverId:{} invalid in sendInstallSnapshotToPeer!", serverId);
            return;
        }

        InstallSnapshotArgs args;
        args.set_term(rf->m_current_term_);
        args.set_leaderid(rf->m_me_);
        args.set_lastincludeindex(rf->m_snapShotIndex);
        args.set_lastincludeterm(rf->m_snapShotTerm);
        InstallSnapshotReply reply;
        spdlog::info("send install snapshot to id[{}]:{}", serverId, rf->m_clusterAddress_[serverId]);

        static std::vector<std::unique_ptr<RaftRPC::Stub>> &stubs =
                rf->m_peers_->getPeerStubs();
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_, static_cast<int>(stubs.size()))) {
            spdlog::error("serverId:{} invalid in sendInstallSnapshotToPeer!", serverId);
            return;
        }

        ClientContext context;
        std::chrono::system_clock::time_point deadline =
                std::chrono::system_clock::now() +
                std::chrono::milliseconds(rf->m_rpcTimeOut_);
        context.set_deadline(deadline);
        Status ok = stubs[serverId]->installSnapshot(&context, args, &reply);
        rf->m_metrics_.IncrementInstallSnapshotSent();
        if (ok.ok() && reply.iscansendsnapfile()) {
            rf->m_metrics_.IncrementInstallSnapshotSuccess();
            int snapshotIndex = args.lastincludeindex();
            int requestTerm = args.term();
            go[rf,serverId,snapshotIndex,requestTerm]{
                // Send snapshot files via grpc streaming protocol
                if(!toTransferSnapShotFiles(rf, serverId)){
                    spdlog::error("TransferSnapShotFiles faild");
                }else{
                    rf->co_mtx_.lock();
                    if (rf->m_state_ == STATE::LEADER && rf->m_current_term_ == requestTerm) {
                        raft_correctness::AdvanceReplicationOnSnapshotInstall(
                            serverId, snapshotIndex, &rf->m_nextIndex_, &rf->m_matchIndex_);
                        rf->m_appendEntriesTimer->reset(0);
                    }
                    rf->co_mtx_.unlock();
                    spdlog::info("success transfer snapshot file to id[{}]:{}", serverId, rf->m_clusterAddress_[serverId]);
                }
            };
        } else {
            rf->m_metrics_.IncrementInstallSnapshotFailed();
            spdlog::error("Install snapshot metadata RPC timed out");
        }
    }

    bool toTransferSnapShotFiles(Raft *rf, int serverId) {
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_,
                                                 static_cast<int>(rf->m_clusterAddress_.size()))) {
            spdlog::error("serverId:{} invalid in toTransferSnapShotFiles!", serverId);
            return false;
        }
        static std::vector<std::unique_ptr<RaftRPC::Stub>> &stubs =
                rf->m_peers_->getPeerStubs();
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_, static_cast<int>(stubs.size()))) {
            spdlog::error("serverId:{} invalid in toTransferSnapShotFiles!", serverId);
            return false;
        }
        spdlog::info("id[{}]:{} transfer snapshot file to id[{}]:{}", rf->m_me_,rf->m_clusterAddress_[rf->m_me_], serverId,
                     rf->m_clusterAddress_[serverId]);
        std::filesystem::path snapshotFilePath = rf->m_persister_->snapshotPath();
        check(snapshotFilePath);
        TransferSnapShotFileArgs args;
        TransferSnapShotFileReply reply;
        const int CHUNK_SIZE = 1024;
        char data[CHUNK_SIZE];
        ClientContext context;
        std::ifstream infile(snapshotFilePath, std::ios::in);
        if (!infile.is_open()) {
            spdlog::error("open snapshotFile file:{} faild", snapshotFilePath.string());
            return false;
        }
        std::chrono::system_clock::time_point deadline =
                std::chrono::system_clock::now() +
                std::chrono::milliseconds(5000);
        context.set_deadline(deadline);
        std::unique_ptr<::grpc::ClientWriter<::TransferSnapShotFileArgs>>
                writer = stubs[serverId]->TransferSnapShotFile(&context, &reply);
        while (!infile.eof()) {
            infile.read(data, CHUNK_SIZE);
            args.set_data(data, infile.gcount());
            spdlog::info("send data :{}", data);
            if (!writer->Write(args)) {
                return false;
            }
        }
        writer->WritesDone();
        Status status = writer->Finish();
        return status.ok();

    }
};  // namespace craft
