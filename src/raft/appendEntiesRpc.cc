#include "craft/public.h"
#include "craft/startRpcService.h"
#include <algorithm>

namespace craft {


    Status RpcServiceImpl::appendEntries(::grpc::ServerContext *context,
                                         const ::AppendEntriesArgs *request,
                                         ::AppendEntriesReply *response) {
        m_rf_->co_mtx_.lock();
        response->set_term(m_rf_->m_current_term_);
        response->set_success(false);
        auto rewriteLogs = [this]() {
            std::vector<std::pair<int, std::string>> entries;
            for (int i = 1; i < static_cast<int>(m_rf_->m_logs_.size()); ++i) {
                entries.emplace_back(m_rf_->m_logs_[i].term(), m_rf_->m_logs_[i].command());
            }
            return m_rf_->m_persister_->rewriteLogEntries(m_rf_->m_snapShotIndex + 1, entries);
        };

        do {
            if (request->term() < m_rf_->m_current_term_) {
                response->set_term(m_rf_->m_current_term_);
                break;
            }

            if (request->term() > m_rf_->m_current_term_) {
                m_rf_->m_current_term_ = request->term();
                m_rf_->m_votedFor_ = -1;
                m_rf_->changeToState(STATE::FOLLOWER);
            } else if (m_rf_->m_state_ != STATE::FOLLOWER) {
                spdlog::warn("node [{}] step down after receiving appendEntries from leader [{}]",
                             m_rf_->m_me_, request->leaderid());
                m_rf_->changeToState(STATE::FOLLOWER);
            }

            m_rf_->m_leaderId_ = request->leaderid();
            m_rf_->m_electionTimer->reset(getElectionTimeOut(m_rf_->m_leaderEelectionTimeOut_));
            response->set_term(m_rf_->m_current_term_);

            int lastLogIndex = m_rf_->getLastLogIndex();
            if (request->prevlogindex() < m_rf_->m_snapShotIndex) {
                response->set_nextlogindex(m_rf_->m_snapShotIndex + 1);
            } else if (request->prevlogindex() > lastLogIndex) {
                response->set_nextlogindex(lastLogIndex + 1);
            } else if (request->prevlogindex() == m_rf_->m_snapShotIndex) {
                if (m_rf_->isOutOfArgsAppendEntries(request)) {
                    response->set_nextlogindex(0);
                } else {
                    m_rf_->m_logs_.resize(1);
                    for (const auto &log: request->entries()) {
                        m_rf_->m_logs_.push_back(log);
                    }
                    if (rewriteLogs()) {
                        response->set_success(true);
                        response->set_nextlogindex(m_rf_->getLastLogIndex() + 1);
                    }
                }
            } else if (request->prevlogterm() ==
                       m_rf_->m_logs_[m_rf_->getStoreIndexByLogIndex(request->prevlogindex())].term()) {
                if (m_rf_->isOutOfArgsAppendEntries(request)) {
                    response->set_nextlogindex(0);
                } else {
                    int storeIndex = m_rf_->getStoreIndexByLogIndex(request->prevlogindex());
                    m_rf_->m_logs_.resize(storeIndex + 1);
                    for (const auto &log: request->entries()) {
                        m_rf_->m_logs_.push_back(log);
                    }
                    if (rewriteLogs()) {
                        response->set_success(true);
                        response->set_nextlogindex(m_rf_->getLastLogIndex() + 1);
                    }
                }
            } else {
                int term = m_rf_->m_logs_[m_rf_->getStoreIndexByLogIndex(request->prevlogindex())].term();
                int index = request->prevlogindex();
                for (; (index > m_rf_->m_commitIndex_)
                       && (index > m_rf_->m_snapShotIndex)
                       && (m_rf_->m_logs_[m_rf_->getStoreIndexByLogIndex(index)].term() == term);) {
                    index--;
                }
                response->set_nextlogindex(index + 1);
            }
            if (response->success()) {
                int newCommit = std::min(request->leadercommit(), m_rf_->getLastLogIndex());
                if (m_rf_->m_commitIndex_ < newCommit) {
                    m_rf_->m_commitIndex_ = newCommit;
                    *m_rf_->m_notifyApplyCh_ << (void *) 1;
                    spdlog::info("id[{}]:{}[{}] commit log[{}]", m_rf_->m_me_, m_rf_->m_clusterAddress_[m_rf_->m_me_],
                                 m_rf_->stringState(m_rf_->m_state_), m_rf_->m_commitIndex_);
                }
            }
            m_rf_->persist();
        } while (false);
        m_rf_->co_mtx_.unlock();

        return Status::OK;
    }

}
