#include "craft/startRpcService.h"
#include "grpc++/grpc++.h"
#include "craft/public.h"

using grpc::Server;
using grpc::ServerBuilder;
using grpc::ServerContext;
using grpc::Status;

namespace craft{
    RpcServiceImpl::RpcServiceImpl(Raft *rf) :m_rf_(rf){
        if(rf == nullptr){
            spdlog::critical("raft is null in rpcserice init");
            exit(2);
        }
        m_addr_ = rf->m_clusterAddress_[rf->m_me_];
    }
    void RpcServiceImpl::publishRpcService() {
        std::string server_address(m_rf_->m_clusterAddress_[m_rf_->m_me_]);
        ServerBuilder builder;
        builder.SetSyncServerOption(grpc::ServerBuilder::SyncServerOption::NUM_CQS, 4);
        int a =1;
        builder.AddListeningPort(server_address, grpc::InsecureServerCredentials(),&a);
        builder.AddChannelArgument(GRPC_ARG_ALLOW_REUSEPORT, 1);
        builder.RegisterService(this);
        std::unique_ptr<Server> server(builder.BuildAndStart());
        spdlog::info("Server[{}] listening on {}", m_rf_->m_me_, server_address);
        server->Wait();
    }

    Status RpcServiceImpl::GetNodeStatus(::grpc::ServerContext *context,
                                         const ::NodeStatusRequest *request,
                                         ::NodeStatusReply *response) {
        (void)context;
        (void)request;
        RaftStatusSnapshot snapshot = m_rf_->getStatusSnapshot();
        response->set_node_id(snapshot.node_id);
        response->set_role(snapshot.role);
        response->set_current_term(snapshot.current_term);
        response->set_leader_id(snapshot.leader_id);
        response->set_commit_index(snapshot.commit_index);
        response->set_last_applied(snapshot.last_applied);
        response->set_last_log_index(snapshot.last_log_index);
        response->set_snapshot_index(snapshot.snapshot_index);
        response->set_snapshot_term(snapshot.snapshot_term);
        response->set_log_entry_count(static_cast<std::uint64_t>(snapshot.log_entry_count));
        response->set_wal_bytes(snapshot.wal_bytes);
        MetricsStatus* metrics = response->mutable_metrics();
        metrics->set_election_count(snapshot.metrics.election_count);
        metrics->set_leader_change_count(snapshot.metrics.leader_change_count);
        metrics->set_append_entries_sent(snapshot.metrics.append_entries_sent);
        metrics->set_append_entries_success(snapshot.metrics.append_entries_success);
        metrics->set_append_entries_failed(snapshot.metrics.append_entries_failed);
        metrics->set_request_vote_sent(snapshot.metrics.request_vote_sent);
        metrics->set_request_vote_granted(snapshot.metrics.request_vote_granted);
        metrics->set_request_vote_rejected(snapshot.metrics.request_vote_rejected);
        metrics->set_install_snapshot_sent(snapshot.metrics.install_snapshot_sent);
        metrics->set_install_snapshot_success(snapshot.metrics.install_snapshot_success);
        metrics->set_install_snapshot_failed(snapshot.metrics.install_snapshot_failed);
        metrics->set_snapshot_created_count(snapshot.metrics.snapshot_created_count);
        metrics->set_wal_recovery_truncated_tail_count(snapshot.metrics.wal_recovery_truncated_tail_count);
        metrics->set_client_request_total(snapshot.metrics.client_request_total);
        metrics->set_client_request_success(snapshot.metrics.client_request_success);
        metrics->set_client_request_failed(snapshot.metrics.client_request_failed);
        return Status::OK;
    }
};
