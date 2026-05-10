#include "craft/raft.h"
#include "craft/public.h"

namespace craft {

    void startApplyLogs(Raft *rf);

    void Raft::co_applyLogs() {

        go [this] {

            for (; !m_iskilled_;) {
                void *a;
                *m_notifyApplyCh_ >> a;
                startApplyLogs(this);
            }
        };

    }

    void startApplyLogs(Raft *rf) {
        rf->co_mtx_.lock();
        std::vector<ApplyMsg> msgs;
        if (rf->m_lastApplied_ < rf->m_snapShotIndex) {
            int lastIncludedTerm = rf->m_snapShotTerm;
            int lastIncludedIndex = rf->m_snapShotIndex;
            int lastIndex = rf->getLastLogIndex();
            if (lastIncludedIndex > lastIndex) {
                rf->m_logs_.resize(1);
            } else {
                int installLen = lastIncludedIndex - rf->m_snapShotIndex;
                rf->m_logs_.erase(rf->m_logs_.begin(), rf->m_logs_.begin() + installLen);
                rf->m_logs_[0].set_command("");
            }
            rf->m_logs_[0].set_term(lastIncludedTerm);
            rf->m_snapShotIndex = lastIncludedIndex;
            rf->m_snapShotTerm = lastIncludedTerm;
            if (rf->m_commitIndex_ < lastIncludedIndex) {
                rf->m_commitIndex_ = lastIncludedIndex;
            }
            rf->m_lastApplied_ = lastIncludedIndex;
            // Restore the state machine from the snapshot,
            // the deserialization method is rewritten
            // and implemented by the upper-layer service
            rf->m_persister_->deserialization(rf->m_persister_->snapshotFileName_.c_str());
            rf->persist();

        } else if (rf->m_commitIndex_ <= rf->m_lastApplied_) {

            msgs.resize(0);
        } else {
            msgs.reserve(rf->m_commitIndex_ - rf->m_lastApplied_);
            for (int i = rf->m_lastApplied_ + 1; i <= rf->m_commitIndex_; i++) {
                int storeIndex = rf->getStoreIndexByLogIndex(i);
                if (storeIndex < 0 || storeIndex >= static_cast<int>(rf->m_logs_.size())) {
                    break;
                }
                msgs.push_back(ApplyMsg{true,
                                        {rf->m_logs_[storeIndex].command()},
                                        i});
            }

        }
        if (msgs.empty()) {
            rf->co_mtx_.unlock();
            return;
        }
        rf->co_mtx_.unlock();

        for (const auto &msg: msgs) {
            if (msg.commandValid) {
                *rf->m_applyCh_ << msg;
            }
            rf->co_mtx_.lock();
            rf->m_lastApplied_ = msg.commandIndex;
            rf->persist();
            rf->co_mtx_.unlock();
        }

    }
};
