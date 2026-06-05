#!/usr/bin/env python3
"""Small KV linearizability checker for recorded concurrent test histories.

This checker searches for one legal sequential order for each key. It is a
bounded test-history checker, not a formal proof for all executions.
"""

import argparse
import json
import re
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


REQUIRED_FIELDS = {
    "sequence",
    "worker_id",
    "client_id",
    "request_id",
    "operation",
    "key",
    "input_value",
    "invoke_time_ns",
    "complete_time_ns",
    "result_class",
    "application_status",
    "response_value",
    "final_success",
    "retry_count",
}

PASS = "PASS"
LINEARIZABILITY_SAFETY_FAIL = "LINEARIZABILITY_SAFETY_FAIL"
WORKLOAD_LIVENESS_FAIL = "WORKLOAD_LIVENESS_FAIL"
INFRASTRUCTURE_FAIL = "INFRASTRUCTURE_FAIL"
INCONCLUSIVE = "INCONCLUSIVE"
DEFAULT_MAX_RECORDS_PER_KEY = 200
SUMMARY_FIELDS = [
    "sequence",
    "worker_id",
    "client_id",
    "request_id",
    "operation",
    "input_value",
    "invoke_time_ns",
    "complete_time_ns",
    "result_class",
    "application_status",
    "response_value",
]


class CheckTimeout(Exception):
    pass


class DuplicateRequestError(ValueError):
    def __init__(self, message, records):
        # type: (str, Sequence[Dict[str, Any]]) -> None
        super().__init__(message)
        self.records = list(records)


ABSENT = ("ABSENT",)
INVALID = ("INVALID",)


ATTEMPT_RE = re.compile(
    r"^worker=(?P<worker_id>\S+) request_id=(?P<request_id>\S+) "
    r"attempt=(?P<attempt>\S+) op=(?P<operation>\S+) key=(?P<key>\S+) "
    r"(?:servers=(?P<servers>.*?) )?status=(?P<status>\S+) result=(?P<result_class>\S+) "
    r"stdout=(?P<stdout>.*) stderr=(?P<stderr>.*)$"
)


def load_jsonl(path):
    # type: (Path) -> List[Dict[str, Any]]
    records = []  # type: List[Dict[str, Any]]
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError as exc:
                raise ValueError("%s:%s: invalid JSON: %s" % (path, line_no, exc))
            if not isinstance(obj, dict):
                raise ValueError("%s:%s: record is not an object" % (path, line_no))
            missing = sorted(REQUIRED_FIELDS - set(obj))
            if missing:
                raise ValueError("%s:%s: missing fields: %s" % (path, line_no, ", ".join(missing)))
            records.append(obj)
    return records


def normalize_bool(value):
    # type: (Any) -> bool
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() == "true"
    return bool(value)


def normalize_record(record):
    # type: (Dict[str, Any]) -> Dict[str, Any]
    out = dict(record)
    out["sequence"] = int(out["sequence"])
    out["worker_id"] = int(out["worker_id"])
    out["request_id"] = int(out["request_id"])
    out["invoke_time_ns"] = int(out["invoke_time_ns"])
    out["complete_time_ns"] = int(out["complete_time_ns"])
    out["retry_count"] = int(out["retry_count"])
    out["final_success"] = normalize_bool(out["final_success"])
    out["client_id"] = str(out["client_id"])
    out["operation"] = str(out["operation"]).lower()
    out["key"] = str(out["key"])
    out["input_value"] = str(out["input_value"])
    out["result_class"] = str(out["result_class"])
    out["application_status"] = str(out["application_status"])
    out["response_value"] = str(out["response_value"])
    if out["complete_time_ns"] < out["invoke_time_ns"]:
        raise ValueError("record %s completes before it starts" % out["sequence"])
    return out


def dedup_key(record):
    # type: (Dict[str, Any]) -> Tuple[str, int]
    return (record["client_id"], record["request_id"])


def check_duplicate_results(records):
    # type: (Sequence[Dict[str, Any]]) -> None
    seen = {}  # type: Dict[Tuple[str, int], Tuple[Tuple[str, str, str, str, str, str, bool], Dict[str, Any]]]
    for record in records:
        key = dedup_key(record)
        result = (
            record["operation"],
            record["key"],
            record["input_value"],
            record["result_class"],
            record["application_status"],
            record["response_value"],
            record["final_success"],
        )
        previous = seen.get(key)
        if previous is None:
            seen[key] = (result, record)
        elif previous[0] != result:
            raise DuplicateRequestError(
                "duplicate request %s returned different result: %r vs %r"
                % (key, previous[0], result),
                [previous[1], record],
            )


def logical_records(records):
    # type: (Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]
    out = []  # type: List[Dict[str, Any]]
    seen = set()  # type: Set[Tuple[str, int]]
    for record in sorted(records, key=lambda r: (r["invoke_time_ns"], r["complete_time_ns"], r["sequence"])):
        result_class = record["result_class"]
        if result_class in ("FATAL_ERROR", "RETRIABLE_INFRASTRUCTURE_ERROR"):
            raise ValueError("operation %s ended with %s" % (record["sequence"], result_class))
        key = dedup_key(record)
        if key not in seen:
            out.append(record)
            seen.add(key)
    return out


def is_completed_record(record):
    # type: (Dict[str, Any]) -> bool
    return record["result_class"] in ("SUCCESS", "EXPECTED_APPLICATION_ERROR")


def is_retriable_record(record):
    # type: (Dict[str, Any]) -> bool
    return record["result_class"] == "RETRIABLE_INFRASTRUCTURE_ERROR"


def is_fatal_record(record):
    # type: (Dict[str, Any]) -> bool
    return record["result_class"] == "FATAL_ERROR"


def split_quiescent_components(records):
    # type: (Sequence[Dict[str, Any]]) -> List[List[Dict[str, Any]]]
    ordered = sorted(records, key=lambda r: (r["invoke_time_ns"], r["complete_time_ns"], r["sequence"]))
    components = []  # type: List[List[Dict[str, Any]]]
    current = []  # type: List[Dict[str, Any]]
    max_complete = None  # type: Optional[int]
    for record in ordered:
        if current and max_complete is not None and record["invoke_time_ns"] > max_complete:
            components.append(current)
            current = []
            max_complete = None
        current.append(record)
        if max_complete is None or record["complete_time_ns"] > max_complete:
            max_complete = record["complete_time_ns"]
    if current:
        components.append(current)
    return components


def check_deadline(deadline_ns):
    # type: (int) -> None
    if now_ns() >= deadline_ns:
        raise CheckTimeout()


def now_ns():
    # type: () -> int
    monotonic_ns = getattr(time, "monotonic_ns", None)
    if monotonic_ns is not None:
        return int(monotonic_ns())
    return int(time.monotonic() * 1000000000)


def write_fragment(path, records):
    # type: (Path, Iterable[Dict[str, Any]]) -> None
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, sort_keys=True) + "\n")


def state_to_json(state):
    # type: (object) -> Dict[str, Any]
    if state == ABSENT:
        return {"present": False, "value": None}
    return {"present": True, "value": state}


def format_state(state):
    # type: (object) -> str
    if state == ABSENT:
        return "ABSENT"
    return repr(state)


def summarize_record(record):
    # type: (Dict[str, Any]) -> Dict[str, Any]
    out = {}  # type: Dict[str, Any]
    for field in SUMMARY_FIELDS:
        out[field] = record.get(field)
    if "key" in record:
        out["key"] = record["key"]
    if "final_success" in record:
        out["final_success"] = record["final_success"]
    if "retry_count" in record:
        out["retry_count"] = record["retry_count"]
    return out


def actual_result(record):
    # type: (Dict[str, Any]) -> Dict[str, Any]
    return {
        "result_class": record["result_class"],
        "application_status": record["application_status"],
        "response_value": record["response_value"],
        "final_success": record["final_success"],
    }


def success_ok(record):
    # type: (Dict[str, Any]) -> bool
    return (
        record["final_success"]
        and record["result_class"] == "SUCCESS"
        and record["application_status"] == "OK"
    )


def key_not_found(record):
    # type: (Dict[str, Any]) -> bool
    return (
        record["result_class"] == "EXPECTED_APPLICATION_ERROR"
        and record["application_status"] == "KEY_NOT_FOUND"
        and not record["final_success"]
    )


def explain_operation(state, record):
    # type: (object, Dict[str, Any]) -> Dict[str, Any]
    op = record["operation"]
    response = record["response_value"]
    value = record["input_value"]
    ok = success_ok(record)
    missing = key_not_found(record)
    base = {
        "operation": summarize_record(record),
        "state_before": state_to_json(state),
        "actual": actual_result(record),
    }  # type: Dict[str, Any]

    def legal(next_state, expected):
        # type: (object, str) -> Dict[str, Any]
        out = dict(base)
        out.update({
            "legal": True,
            "next_state": state_to_json(next_state),
            "expected": expected,
            "reason": "matches model",
        })
        return out

    def illegal(expected, reason):
        # type: (str, str) -> Dict[str, Any]
        out = dict(base)
        out.update({
            "legal": False,
            "next_state": None,
            "expected": expected,
            "reason": reason,
        })
        return out

    if op == "put":
        if ok and response == "OK":
            return legal(value, "SUCCESS/OK with response_value OK; state becomes input_value")
        return illegal("SUCCESS/OK with response_value OK", "put did not return the required OK success")

    if op == "get":
        if state == ABSENT:
            if missing:
                return legal(state, "KEY_NOT_FOUND while key is absent")
            return illegal("KEY_NOT_FOUND while key is absent", "get returned a value or non-missing status for an absent key")
        if ok and response == state:
            return legal(state, "SUCCESS/OK with current value %r" % state)
        return illegal("SUCCESS/OK with response_value %r" % state, "get response does not match the current model value")

    if op == "append":
        base_value = "" if state == ABSENT else state
        expected_value = base_value + value
        if ok and response == expected_value:
            return legal(expected_value, "SUCCESS/OK with appended value %r" % expected_value)
        if missing:
            return illegal(
                "SUCCESS/OK with response_value %r" % expected_value,
                "append returned KEY_NOT_FOUND, but append creates an absent key under the API contract",
            )
        return illegal(
            "SUCCESS/OK with response_value %r" % expected_value,
            "append response does not equal current value plus input_value",
        )

    if op == "delete":
        if state == ABSENT:
            if missing:
                return legal(state, "KEY_NOT_FOUND while key is absent")
            return illegal("KEY_NOT_FOUND while key is absent", "delete returned success or a non-missing status for an absent key")
        if ok and response == "OK":
            return legal(ABSENT, "SUCCESS/OK with response_value OK; state becomes absent")
        return illegal("SUCCESS/OK with response_value OK", "delete did not return the required OK success")

    raise ValueError("unknown operation: %s" % op)


def apply_operation(state, record):
    # type: (object, Dict[str, Any]) -> object
    explanation = explain_operation(state, record)
    if not explanation["legal"]:
        return INVALID
    next_state = explanation["next_state"]
    if next_state["present"]:
        return next_state["value"]
    return ABSENT


def real_time_edges(records):
    # type: (Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]
    edges = []  # type: List[Dict[str, Any]]
    for left in records:
        for right in records:
            if left["sequence"] == right["sequence"]:
                continue
            if left["complete_time_ns"] < right["invoke_time_ns"]:
                edges.append({
                    "from_sequence": left["sequence"],
                    "to_sequence": right["sequence"],
                    "from_complete_time_ns": left["complete_time_ns"],
                    "to_invoke_time_ns": right["invoke_time_ns"],
                })
    edges.sort(key=lambda e: (e["from_sequence"], e["to_sequence"]))
    return edges


def analyze_component(initial_state, records, deadline_ns):
    # type: (object, Sequence[Dict[str, Any]], int) -> Tuple[Set[object], Optional[Dict[str, Any]]]
    n = len(records)
    predecessors = [0] * n
    for i, left in enumerate(records):
        for j, right in enumerate(records):
            if i != j and left["complete_time_ns"] < right["invoke_time_ns"]:
                predecessors[j] |= 1 << i

    full_mask = (1 << n) - 1
    failed_memo = set()  # type: Set[Tuple[int, object]]
    results = set()  # type: Set[object]
    first_deadend = [None]  # type: List[Optional[Dict[str, Any]]]

    def make_frontier(done_mask, state, linearized_sequences, candidate_reports):
        # type: (int, object, Sequence[int], Sequence[Dict[str, Any]]) -> Dict[str, Any]
        eligible = []  # type: List[int]
        blocked = []  # type: List[Dict[str, Any]]
        remaining = []  # type: List[Dict[str, Any]]
        for idx, record in enumerate(records):
            bit = 1 << idx
            if done_mask & bit:
                continue
            remaining.append(summarize_record(record))
            if predecessors[idx] & ~done_mask:
                blockers = []  # type: List[int]
                for pred_idx, pred_record in enumerate(records):
                    if predecessors[idx] & (1 << pred_idx) and not (done_mask & (1 << pred_idx)):
                        blockers.append(pred_record["sequence"])
                blocked.append({
                    "operation": summarize_record(record),
                    "unmet_predecessor_sequences": blockers,
                })
            else:
                eligible.append(idx)
        return {
            "done_mask": done_mask,
            "linearized_sequences": list(linearized_sequences),
            "model_state": state_to_json(state),
            "remaining_operations": remaining,
            "eligible_candidate_sequences": [records[idx]["sequence"] for idx in eligible],
            "blocked_operations": blocked,
            "candidate_explanations": list(candidate_reports),
        }

    def search(done_mask, state, linearized_sequences):
        # type: (int, object, Sequence[int]) -> bool
        check_deadline(deadline_ns)
        memo_key = (done_mask, state)
        if memo_key in failed_memo:
            return False
        if done_mask == full_mask:
            results.add(state)
            return True

        eligible = []  # type: List[int]
        for idx in range(n):
            bit = 1 << idx
            if done_mask & bit:
                continue
            if predecessors[idx] & ~done_mask:
                continue
            eligible.append(idx)
        eligible.sort(key=lambda idx: (records[idx]["complete_time_ns"], records[idx]["invoke_time_ns"], records[idx]["sequence"]))

        found = False
        candidate_reports = []  # type: List[Dict[str, Any]]
        for idx in eligible:
            record = records[idx]
            explanation = explain_operation(state, record)
            if not explanation["legal"]:
                candidate_reports.append(explanation)
                continue
            next_state_json = explanation["next_state"]
            next_state = next_state_json["value"] if next_state_json["present"] else ABSENT
            if search(done_mask | (1 << idx), next_state, list(linearized_sequences) + [record["sequence"]]):
                found = True
            else:
                report = dict(explanation)
                report["legal"] = False
                report["reason"] = "operation matches the model locally, but every continuation from its next state fails"
                candidate_reports.append(report)

        if not found:
            if first_deadend[0] is None:
                first_deadend[0] = make_frontier(done_mask, state, linearized_sequences, candidate_reports)
            failed_memo.add(memo_key)
        return found

    search(0, initial_state, [])
    return results, first_deadend[0]


def component_successors(initial_state, records, deadline_ns):
    # type: (object, Sequence[Dict[str, Any]], int) -> Set[object]
    results, _ = analyze_component(initial_state, records, deadline_ns)
    return results


def check_key_history(records, deadline_ns):
    # type: (Sequence[Dict[str, Any]], int) -> Tuple[str, Optional[Dict[str, Any]]]
    states = {ABSENT}  # type: Set[object]
    for component_index, component in enumerate(split_quiescent_components(records), 1):
        next_states = set()  # type: Set[object]
        component_diagnostics = []  # type: List[Dict[str, Any]]
        initial_states = list(states)
        initial_states.sort(key=format_state)
        for state in initial_states:
            successors, frontier = analyze_component(state, component, deadline_ns)
            next_states.update(successors)
            if frontier is not None:
                component_diagnostics.append({
                    "initial_state": state_to_json(state),
                    "frontier": frontier,
                })
        if not next_states:
            diagnostic = component_diagnostics[0] if component_diagnostics else {
                "initial_state": state_to_json(ABSENT),
                "frontier": None,
            }
            diagnostic.update({
                "component_index": component_index,
                "component_initial_states": [state_to_json(state) for state in initial_states],
                "failing_component": [summarize_record(record) for record in component],
            })
            return LINEARIZABILITY_SAFETY_FAIL, diagnostic
        states = next_states
    return PASS, None


def build_key_failure_diagnostic(key, key_records, key_diagnostic):
    # type: (str, Sequence[Dict[str, Any]], Dict[str, Any]) -> Dict[str, Any]
    out = {
        "status": LINEARIZABILITY_SAFETY_FAIL,
        "failure_key": key,
        "problem": "key %s has no legal linearization" % key,
        "model": {
            "initial_state": state_to_json(ABSENT),
            "put": "overwrites or creates the key and must return OK",
            "get": "returns the current value, or KEY_NOT_FOUND only when absent",
            "append": "appends to an existing value, or creates an absent key from the appended value; must return the new value",
            "delete": "removes an existing key and returns OK, or KEY_NOT_FOUND only when absent",
            "real_time_order": "A must precede B when A.complete_time_ns < B.invoke_time_ns",
        },
        "normalized_history": [summarize_record(record) for record in key_records],
        "real_time_edges": real_time_edges(key_records),
    }  # type: Dict[str, Any]
    out.update(key_diagnostic)
    fragment = key_diagnostic.get("failing_component", [])
    out["minimized_failure_fragment"] = fragment
    return out


def build_duplicate_failure_diagnostic(message, records):
    # type: (str, Sequence[Dict[str, Any]]) -> Dict[str, Any]
    return {
        "status": LINEARIZABILITY_SAFETY_FAIL,
        "failure_key": None,
        "problem": message,
        "duplicate_request_records": [summarize_record(record) for record in records],
        "normalized_history": [summarize_record(record) for record in records],
        "real_time_edges": real_time_edges(records),
    }


def load_fault_timeline(path):
    # type: (Optional[Path]) -> List[Dict[str, Any]]
    if path is None or not path.exists():
        return []
    out = []  # type: List[Dict[str, Any]]
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                out.append({"line_no": line_no, "raw": line})
                continue
            if isinstance(obj, dict):
                out.append(obj)
            else:
                out.append({"line_no": line_no, "raw": obj})
    return out


def parse_attempt_log(path):
    # type: (Optional[Path]) -> Dict[Tuple[int, int], List[Dict[str, Any]]]
    attempts = {}  # type: Dict[Tuple[int, int], List[Dict[str, Any]]]
    if path is None or not path.exists():
        return attempts
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.rstrip("\n")
            match = ATTEMPT_RE.match(line)
            if not match:
                continue
            item = dict(match.groupdict())  # type: Dict[str, Any]
            item["line_no"] = line_no
            for key in ("worker_id", "request_id", "attempt", "status"):
                try:
                    item[key] = int(item[key])
                except (TypeError, ValueError):
                    pass
            attempts.setdefault((int(item["worker_id"]), int(item["request_id"])), []).append(item)
    return attempts


def find_failed_operation(records):
    # type: (Sequence[Dict[str, Any]]) -> Optional[Dict[str, Any]]
    incomplete = [record for record in records if not is_completed_record(record)]
    if not incomplete:
        return None
    incomplete.sort(key=lambda r: (r["sequence"], r["invoke_time_ns"], r["complete_time_ns"]))
    return incomplete[0]


def build_workload_failure_diagnostic(status, completed_status, completed_detail, records,
                                      checked_completed_records=None,
                                      attempt_log=None, faults=None):
    # type: (str, str, str, Sequence[Dict[str, Any]], Optional[Sequence[Dict[str, Any]]], Optional[Path], Optional[Path]) -> Dict[str, Any]
    incomplete = [record for record in records if not is_completed_record(record)]
    retriable = [record for record in incomplete if is_retriable_record(record)]
    fatal = [record for record in incomplete if is_fatal_record(record)]
    failed = find_failed_operation(records)
    attempt_map = parse_attempt_log(attempt_log)
    failed_attempts = []  # type: List[Dict[str, Any]]
    if failed is not None:
        failed_attempts = attempt_map.get((failed["worker_id"], failed["request_id"]), [])
    last_error = ""
    if failed_attempts:
        last = failed_attempts[-1]
        last_error = "%s %s" % (last.get("stdout", ""), last.get("stderr", ""))
        last_error = last_error.strip()
    elif failed is not None:
        last_error = failed.get("response_value", "")
    return {
        "status": status,
        "problem": "workload did not complete all operations with a definitive result",
        "completed_history_linearizable": completed_status == PASS,
        "completed_history_status": completed_status,
        "completed_history_detail": completed_detail,
        "completed_history_scope": "definitive operations completed before the first incomplete operation began",
        "completed_history_checked_operation_count": len(checked_completed_records or []),
        "completed_operation_count": len(records) - len(incomplete),
        "incomplete_operation_count": len(incomplete),
        "retriable_error_count": len(retriable),
        "fatal_error_count": len(fatal),
        "exhausted_retry_operation_count": len(retriable),
        "failed_sequence": failed.get("sequence") if failed is not None else None,
        "failed_operation": summarize_record(failed) if failed is not None else None,
        "client_id": failed.get("client_id") if failed is not None else None,
        "request_id": failed.get("request_id") if failed is not None else None,
        "retry_count": failed.get("retry_count") if failed is not None else None,
        "attempts": failed_attempts,
        "last_error": last_error,
        "fault_timeline": load_fault_timeline(faults),
        "completed_history_checked_operations": [
            summarize_record(record) for record in (checked_completed_records or [])
        ],
        "incomplete_operations": [summarize_record(record) for record in incomplete],
    }


def write_failure_diagnostics(json_path, text_path, diagnostic):
    # type: (Optional[Path], Optional[Path], Dict[str, Any]) -> None
    if json_path is not None:
        json_path.parent.mkdir(parents=True, exist_ok=True)
        with json_path.open("w", encoding="utf-8") as f:
            json.dump(diagnostic, f, indent=2, sort_keys=True)
            f.write("\n")
    if text_path is not None:
        text_path.parent.mkdir(parents=True, exist_ok=True)
        with text_path.open("w", encoding="utf-8") as f:
            f.write(render_failure_text(diagnostic))


def render_failure_text(diagnostic):
    # type: (Dict[str, Any]) -> str
    lines = []  # type: List[str]
    lines.append("%s DIAGNOSTIC" % diagnostic.get("status", "FAIL"))
    lines.append("problem: %s" % diagnostic.get("problem"))
    if "completed_history_linearizable" in diagnostic:
        lines.append("completed_history_linearizable: %s" % diagnostic.get("completed_history_linearizable"))
        lines.append("completed_history_status: %s" % diagnostic.get("completed_history_status"))
        lines.append("completed_history_detail: %s" % diagnostic.get("completed_history_detail"))
        lines.append("completed_history_scope: %s" % diagnostic.get("completed_history_scope"))
        lines.append("completed_history_checked_operation_count: %s" % diagnostic.get("completed_history_checked_operation_count"))
        lines.append("incomplete_operation_count: %s" % diagnostic.get("incomplete_operation_count"))
        lines.append("retriable_error_count: %s" % diagnostic.get("retriable_error_count"))
        lines.append("exhausted_retry_operation_count: %s" % diagnostic.get("exhausted_retry_operation_count"))
        lines.append("failed_sequence: %s" % diagnostic.get("failed_sequence"))
        lines.append("client_id: %s" % diagnostic.get("client_id"))
        lines.append("request_id: %s" % diagnostic.get("request_id"))
        lines.append("retry_count: %s" % diagnostic.get("retry_count"))
        lines.append("last_error: %s" % diagnostic.get("last_error"))
        lines.append("")
        if diagnostic.get("failed_operation"):
            lines.append("Failed operation:")
            lines.append("  %s" % json.dumps(diagnostic["failed_operation"], sort_keys=True))
            lines.append("")
        if diagnostic.get("attempts"):
            lines.append("Attempt timeline:")
            for attempt in diagnostic["attempts"]:
                lines.append("  %s" % json.dumps(attempt, sort_keys=True))
            lines.append("")
        if diagnostic.get("fault_timeline"):
            lines.append("Fault timeline:")
            for fault in diagnostic["fault_timeline"]:
                lines.append("  %s" % json.dumps(fault, sort_keys=True))
            lines.append("")
        if diagnostic.get("completed_history_checked_operations"):
            lines.append("Completed history checked operations:")
            for record in diagnostic["completed_history_checked_operations"]:
                lines.append("  %s" % json.dumps(record, sort_keys=True))
            lines.append("")
        if diagnostic.get("incomplete_operations"):
            lines.append("Incomplete operations:")
            for record in diagnostic["incomplete_operations"]:
                lines.append("  %s" % json.dumps(record, sort_keys=True))
            lines.append("")
    if diagnostic.get("failure_key") is not None:
        lines.append("failure_key: %s" % diagnostic.get("failure_key"))
    lines.append("")
    if "model" in diagnostic:
        lines.append("Model:")
        for key in ["put", "get", "append", "delete", "real_time_order"]:
            lines.append("  %s: %s" % (key, diagnostic["model"][key]))
        lines.append("")
    if "normalized_history" in diagnostic:
        lines.append("Normalized history:")
        for record in diagnostic["normalized_history"]:
            lines.append("  seq=%s worker=%s client=%s request=%s op=%s key=%s input=%r invoke=%s complete=%s result=%s app=%s response=%r" % (
                record.get("sequence"),
                record.get("worker_id"),
                record.get("client_id"),
                record.get("request_id"),
                record.get("operation"),
                record.get("key"),
                record.get("input_value"),
                record.get("invoke_time_ns"),
                record.get("complete_time_ns"),
                record.get("result_class"),
                record.get("application_status"),
                record.get("response_value"),
            ))
        lines.append("")
    frontier = diagnostic.get("frontier")
    if frontier:
        lines.append("Frontier where search lost all candidates:")
        lines.append("  linearized_sequences: %s" % frontier.get("linearized_sequences"))
        lines.append("  model_state: %s" % frontier.get("model_state"))
        lines.append("  eligible_candidate_sequences: %s" % frontier.get("eligible_candidate_sequences"))
        lines.append("  remaining_operations:")
        for record in frontier.get("remaining_operations", []):
            lines.append("    seq=%s op=%s input=%r result=%s app=%s response=%r" % (
                record.get("sequence"),
                record.get("operation"),
                record.get("input_value"),
                record.get("result_class"),
                record.get("application_status"),
                record.get("response_value"),
            ))
        lines.append("  candidate explanations:")
        for item in frontier.get("candidate_explanations", []):
            op = item.get("operation", {})
            lines.append("    seq=%s op=%s legal=%s expected=%s actual=%s reason=%s" % (
                op.get("sequence"),
                op.get("operation"),
                item.get("legal"),
                item.get("expected"),
                item.get("actual"),
                item.get("reason"),
            ))
        lines.append("")
    if diagnostic.get("minimized_failure_fragment"):
        lines.append("Minimized failure fragment:")
        for record in diagnostic["minimized_failure_fragment"]:
            lines.append("  %s" % json.dumps(record, sort_keys=True))
        lines.append("")
    if "real_time_edges" in diagnostic:
        lines.append("Real-time order edges (complete < invoke):")
        for edge in diagnostic["real_time_edges"]:
            lines.append("  %s -> %s" % (edge["from_sequence"], edge["to_sequence"]))
        lines.append("")
    return "\n".join(lines) + "\n"


def check_completed_records(normalized, timeout_ms, failure_fragment, max_records_per_key,
                            failure_json=None, failure_text=None):
    # type: (Sequence[Dict[str, Any]], int, Path, int, Optional[Path], Optional[Path]) -> Tuple[str, str]
    completed = [record for record in normalized if is_completed_record(record)]
    logical = logical_records(completed)
    by_key = {}  # type: Dict[str, List[Dict[str, Any]]]
    for record in logical:
        by_key.setdefault(record["key"], []).append(record)

    deadline_ns = now_ns() + timeout_ms * 1000000
    try:
        for key in sorted(by_key):
            if len(by_key[key]) > max_records_per_key:
                return (
                    INCONCLUSIVE,
                    "key %s has %s records, above limit %s"
                    % (key, len(by_key[key]), max_records_per_key),
                )
            result, fragment = check_key_history(by_key[key], deadline_ns)
            if result == LINEARIZABILITY_SAFETY_FAIL:
                diagnostic = build_key_failure_diagnostic(key, by_key[key], fragment or {})
                failure_records = diagnostic.get("minimized_failure_fragment") or by_key[key]
                write_fragment(failure_fragment, failure_records)
                write_failure_diagnostics(failure_json, failure_text, diagnostic)
                return LINEARIZABILITY_SAFETY_FAIL, "key %s has no legal linearization" % key
    except CheckTimeout:
        return INCONCLUSIVE, "search timed out after %sms" % timeout_ms
    return PASS, "all keys have a legal linearization"


def check_history(records, timeout_ms, failure_fragment, max_records_per_key=DEFAULT_MAX_RECORDS_PER_KEY,
                  failure_json=None, failure_text=None, normalized_history=None,
                  attempt_log=None, faults=None):
    # type: (Sequence[Dict[str, Any]], int, Path, int, Optional[Path], Optional[Path], Optional[Path], Optional[Path], Optional[Path]) -> Tuple[str, str]
    normalized = [normalize_record(record) for record in records]
    normalized.sort(key=lambda r: (r["invoke_time_ns"], r["complete_time_ns"], r["sequence"]))
    if normalized_history is not None:
        write_fragment(normalized_history, normalized)
    try:
        check_duplicate_results(normalized)
    except DuplicateRequestError as exc:
        write_fragment(failure_fragment, exc.records)
        write_failure_diagnostics(
            failure_json,
            failure_text,
            build_duplicate_failure_diagnostic(str(exc), exc.records),
        )
        return LINEARIZABILITY_SAFETY_FAIL, str(exc)

    incomplete = [record for record in normalized if not is_completed_record(record)]
    if incomplete:
        first_incomplete_invoke = min(record["invoke_time_ns"] for record in incomplete)
        completed_check_records = [
            record for record in normalized
            if is_completed_record(record) and record["complete_time_ns"] < first_incomplete_invoke
        ]
    else:
        completed_check_records = [record for record in normalized if is_completed_record(record)]

    completed_status, completed_detail = check_completed_records(
        completed_check_records,
        timeout_ms,
        failure_fragment,
        max_records_per_key,
        failure_json,
        failure_text,
    )
    if completed_status != PASS:
        return completed_status, completed_detail

    if incomplete:
        status = INFRASTRUCTURE_FAIL if any(is_fatal_record(record) for record in incomplete) else WORKLOAD_LIVENESS_FAIL
        diagnostic = build_workload_failure_diagnostic(
            status,
            completed_status,
            completed_detail,
            normalized,
            completed_check_records,
            attempt_log,
            faults,
        )
        failed = find_failed_operation(normalized)
        write_fragment(failure_fragment, [failed] if failed is not None else incomplete)
        write_failure_diagnostics(failure_json, failure_text, diagnostic)
        detail = (
            "completed_history_linearizable=%s incomplete_operation_count=%s "
            "retriable_error_count=%s exhausted_retry_operation_count=%s "
            "failed_sequence=%s last_error=%s"
            % (
                diagnostic["completed_history_linearizable"],
                diagnostic["incomplete_operation_count"],
                diagnostic["retriable_error_count"],
                diagnostic["exhausted_retry_operation_count"],
                diagnostic["failed_sequence"],
                diagnostic["last_error"],
            )
        )
        return status, detail

    return PASS, completed_detail


def record(sequence, worker, client, request, op, key, value, start, end,
           result_class, status, response, final_success=True):
    # type: (int, int, str, int, str, str, str, int, int, str, str, str, bool) -> Dict[str, Any]
    return {
        "sequence": sequence,
        "worker_id": worker,
        "client_id": client,
        "request_id": request,
        "operation": op,
        "key": key,
        "input_value": value,
        "invoke_time_ns": start,
        "complete_time_ns": end,
        "result_class": result_class,
        "application_status": status,
        "response_value": response,
        "final_success": final_success,
        "retry_count": 0,
    }


def expect_case(name, records, expected, timeout_ms=1000):
    # type: (str, Sequence[Dict[str, Any]], str, int) -> None
    with tempfile.TemporaryDirectory() as tmp:
        fragment = Path(tmp) / "fragment.jsonl"
        try:
            actual, detail = check_history(records, timeout_ms, fragment)
        except Exception as exc:  # noqa: BLE001 - self-test maps validation errors to FAIL.
            actual, detail = LINEARIZABILITY_SAFETY_FAIL, str(exc)
        if actual != expected:
            raise AssertionError("%s: expected %s, got %s: %s" % (name, expected, actual, detail))


def run_self_test():
    # type: () -> int
    expect_case(
        "append_absent_creates_key",
        [record(1, 1, "c1", 1, "append", "k", "x", 10, 20, "SUCCESS", "OK", "x")],
        PASS,
    )
    expect_case(
        "append_existing_key",
        [
            record(1, 1, "c1", 1, "put", "k", "a", 10, 20, "SUCCESS", "OK", "OK"),
            record(2, 1, "c1", 2, "append", "k", "b", 30, 40, "SUCCESS", "OK", "ab"),
        ],
        PASS,
    )
    expect_case(
        "append_absent_key_not_found_is_illegal",
        [record(1, 1, "c1", 1, "append", "k", "x", 10, 20, "EXPECTED_APPLICATION_ERROR", "KEY_NOT_FOUND", "", False)],
        LINEARIZABILITY_SAFETY_FAIL,
    )
    expect_case(
        "append_absent_then_get",
        [
            record(1, 1, "c1", 1, "append", "k", "x", 10, 20, "SUCCESS", "OK", "x"),
            record(2, 2, "c2", 1, "get", "k", "", 30, 40, "SUCCESS", "OK", "x"),
        ],
        PASS,
    )
    expect_case(
        "put_append_get",
        [
            record(1, 1, "c1", 1, "put", "k", "a", 10, 20, "SUCCESS", "OK", "OK"),
            record(2, 1, "c1", 2, "append", "k", "b", 30, 40, "SUCCESS", "OK", "ab"),
            record(3, 2, "c2", 1, "get", "k", "", 50, 60, "SUCCESS", "OK", "ab"),
        ],
        PASS,
    )
    expect_case(
        "concurrent_append_and_get_has_legal_order",
        [
            record(1, 1, "c1", 1, "append", "k", "x", 10, 100, "SUCCESS", "OK", "x"),
            record(2, 2, "c2", 1, "get", "k", "", 20, 30, "EXPECTED_APPLICATION_ERROR", "KEY_NOT_FOUND", "", False),
        ],
        PASS,
    )
    expect_case(
        "duplicate_append_same_request_is_deduplicated",
        [
            record(1, 1, "same", 1, "append", "k", "x", 10, 20, "SUCCESS", "OK", "x"),
            record(2, 1, "same", 1, "append", "k", "x", 30, 40, "SUCCESS", "OK", "x"),
            record(3, 2, "reader", 1, "get", "k", "", 50, 60, "SUCCESS", "OK", "x"),
        ],
        PASS,
    )
    expect_case(
        "same_request_different_result_fails",
        [
            record(1, 1, "same", 1, "append", "k", "x", 10, 20, "SUCCESS", "OK", "x"),
            record(2, 1, "same", 1, "append", "k", "x", 30, 40, "SUCCESS", "OK", "xx"),
        ],
        LINEARIZABILITY_SAFETY_FAIL,
    )
    expect_case(
        "put_completed_then_get_returns_old_value",
        [
            record(1, 1, "c1", 1, "put", "k", "a", 10, 20, "SUCCESS", "OK", "OK"),
            record(2, 2, "c2", 1, "get", "k", "", 30, 40, "SUCCESS", "OK", "old"),
        ],
        LINEARIZABILITY_SAFETY_FAIL,
    )
    expect_case(
        "timeout",
        [
            record(1, 1, "c1", 1, "put", "k", "a", 10, 100, "SUCCESS", "OK", "OK"),
            record(2, 2, "c2", 1, "put", "k", "b", 10, 100, "SUCCESS", "OK", "OK"),
        ],
        INCONCLUSIVE,
        timeout_ms=0,
    )
    expect_case(
        "retriable_infrastructure_error_is_liveness_fail",
        [
            record(1, 1, "c1", 1, "put", "k", "a", 10, 20, "SUCCESS", "OK", "OK"),
            record(
                2,
                2,
                "c2",
                1,
                "get",
                "k",
                "",
                30,
                100,
                "RETRIABLE_INFRASTRUCTURE_ERROR",
                "INFRASTRUCTURE_ERROR",
                "NOT_LEADER: not leader",
                False,
            ),
        ],
        WORKLOAD_LIVENESS_FAIL,
    )
    print("SELF TEST PASSED")
    return 0


def main():
    # type: () -> int
    parser = argparse.ArgumentParser(description="Check a RaftKV concurrent history for linearizability.")
    parser.add_argument("--history", type=Path)
    parser.add_argument("--timeout_ms", type=int, default=5000)
    parser.add_argument("--max-records-per-key", type=int, default=DEFAULT_MAX_RECORDS_PER_KEY)
    parser.add_argument("--failure-fragment", type=Path)
    parser.add_argument("--failure-json", type=Path)
    parser.add_argument("--failure-text", type=Path)
    parser.add_argument("--normalized-history", type=Path)
    parser.add_argument("--attempt-log", type=Path)
    parser.add_argument("--faults", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if args.history is None:
        parser.error("--history is required unless --self-test is used")

    fragment = args.failure_fragment
    if fragment is None:
        fragment = args.history.with_suffix(".linearizability_failure.jsonl")
    failure_json = args.failure_json
    if failure_json is None:
        failure_json = args.history.parent / "linearizability_failure.json"
    failure_text = args.failure_text
    if failure_text is None:
        failure_text = args.history.parent / "linearizability_failure.txt"

    try:
        records = load_jsonl(args.history)
        result, detail = check_history(
            records,
            args.timeout_ms,
            fragment,
            args.max_records_per_key,
            failure_json,
            failure_text,
            args.normalized_history,
            args.attempt_log,
            args.faults,
        )
    except Exception as exc:  # noqa: BLE001 - CLI prints concise diagnostics.
        result = INFRASTRUCTURE_FAIL
        detail = str(exc)

    if result == PASS:
        print("LINEARIZABILITY PASSED")
        return 0
    if result == INCONCLUSIVE:
        print("LINEARIZABILITY INCONCLUSIVE: %s" % detail)
        return 2
    if result == LINEARIZABILITY_SAFETY_FAIL:
        print("LINEARIZABILITY_SAFETY_FAIL: %s" % detail)
    elif result == WORKLOAD_LIVENESS_FAIL:
        print("WORKLOAD_LIVENESS_FAIL: %s" % detail)
    elif result == INFRASTRUCTURE_FAIL:
        print("INFRASTRUCTURE_FAIL: %s" % detail)
    else:
        print("%s: %s" % (result, detail))
    if failure_text is not None and failure_text.exists():
        print("")
        print(failure_text.read_text(encoding="utf-8"), end="")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
