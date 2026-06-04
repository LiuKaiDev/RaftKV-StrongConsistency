#!/usr/bin/env python3
"""Basic seeded-chaos history checker.

This is intentionally not a formal linearizability checker. It validates that
the recorded sequential test history is well formed, that duplicate successful
append retries use dedup semantics, and that final node dumps agree with the
state implied by successful operations.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple


HISTORY_FIELDS = {
    "sequence",
    "timestamp_start",
    "timestamp_end",
    "client_id",
    "request_id",
    "operation",
    "key",
    "input_value",
    "response_status",
    "response_value",
    "target_node",
    "leader_hint",
    "retry_count",
    "final_success",
}

FAULT_FIELDS = {"sequence", "timestamp", "event", "node_id", "reason", "seed"}


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
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSON: {exc}") from exc
            if not isinstance(obj, dict):
                raise ValueError(f"{path}:{line_no}: record is not an object")
            records.append(obj)
    return records


def parse_dump(path):
    # type: (Path) -> Dict[str, str]
    out = {}  # type: Dict[str, str]
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            if "=" not in line:
                raise ValueError(f"{path}:{line_no}: dump line lacks '='")
            key, value = line.split("=", 1)
            out[key] = value
    return out


def require_fields(records, fields, label):
    # type: (List[Dict[str, Any]], Set[str], str) -> None
    for idx, record in enumerate(records, 1):
        missing = sorted(fields - set(record))
        if missing:
            raise ValueError(f"{label} record {idx} missing fields: {', '.join(missing)}")


def check_history(history, final_state):
    # type: (List[Dict[str, Any]], Dict[str, str]) -> None
    model = {}  # type: Dict[str, str]
    append_results = {}  # type: Dict[Tuple[str, int], str]
    applied_appends = set()  # type: Set[Tuple[str, int]]

    for record in sorted(history, key=lambda item: int(item["sequence"])):
        op = str(record["operation"])
        key = str(record["key"])
        value = str(record["input_value"])
        response_status = str(record["response_status"])
        response_value = str(record["response_value"])
        final_success = bool(record["final_success"])
        client_id = str(record["client_id"])
        request_id = int(record["request_id"])
        dedup_key = (client_id, request_id)

        if op == "get":
            if final_success:
                expected = model.get(key)
                if expected is None:
                    raise ValueError(f"successful get for absent key {key} returned {response_value!r}")
                if response_value != expected:
                    raise ValueError(
                        f"successful get for {key} returned {response_value!r}, expected {expected!r}"
                    )
            elif response_status == "KEY_NOT_FOUND" and key in model:
                raise ValueError(f"get for existing key {key} returned KEY_NOT_FOUND")
            continue

        if op == "put":
            if final_success:
                model[key] = value
            continue

        if op == "append":
            if not final_success:
                continue
            previous = append_results.get(dedup_key)
            if previous is not None:
                if previous != response_value:
                    raise ValueError(
                        f"duplicate successful append {dedup_key} returned {response_value!r}, "
                        f"first result was {previous!r}"
                    )
                continue
            append_results[dedup_key] = response_value
            if dedup_key not in applied_appends:
                model[key] = model.get(key, "") + value
                applied_appends.add(dedup_key)
            if response_value != model[key]:
                raise ValueError(
                    f"append result for {key} was {response_value!r}, modeled value is {model[key]!r}"
                )
            continue

        if op == "delete":
            if final_success:
                model.pop(key, None)
            elif response_status == "KEY_NOT_FOUND":
                if key in model:
                    raise ValueError(f"delete for existing key {key} returned KEY_NOT_FOUND")
            continue

        raise ValueError(f"unknown operation in history: {op}")

    for key, value in model.items():
        actual = final_state.get(key)
        if actual != value:
            raise ValueError(f"final state for committed key {key}: expected {value!r}, got {actual!r}")
    extra_keys = sorted(set(final_state) - set(model))
    if extra_keys:
        raise ValueError(f"final state has unexplained keys: {', '.join(extra_keys)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check basic seeded-chaos history consistency.")
    parser.add_argument("--history", required=True, type=Path)
    parser.add_argument("--faults", required=True, type=Path)
    parser.add_argument("--dump", action="append", required=True, type=Path)
    args = parser.parse_args()

    try:
        history = load_jsonl(args.history)
        faults = load_jsonl(args.faults)
        require_fields(history, HISTORY_FIELDS, "history")
        require_fields(faults, FAULT_FIELDS, "fault")

        dumps = [parse_dump(path) for path in args.dump]
        if len(dumps) != 3:
            raise ValueError("expected exactly three node dumps")
        for idx, dump in enumerate(dumps[1:], 2):
            if dump != dumps[0]:
                raise ValueError(f"node dump {idx} differs from node dump 1")

        check_history(history, dumps[0])
    except Exception as exc:  # noqa: BLE001 - checker prints concise CLI diagnostics.
        print(f"CHAOS HISTORY CHECK FAILED: {exc}", file=sys.stderr)
        return 1

    print("CHAOS HISTORY CHECK PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
