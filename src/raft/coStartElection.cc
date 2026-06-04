#include <libgo/context/context.h>
#include <libgo/coroutine.h>
#include "craft/peers.h"
#include "craft/raft.h"
#include "raft/raft_correctness.h"

#include <chrono>

namespace craft {

    void sendRequestVote(Raft *rf, int serverId,
                         const std::shared_ptr<RequestVoteArgs> &request,
                         const std::shared_ptr<RequestVoteReply> &response);
    void sendPreVote(Raft *rf, int serverId,
                     const std::shared_ptr<RequestVoteArgs> &request,
                     const std::shared_ptr<RequestVoteReply> &response);

    void startElection(Raft *rf);
    bool startPreVote(Raft *rf);
    bool hasRecentLeaderContactForElection(Raft *rf);

    void Raft::co_startElection() {
        go [this] {
            m_electionTimer->reset(getElectionTimeOut(m_leaderEelectionTimeOut_));
            for (; !m_iskilled_;) {
                RETURN_TYPE type_;
                (m_electionTimer->m_chan_) >> type_;
                if (type_ == RETURN_TYPE::TIME_OUT) {
                    startElection(this);
                } else {
                    spdlog::debug("not found type\n");
                }
            }
        };
    }

    void startElection(Raft *rf) {
        spdlog::debug("start leader election");
        rf->co_mtx_.lock();
        if (rf->m_iskilled_) {
            spdlog::debug("raft is killed,return\n");
            rf->co_mtx_.unlock();
            return;
        }
        if (rf->m_state_ == STATE::LEADER) {
            spdlog::debug("already leader,return\n");
            rf->co_mtx_.unlock();
            return;
        }
        bool preVoteEnabled = rf->m_preVoteEnabled_;
        rf->co_mtx_.unlock();
        if (preVoteEnabled && !startPreVote(rf)) {
            rf->co_mtx_.lock();
            if (!rf->m_iskilled_ && rf->m_state_ != STATE::LEADER) {
                rf->m_electionTimer->reset(getElectionTimeOut(rf->m_leaderEelectionTimeOut_));
            }
            rf->co_mtx_.unlock();
            return;
        }
        rf->co_mtx_.lock();
        if (rf->m_iskilled_ || rf->m_state_ == STATE::LEADER) {
            rf->co_mtx_.unlock();
            return;
        }
        if (preVoteEnabled && hasRecentLeaderContactForElection(rf)) {
            rf->m_electionTimer->reset(getElectionTimeOut(rf->m_leaderEelectionTimeOut_));
            rf->co_mtx_.unlock();
            return;
        }
        rf->changeToState(STATE::CANDIDATE);
        rf->m_metrics_.IncrementElection();
        int allCount = rf->m_clusterAddress_.size(), grantedCount = 1, resCount = 1;
        spdlog::debug("allCount ={} ",allCount);
        std::shared_ptr<co_chan<bool>> grantedChan(new co_chan<bool>(allCount - 1));
        rf->persist();
        rf->co_mtx_.unlock();
        for (int i = 0; i < allCount; i++) {
            if (i == rf->m_me_) {
                continue;
            }
            go [rf, i, grantedChan] {
                rf->co_mtx_.lock();
                std::shared_ptr<RequestVoteArgs> args(new RequestVoteArgs);
                args->set_candidateid(rf->m_me_);
                args->set_term(rf->m_current_term_);
                args->set_lastlogterm(rf->getLastLogTerm());
                args->set_lastlogindex(rf->getLastLogIndex());
                std::shared_ptr<RequestVoteReply> reply(new RequestVoteReply);
                sendRequestVote(rf, i, args, reply);
                bool is_voted = reply->votegranted();
                *grantedChan << is_voted; //  default false ,if rpc  success true;
                if (is_voted) {
                    rf->m_electionTimer->reset(
                            getElectionTimeOut(rf->m_leaderEelectionTimeOut_));
                }
                if (reply->term() > rf->m_current_term_) {
                    rf->m_current_term_ = reply->term();
                    rf->changeToState(STATE::FOLLOWER);
                    rf->m_votedFor_ = -1;
                    rf->persist();
                }
                rf->co_mtx_.unlock();
            };
        }

        bool flag;
        while (resCount != allCount) {
            *grantedChan >> flag;
            resCount++;
            if (flag) {
                grantedCount++;
            }
        }
        spdlog::info("[{}],current_term = {},VoteCount:[{}/{}]", rf->m_me_, rf->m_current_term_, grantedCount,
                     allCount);
        rf->co_mtx_.lock();
        if (rf->m_state_ == STATE::CANDIDATE) {

            if (grantedCount > (allCount / 2)) {

                rf->changeToState(STATE::LEADER);
            } else {
                spdlog::info("grant faild,VoteCount:[{}/{}]", grantedCount, allCount);
                rf->changeToState(STATE::FOLLOWER);
            }
        }
        rf->co_mtx_.unlock();

    }

    bool startPreVote(Raft *rf) {
        rf->co_mtx_.lock();
        if (rf->m_iskilled_ || rf->m_state_ == STATE::LEADER) {
            rf->co_mtx_.unlock();
            return false;
        }
        int allCount = rf->m_clusterAddress_.size(), grantedCount = 1, resCount = 1;
        int nextTerm = rf->m_current_term_ + 1;
        int lastLogTerm = rf->getLastLogTerm();
        int lastLogIndex = rf->getLastLogIndex();
        std::shared_ptr<co_chan<bool>> grantedChan(new co_chan<bool>(allCount - 1));
        rf->co_mtx_.unlock();

        for (int i = 0; i < allCount; i++) {
            if (i == rf->m_me_) {
                continue;
            }
            go [rf, i, grantedChan, nextTerm, lastLogTerm, lastLogIndex] {
                std::shared_ptr<RequestVoteArgs> args(new RequestVoteArgs);
                args->set_candidateid(rf->m_me_);
                args->set_term(nextTerm);
                args->set_lastlogterm(lastLogTerm);
                args->set_lastlogindex(lastLogIndex);
                std::shared_ptr<RequestVoteReply> reply(new RequestVoteReply);
                sendPreVote(rf, i, args, reply);
                *grantedChan << reply->votegranted();
            };
        }

        bool granted = false;
        while (resCount != allCount) {
            *grantedChan >> granted;
            resCount++;
            if (granted) {
                grantedCount++;
            }
        }
        spdlog::info("[{}],PreVote next_term = {},VoteCount:[{}/{}]", rf->m_me_, nextTerm,
                     grantedCount, allCount);
        return grantedCount > (allCount / 2);
    }

    bool hasRecentLeaderContactForElection(Raft *rf) {
        auto now = std::chrono::steady_clock::now();
        auto age = std::chrono::duration_cast<std::chrono::milliseconds>(now - rf->m_lastLeaderContact_);
        return age.count() >= 0 && age.count() <= static_cast<long long>(rf->m_leaderEelectionTimeOut_);
    }

    void sendRequestVote(Raft *rf, int serverId,
                         const std::shared_ptr<RequestVoteArgs> &request,
                         const std::shared_ptr<RequestVoteReply> &response) {
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_,
                                                 static_cast<int>(rf->m_clusterAddress_.size()))) {
            spdlog::error("serverId:{} invalid in sendRequestVote!", serverId);
            return;
        }
        static std::vector<std::unique_ptr<RaftRPC::Stub>> &stubs =
                rf->m_peers_->getPeerStubs();
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_, static_cast<int>(stubs.size()))) {
            spdlog::error("serverId:{} invalid in sendRequestVote!", serverId);
            return;
        }
        for (int i = 0; i < 1 && !rf->m_iskilled_; i++) {
            ClientContext context;
            std::chrono::system_clock::time_point deadline =
                    std::chrono::system_clock::now() +
                    std::chrono::milliseconds(rf->m_rpcTimeOut_);
            context.set_deadline(deadline);
            Status ok = stubs[serverId]->requestVoteRPC(&context, *request, response.get());
            rf->m_metrics_.IncrementRequestVoteSent();
            if (!ok.ok()) {
                spdlog::error("disconnect to id[{}]:{} to try getVote\n", serverId, rf->m_clusterAddress_[serverId]);
                rf->m_metrics_.IncrementRequestVoteRejected();
                continue;
            } else {
                if (response->votegranted()) {
                    rf->m_metrics_.IncrementRequestVoteGranted();
                } else {
                    rf->m_metrics_.IncrementRequestVoteRejected();
                }
                spdlog::debug("to {} success call voteRPC\n", serverId);
                break;
            }
        }
    }

    void sendPreVote(Raft *rf, int serverId,
                     const std::shared_ptr<RequestVoteArgs> &request,
                     const std::shared_ptr<RequestVoteReply> &response) {
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_,
                                                 static_cast<int>(rf->m_clusterAddress_.size()))) {
            spdlog::error("serverId:{} invalid in sendPreVote!", serverId);
            return;
        }
        static std::vector<std::unique_ptr<RaftRPC::Stub>> &stubs =
                rf->m_peers_->getPeerStubs();
        if (!raft_correctness::IsRemotePeerIndex(serverId, rf->m_me_, static_cast<int>(stubs.size()))) {
            spdlog::error("serverId:{} invalid in sendPreVote!", serverId);
            return;
        }
        ClientContext context;
        std::chrono::system_clock::time_point deadline =
                std::chrono::system_clock::now() +
                std::chrono::milliseconds(rf->m_rpcTimeOut_);
        context.set_deadline(deadline);
        Status ok = stubs[serverId]->preVoteRPC(&context, *request, response.get());
        rf->m_metrics_.IncrementPreVoteSent();
        if (!ok.ok()) {
            spdlog::error("disconnect to id[{}]:{} to try preVote\n", serverId, rf->m_clusterAddress_[serverId]);
            rf->m_metrics_.IncrementPreVoteRejected();
            return;
        }
        if (response->votegranted()) {
            rf->m_metrics_.IncrementPreVoteGranted();
        } else {
            rf->m_metrics_.IncrementPreVoteRejected();
        }
    }

};  // namespace craft
