#include "craft/raft.h"

#include <chrono>

#include "raft/raft_correctness.h"

namespace craft {
namespace {

int TermAtIndex(Raft* rf, int log_index) {
    if (log_index == rf->m_snapShotIndex) {
        return rf->m_snapShotTerm;
    }
    int store_index = rf->getStoreIndexByLogIndex(log_index);
    if (store_index >= 0 && store_index < static_cast<int>(rf->m_logs_.size())) {
        return rf->m_logs_[store_index].term();
    }
    return 0;
}

void StepDownForTerm(Raft* rf, int term) {
    rf->co_mtx_.lock();
    if (term > rf->m_current_term_) {
        rf->m_current_term_ = term;
        rf->m_votedFor_ = -1;
        rf->changeToState(STATE::FOLLOWER);
        rf->m_electionTimer->reset(getElectionTimeOut(rf->m_leaderEelectionTimeOut_));
        rf->persist();
    }
    rf->co_mtx_.unlock();
}

}  // namespace

ReadIndexResult Raft::confirmReadIndex(int timeout_ms) {
    m_metrics_.IncrementReadIndexTotal();
    m_metrics_.IncrementReadIndexQuorumConfirmRounds();

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);

    int term = 0;
    int leader_id = -1;
    int read_index = 0;
    int peer_count = 0;

    co_mtx_.lock();
    if (m_state_ != STATE::LEADER) {
        co_mtx_.unlock();
        m_metrics_.IncrementReadIndexFailed();
        return {false, true, false, 0, "not leader"};
    }
    term = m_current_term_;
    leader_id = m_me_;
    read_index = m_commitIndex_;
    if (read_index < m_snapShotIndex || TermAtIndex(this, read_index) != term) {
        co_mtx_.unlock();
        m_metrics_.IncrementReadIndexTimeout();
        m_metrics_.IncrementReadIndexFailed();
        return {false, false, true, 0, "ReadIndex leader has not committed an entry in current term"};
    }
    peer_count = m_peers_->numPeers();
    co_mtx_.unlock();

    int quorum = peer_count / 2 + 1;
    int confirmed = 1;
    auto& stubs = m_peers_->getPeerStubs();

    for (int peer = 0; peer < peer_count && confirmed < quorum; ++peer) {
        if (peer == m_me_) {
            continue;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            break;
        }
        if (!raft_correctness::IsRemotePeerIndex(peer, m_me_, static_cast<int>(stubs.size()))) {
            continue;
        }

        int prev_log_index = 0;
        int prev_log_term = 0;
        co_mtx_.lock();
        if (m_state_ != STATE::LEADER || m_current_term_ != term) {
            co_mtx_.unlock();
            m_metrics_.IncrementReadIndexFailed();
            return {false, true, false, 0, "leadership changed during ReadIndex"};
        }
        prev_log_index = m_nextIndex_[peer] - 1;
        if (prev_log_index < m_snapShotIndex) {
            prev_log_index = m_snapShotIndex;
        }
        int last_log_index = getLastLogIndex();
        if (prev_log_index > last_log_index) {
            prev_log_index = last_log_index;
        }
        prev_log_term = TermAtIndex(this, prev_log_index);
        co_mtx_.unlock();

        AppendEntriesArgs args;
        args.set_term(term);
        args.set_leaderid(leader_id);
        args.set_prevlogindex(prev_log_index);
        args.set_prevlogterm(prev_log_term);
        args.set_leadercommit(read_index);

        AppendEntriesReply reply;
        ClientContext context;
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
        int rpc_timeout_ms = static_cast<int>(remaining.count());
        if (rpc_timeout_ms <= 0) {
            break;
        }
        if (rpc_timeout_ms > static_cast<int>(m_rpcTimeOut_)) {
            rpc_timeout_ms = static_cast<int>(m_rpcTimeOut_);
        }
        context.set_deadline(std::chrono::system_clock::now() + std::chrono::milliseconds(rpc_timeout_ms));

        Status ok = stubs[peer]->appendEntries(&context, args, &reply);
        m_metrics_.IncrementAppendEntriesSent();
        if (!ok.ok()) {
            m_metrics_.IncrementAppendEntriesFailed();
            continue;
        }
        if (reply.term() > term) {
            m_metrics_.IncrementAppendEntriesFailed();
            StepDownForTerm(this, reply.term());
            m_metrics_.IncrementReadIndexFailed();
            return {false, true, false, 0, "observed higher term during ReadIndex"};
        }
        if (reply.success()) {
            m_metrics_.IncrementAppendEntriesSuccess();
            ++confirmed;
        } else {
            m_metrics_.IncrementAppendEntriesFailed();
        }
    }

    if (confirmed < quorum) {
        m_metrics_.IncrementReadIndexTimeout();
        m_metrics_.IncrementReadIndexFailed();
        return {false, false, true, 0, "ReadIndex quorum confirmation timeout"};
    }

    co_mtx_.lock();
    if (m_state_ != STATE::LEADER || m_current_term_ != term) {
        co_mtx_.unlock();
        m_metrics_.IncrementReadIndexFailed();
        return {false, true, false, 0, "leadership changed during ReadIndex"};
    }
    if (m_commitIndex_ > read_index) {
        read_index = m_commitIndex_;
    }
    co_mtx_.unlock();

    return {true, false, false, read_index, ""};
}

void Raft::recordLogRead() {
    m_metrics_.IncrementReadLogTotal();
}

void Raft::recordReadIndexSuccess() {
    m_metrics_.IncrementReadIndexSuccess();
}

void Raft::recordReadIndexFailure() {
    m_metrics_.IncrementReadIndexFailed();
}

void Raft::recordReadIndexTimeoutFailure() {
    m_metrics_.IncrementReadIndexTimeout();
    m_metrics_.IncrementReadIndexFailed();
}

}  // namespace craft
