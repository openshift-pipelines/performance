#!/usr/bin/env python3
"""Reconcile one benchmark run with Results records and TaskRun logs."""

import argparse
import csv
import json
import re
import ssl
import sys
import time
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, as_completed, wait
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen


MARKER = re.compile(r"Hello World Chains Performance Benchmark Test \d+ from Task\d+")
MANIFEST_MARKER = re.compile(r'echo "(Hello World Chains Performance Benchmark Test \d+ from Task(\d+))"')


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def completion_times_match(left, right):
    """Compare completion times at second resolution.

    Kubernetes and PostgreSQL/JSON storage may disagree on fractional seconds.
    Second-level equality still catches early incomplete records that never
    receive a final completionTime update.
    """
    return timestamp(left).replace(microsecond=0) == timestamp(right).replace(microsecond=0)


def expected_runs(benchmark, status, snapshots):
    started = timestamp(status["results"]["started"])
    ended = timestamp(status["results"]["ended"])
    if ended < started:
        raise ValueError("Benchmark end precedes its start")

    runs = []
    seen = set()
    for collection, kind in (("pipelineruns", "PipelineRun"), ("taskruns", "TaskRun")):
        for key, data in benchmark.get(collection, {}).items():
            created = data.get("creationTimestamp")
            if not created or not started <= timestamp(created) <= ended:
                continue
            namespace, name = key.split(".", 1)
            snapshot = snapshots.get((kind, namespace, name), {})
            record = data.get("record", "")
            uid = data.get("uid") or snapshot.get("uid")
            if not uid and isinstance(record, str) and "/records/" in record:
                uid = record.rsplit("/records/", 1)[-1]
            runs.append({
                "kind": kind,
                "namespace": namespace,
                "name": name,
                "uid": uid,
                "record": record,
                "completion_time": data.get("completionTime") or snapshot.get("completion_time"),
            })
            seen.add((kind, namespace, name))
    for (kind, namespace, name), data in snapshots.items():
        if (kind, namespace, name) in seen:
            continue
        created = data.get("creation_time")
        if created and started <= timestamp(created) <= ended:
            runs.append({
                "kind": kind,
                "namespace": namespace,
                "name": name,
                "uid": data["uid"],
                "record": "",
                "completion_time": data.get("completion_time"),
            })
    return runs, started, ended


def snapshot_runs(paths):
    found = {}
    for path, kind in paths:
        if not path or not path.exists():
            continue
        for item in json.loads(path.read_text()).get("items", []):
            metadata = item.get("metadata", {})
            namespace, name, uid = (metadata.get(field) for field in ("namespace", "name", "uid"))
            if namespace and name and uid:
                found[(kind, namespace, name)] = {
                    "uid": uid,
                    "creation_time": metadata.get("creationTimestamp"),
                    "completion_time": item.get("status", {}).get("completionTime"),
                }
    return found


def database_records(path):
    records = {}
    with path.open(newline="") as source:
        for row in csv.reader(source):
            if len(row) != 4:
                raise ValueError(f"Unexpected PostgreSQL row: {row!r}")
            parent, record_type, record_name, completion_time = row
            key = (parent, record_type.rsplit(".", 1)[-1], record_name)
            records.setdefault(key, []).append(completion_time)
    return records


def expected_markers(path):
    markers = {}
    if path and path.exists():
        for line, task_number in MANIFEST_MARKER.findall(path.read_text()):
            markers.setdefault(f"echo{task_number}", Counter())[line] += 1
    return markers


def log_path(taskrun, pipelineruns):
    uid = taskrun["uid"]
    if not uid:
        return None
    record = taskrun["record"]
    if isinstance(record, str) and record.endswith(f"/records/{uid}"):
        return record.replace("/records/", "/logs/", 1)

    prefix = (taskrun["namespace"], taskrun["name"])
    parents = [
        run for run in pipelineruns
        if run["namespace"] == prefix[0]
        and prefix[1].startswith(run["name"] + "-")
        and run["uid"]
    ]
    if not parents:
        return None
    parent = max(parents, key=lambda run: len(run["name"]))
    return f'{taskrun["namespace"]}/results/{parent["uid"]}/logs/{uid}'


def fetch_log(base_url, path, attempts, delay):
    url = base_url.rstrip("/") + "/apis/results.tekton.dev/v1alpha2/parents/" + quote(path, safe="/")
    context = ssl._create_unverified_context()
    error = None
    for attempt in range(attempts):
        try:
            with urlopen(url, context=context, timeout=15) as response:
                return response.read().decode("utf-8", errors="replace"), None
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            error = str(exc)
            if attempt + 1 < attempts:
                time.sleep(delay)
    return None, error


def check_log(taskrun, pipelineruns, markers, base_url, attempts, delay):
    identity = {key: taskrun[key] for key in ("namespace", "name", "uid")}
    path = log_path(taskrun, pipelineruns)
    if not path:
        return "missing_logs", {**identity, "reason": "Cannot determine TaskRun log path"}
    body, error = fetch_log(base_url, path, attempts, delay)
    if error:
        return "missing_logs", {**identity, "path": path, "reason": error}
    if not body:
        return "missing_logs", {**identity, "path": path, "reason": "Empty log"}

    task_name = re.search(r"-echo(\d+)$", taskrun["name"])
    expected = markers.get(f"echo{task_name.group(1)}") if task_name else None
    if not expected:
        return "log_line_failures", {**identity, "reason": "No expected lines for TaskRun"}
    actual = Counter(MARKER.findall(body))
    if actual != expected:
        missing = list((expected - actual).elements())
        unexpected = list((actual - expected).elements())
        return "log_line_failures", {
            **identity,
            "expected_lines": sum(expected.values()),
            "actual_marker_lines": sum(actual.values()),
            "missing_lines": missing,
            "unexpected_lines": unexpected,
        }
    return "verified", None


def verify(args, report):
    benchmark = json.loads(args.benchmark_output.read_text())
    status = json.loads(args.status_data.read_text())
    snapshots = snapshot_runs(((args.pipelineruns, "PipelineRun"), (args.taskruns, "TaskRun")))
    runs, started, ended = expected_runs(benchmark, status, snapshots)
    pipelineruns = [run for run in runs if run["kind"] == "PipelineRun"]
    taskruns = [run for run in runs if run["kind"] == "TaskRun"]
    report["window"] = {"started": started.isoformat(), "ended": ended.isoformat()}
    report["expected"] = {
        "pipelineruns": len(pipelineruns),
        "taskruns": len(taskruns),
        "records": len(runs),
        "logs": len(taskruns),
    }
    if not pipelineruns:
        raise ValueError("No PipelineRuns found in this benchmark window")
    if args.expected_pipelineruns and len(pipelineruns) != args.expected_pipelineruns:
        report["errors"].append(
            f"Expected {args.expected_pipelineruns} PipelineRuns to be created, "
            f"but captured {len(pipelineruns)}"
        )

    database = database_records(args.db_records)
    if args.db_query_failed:
        report["errors"].append("PostgreSQL records query failed")
    for run in runs:
        identity = {key: run[key] for key in ("kind", "namespace", "name", "uid")}
        if not run["uid"]:
            report["missing_records"].append({**identity, "reason": "UID unavailable"})
        elif len(database.get((run["namespace"], run["kind"], run["uid"]), [])) != 1:
            report["missing_records"].append({
                **identity,
                "reason": "Missing or duplicate PostgreSQL record",
                "matches": len(database.get((run["namespace"], run["kind"], run["uid"]), [])),
            })
        else:
            stored_completion = database[(run["namespace"], run["kind"], run["uid"])][0]
            expected_completion = run["completion_time"]
            if not expected_completion:
                report["incomplete_records"].append({
                    **identity, "reason": "Benchmark has no completionTime"
                })
            elif not stored_completion:
                report["incomplete_records"].append({
                    **identity, "reason": "PostgreSQL record has no status.completionTime"
                })
            elif not completion_times_match(stored_completion, expected_completion):
                report["incomplete_records"].append({
                    **identity,
                    "reason": "PostgreSQL completionTime differs from benchmark",
                    "expected_completion_time": expected_completion,
                    "stored_completion_time": stored_completion,
                })
    report["verified"]["records"] = (
        len(runs) - len(report["missing_records"]) - len(report["incomplete_records"])
    )

    markers = expected_markers(args.manifest)
    if not markers:
        raise ValueError("Generated pipeline manifest contains no expected TaskRun log lines")
    observed_taskruns = {(run["namespace"], run["name"]) for run in taskruns}
    for pipelinerun in pipelineruns:
        for task_name in markers:
            taskrun_name = f'{pipelinerun["name"]}-{task_name}'
            if (pipelinerun["namespace"], taskrun_name) not in observed_taskruns:
                report["missing_generated_taskruns"].append({
                    "namespace": pipelinerun["namespace"],
                    "name": taskrun_name,
                    "pipelinerun_uid": pipelinerun["uid"],
                })
    expected_taskruns = len(pipelineruns) * len(markers)
    report["expected"].update({
        "taskruns": expected_taskruns,
        "records": len(pipelineruns) + expected_taskruns,
        "logs": expected_taskruns,
    })
    if not args.api_url:
        raise ValueError("Results API route was not found")
    def record_result(future, run):
        try:
            category, issue = future.result()
        except Exception as exc:
            category = "missing_logs"
            issue = {key: run[key] for key in ("namespace", "name", "uid")}
            issue["reason"] = f"Unexpected log check error: {exc}"
        if issue is None:
            report["verified"]["logs"] += 1
            return 0
        report[category].append(issue)
        return 1

    checked = 0
    failures = 0
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        pending = {}

        def fill_queue():
            nonlocal checked
            while len(pending) < args.workers and checked < len(taskruns):
                run = taskruns[checked]
                future = executor.submit(
                    check_log, run, pipelineruns, markers, args.api_url, args.attempts, args.retry_delay
                )
                pending[future] = run
                checked += 1

        fill_queue()
        while pending:
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in done:
                failures += record_result(future, pending.pop(future))
            if failures >= args.failure_limit:
                report["errors"].append(
                    f"Stopped scheduling log checks after {failures} failures"
                )
                break
            fill_queue()

        for future in as_completed(pending):
            record_result(future, pending[future])
        for run in taskruns[checked:]:
            report["unchecked_logs"].append({
                **{key: run[key] for key in ("namespace", "name", "uid")},
                "reason": "Not checked after log failure limit was reached",
            })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark-output", type=Path, required=True)
    parser.add_argument("--status-data", type=Path, required=True)
    parser.add_argument("--pipelineruns", type=Path)
    parser.add_argument("--taskruns", type=Path)
    parser.add_argument("--db-records", type=Path, required=True)
    parser.add_argument("--db-query-failed", action="store_true")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--api-url", default="",
                        help="Results API base URL (https://route-host). Required for log checks.")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--retry-delay", type=float, default=2)
    parser.add_argument("--failure-limit", type=int, default=100)
    parser.add_argument("--expected-pipelineruns", type=int, default=0)
    args = parser.parse_args()

    report = {
        "status": "failed",
        "expected": {},
        "verified": {"records": 0, "logs": 0},
        "missing_records": [],
        "incomplete_records": [],
        "missing_generated_taskruns": [],
        "missing_logs": [],
        "unchecked_logs": [],
        "log_line_failures": [],
        "errors": [],
    }
    try:
        if args.workers < 1 or args.attempts < 1 or args.retry_delay < 0 or args.failure_limit < 1 or args.expected_pipelineruns < 0:
            raise ValueError("workers, attempts, and failure limit must be positive; retry delay cannot be negative")
        verify(args, report)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        report["errors"].append(str(exc))
    except Exception as exc:
        report["errors"].append(f"Unexpected verification error: {exc}")

    for category in ("missing_records", "incomplete_records", "missing_generated_taskruns", "missing_logs", "unchecked_logs", "log_line_failures"):
        report[category].sort(key=lambda item: (item["namespace"], item["name"]))
    if not any(report[key] for key in ("missing_records", "incomplete_records", "missing_generated_taskruns", "missing_logs", "unchecked_logs", "log_line_failures", "errors")):
        report["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        f'Results ingestion: {report["status"]} '
        f'({report["verified"]["records"]}/{report["expected"].get("records", 0)} records, '
        f'{report["verified"]["logs"]}/{report["expected"].get("logs", 0)} logs); '
        f'details: {args.output}'
    )
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
