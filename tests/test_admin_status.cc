#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#include "raft/raft_status.h"

#ifndef PROJECT_SOURCE_DIR
#define PROJECT_SOURCE_DIR "."
#endif

namespace {

std::string TempPath(const std::string& name) {
    return (std::filesystem::temp_directory_path() / name).string();
}

}  // namespace

int main() {
    craft::RaftStatusSnapshot status;
    assert(status.node_id == -1);
    assert(status.role == "FOLLOWER");
    assert(status.current_term == 0);
    assert(status.leader_id == -1);
    assert(status.commit_index == 0);
    assert(status.last_applied == 0);
    assert(status.last_log_index == 0);
    assert(status.snapshot_index == 0);
    assert(status.snapshot_term == 0);
    assert(status.log_entry_count == 0);
    assert(status.wal_bytes == 0);

    assert(craft::RaftRoleCodeToString(0) == "FOLLOWER");
    assert(craft::RaftRoleCodeToString(1) == "CANDIDATE");
    assert(craft::RaftRoleCodeToString(2) == "LEADER");

    craft::RaftMetrics metrics;
    auto initial_metrics = metrics.Snapshot();
    assert(initial_metrics.election_count == 0);
    assert(initial_metrics.append_entries_sent == 0);
    assert(initial_metrics.client_request_failed == 0);
    assert(initial_metrics.read_log_total == 0);
    assert(initial_metrics.read_index_total == 0);
    assert(initial_metrics.read_index_success == 0);
    assert(initial_metrics.read_index_failed == 0);
    assert(initial_metrics.read_index_timeout == 0);
    assert(initial_metrics.read_index_quorum_confirm_rounds == 0);
    assert(initial_metrics.leader_noop_appended == 0);
    assert(initial_metrics.leader_noop_committed == 0);
    assert(initial_metrics.pre_vote_sent == 0);
    assert(initial_metrics.pre_vote_granted == 0);
    assert(initial_metrics.pre_vote_rejected == 0);
    assert(initial_metrics.check_quorum_stepdown_count == 0);
    assert(initial_metrics.check_quorum_rounds == 0);
    assert(initial_metrics.check_quorum_success == 0);
    assert(initial_metrics.check_quorum_failed == 0);
    assert(initial_metrics.append_entries_batch_rpc_count == 0);
    assert(initial_metrics.append_entries_entries_sent == 0);
    assert(initial_metrics.append_entries_empty_heartbeat_count == 0);
    assert(initial_metrics.append_entries_max_batch_observed == 0);
    assert(initial_metrics.follower_catchup_attempts == 0);
    assert(initial_metrics.follower_catchup_success == 0);
    assert(initial_metrics.append_entries_stale_response_ignored == 0);
    assert(initial_metrics.append_entries_inflight_rejected == 0);
    metrics.IncrementElection();
    metrics.IncrementAppendEntriesSent();
    metrics.IncrementAppendEntriesSuccess();
    metrics.IncrementClientRequestTotal();
    metrics.IncrementClientRequestFailed();
    metrics.IncrementReadLogTotal();
    metrics.IncrementReadIndexTotal();
    metrics.IncrementReadIndexSuccess();
    metrics.IncrementReadIndexFailed();
    metrics.IncrementReadIndexTimeout();
    metrics.IncrementReadIndexQuorumConfirmRounds();
    metrics.IncrementLeaderNoopAppended();
    metrics.IncrementLeaderNoopCommitted();
    metrics.IncrementPreVoteSent();
    metrics.IncrementPreVoteGranted();
    metrics.IncrementPreVoteRejected();
    metrics.IncrementCheckQuorumStepdown();
    metrics.IncrementCheckQuorumRounds();
    metrics.IncrementCheckQuorumSuccess();
    metrics.IncrementCheckQuorumFailed();
    metrics.IncrementAppendEntriesBatchRpc();
    metrics.AddAppendEntriesEntriesSent(3);
    metrics.IncrementAppendEntriesEmptyHeartbeat();
    metrics.ObserveAppendEntriesBatchSize(2);
    metrics.ObserveAppendEntriesBatchSize(5);
    metrics.IncrementFollowerCatchupAttempts();
    metrics.IncrementFollowerCatchupSuccess();
    metrics.IncrementAppendEntriesStaleResponseIgnored();
    metrics.IncrementAppendEntriesInflightRejected();
    auto updated_metrics = metrics.Snapshot();
    assert(updated_metrics.election_count == 1);
    assert(updated_metrics.append_entries_sent == 1);
    assert(updated_metrics.append_entries_success == 1);
    assert(updated_metrics.client_request_total == 1);
    assert(updated_metrics.client_request_failed == 1);
    assert(updated_metrics.read_log_total == 1);
    assert(updated_metrics.read_index_total == 1);
    assert(updated_metrics.read_index_success == 1);
    assert(updated_metrics.read_index_failed == 1);
    assert(updated_metrics.read_index_timeout == 1);
    assert(updated_metrics.read_index_quorum_confirm_rounds == 1);
    assert(updated_metrics.leader_noop_appended == 1);
    assert(updated_metrics.leader_noop_committed == 1);
    assert(updated_metrics.pre_vote_sent == 1);
    assert(updated_metrics.pre_vote_granted == 1);
    assert(updated_metrics.pre_vote_rejected == 1);
    assert(updated_metrics.check_quorum_stepdown_count == 1);
    assert(updated_metrics.check_quorum_rounds == 1);
    assert(updated_metrics.check_quorum_success == 1);
    assert(updated_metrics.check_quorum_failed == 1);
    assert(updated_metrics.append_entries_batch_rpc_count == 1);
    assert(updated_metrics.append_entries_entries_sent == 3);
    assert(updated_metrics.append_entries_empty_heartbeat_count == 1);
    assert(updated_metrics.append_entries_max_batch_observed == 5);
    assert(updated_metrics.follower_catchup_attempts == 1);
    assert(updated_metrics.follower_catchup_success == 1);
    assert(updated_metrics.append_entries_stale_response_ignored == 1);
    assert(updated_metrics.append_entries_inflight_rejected == 1);

    craft::RaftStatusSnapshot before;
    before.node_id = 1;
    before.role = "LEADER";
    before.current_term = 3;
    before.leader_id = 1;
    before.commit_index = 10;
    before.last_applied = 9;
    before.last_log_index = 11;
    before.snapshot_index = 4;
    before.snapshot_term = 2;
    before.log_entry_count = 7;
    before.wal_bytes = 4096;
    before.metrics = updated_metrics;

    std::string encoded = craft::SerializeRaftStatusSnapshot(before);
    assert(encoded.find("node_id=1\n") != std::string::npos);
    assert(encoded.find("role=LEADER\n") != std::string::npos);
    assert(encoded.find("wal_bytes=4096\n") != std::string::npos);

    craft::RaftStatusSnapshot after;
    std::string error;
    assert(craft::DeserializeRaftStatusSnapshot(encoded, &after, &error));
    assert(after.node_id == before.node_id);
    assert(after.role == before.role);
    assert(after.current_term == before.current_term);
    assert(after.leader_id == before.leader_id);
    assert(after.commit_index == before.commit_index);
    assert(after.last_applied == before.last_applied);
    assert(after.last_log_index == before.last_log_index);
    assert(after.snapshot_index == before.snapshot_index);
    assert(after.snapshot_term == before.snapshot_term);
    assert(after.log_entry_count == before.log_entry_count);
    assert(after.wal_bytes == before.wal_bytes);
    assert(after.metrics.election_count == before.metrics.election_count);
    assert(after.metrics.read_index_success == before.metrics.read_index_success);
    assert(encoded.find("read_index_quorum_confirm_rounds=1\n") != std::string::npos);
    assert(after.metrics.leader_noop_committed == before.metrics.leader_noop_committed);
    assert(after.metrics.pre_vote_granted == before.metrics.pre_vote_granted);
    assert(after.metrics.check_quorum_failed == before.metrics.check_quorum_failed);
    assert(after.metrics.append_entries_entries_sent == before.metrics.append_entries_entries_sent);
    assert(after.metrics.append_entries_max_batch_observed == before.metrics.append_entries_max_batch_observed);
    assert(encoded.find("leader_noop_appended=1\n") != std::string::npos);
    assert(encoded.find("append_entries_max_batch_observed=5\n") != std::string::npos);
    assert(craft::SerializeRaftStatusSnapshot(before) == encoded);

    std::string fake_client = TempPath("raftkv_fake_kv_client.sh");
    {
        std::ofstream out(fake_client);
        out << "#!/usr/bin/env bash\n";
        out << "case \"$*\" in\n";
        out << "  *127.0.0.1:1*) printf 'node_id=1\\nrole=LEADER\\ncurrent_term=5\\nleader_id=1\\ncommit_index=8\\nlast_applied=8\\nlast_log_index=8\\nsnapshot_index=0\\nwal_bytes=128\\n' ;;\n";
        out << "  *) exit 2 ;;\n";
        out << "esac\n";
    }
    std::filesystem::permissions(fake_client,
                                 std::filesystem::perms::owner_exec |
                                     std::filesystem::perms::owner_read |
                                     std::filesystem::perms::owner_write);
    std::string table_out = TempPath("raftkv_show_status.out");
    std::string show_cmd = "RAFTKV_KV_CLIENT=" + fake_client + " bash " + PROJECT_SOURCE_DIR
        "/scripts/show_cluster_status.sh 127.0.0.1:1 127.0.0.1:2 127.0.0.1:3 >" + table_out;
    assert(std::system(show_cmd.c_str()) == 0);
    std::ifstream table_file(table_out);
    std::string table((std::istreambuf_iterator<char>(table_file)), std::istreambuf_iterator<char>());
    assert(table.find("NODE") != std::string::npos);
    assert(table.find("LEADER") != std::string::npos);
    assert(table.find("UNAVAILABLE") != std::string::npos);

    std::string cli_cmd = std::string(PROJECT_SOURCE_DIR) +
        "/bin/kv_client --servers=127.0.0.1:1 --timeout_ms=50 --retries=1 status >/dev/null 2>/dev/null";
    assert(std::system(cli_cmd.c_str()) != 0);

    std::cout << "test_admin_status passed" << std::endl;
    return 0;
}
