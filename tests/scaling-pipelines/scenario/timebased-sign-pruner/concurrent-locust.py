#!/usr/bin/env python3
"""Cycle Results read workloads during this scenario's ingestion window."""

import argparse
from datetime import datetime, timezone
import json
from itertools import cycle
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ARTIFACT = Path("locust-concurrent.json")
LOG = Path("locust-test.log")
LOG_DIR = Path("locust-concurrent")
# Reserve time for operator/pod startup and cleanup when admitting another run.
STARTUP_TIMEOUT = 120
CLEANUP_MARGIN = 60
ENDPOINTS = {
    "fetch-record": "/record",
    "fetch-all-records": "/records",
    "fetch-log": "/log",
}


def timestamp(value):
    # The CI tooling image uses Python 3.6: fromisoformat and colon-separated
    # offsets in strptime's %z are only supported starting with Python 3.7.
    normalized = re.sub(r"([+-]\d{2}):(\d{2})$", r"\1\2", value.replace("Z", "+0000"))
    normalized = re.sub(r"(\.\d{6})\d+", r"\1", normalized)
    pattern = "%Y-%m-%dT%H:%M:%S" + (".%f" if "." in normalized else "") + "%z"
    return datetime.strptime(normalized, pattern).timestamp()


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def settings(env):
    if env.get("RUN_LOCUST") != "true":
        raise ValueError("Concurrent reads require RUN_LOCUST=true")
    if env.get("LOCUST_SCENARIO"):
        raise ValueError("Remove LOCUST_SCENARIO: concurrent mode now cycles all three read workloads")
    duration = env.get("LOCUST_DURATION", "5m")
    match = re.fullmatch(r"([1-9][0-9]*)([hms]?)", duration)
    if not match:
        raise ValueError("LOCUST_DURATION must be a positive duration such as 5m or 300s")
    seconds = int(match[1]) * {"h": 3600, "m": 60, "s": 1, "": 1}[match[2]]
    delay = int(env.get("LOCUST_START_DELAY", "300"))
    stop_before = int(env.get("LOCUST_STOP_BEFORE_END", "600"))
    total = int(env.get("TOTAL_TIMEOUT", "0"))
    users = int(env.get("LOCUST_USERS", "100"))
    workers = int(env.get("LOCUST_WORKERS", "5"))
    spawn = int(env.get("LOCUST_SPAWN_RATE", "10"))
    if min(delay, stop_before) < 0 or min(users, workers, spawn) <= 0 or workers > users:
        raise ValueError("Invalid warm-up, user count, worker count or spawn rate")
    slot = seconds + STARTUP_TIMEOUT + CLEANUP_MARGIN
    if delay + len(ENDPOINTS) * slot >= total - stop_before:
        raise ValueError("TOTAL_TIMEOUT must fit warm-up, one full three-scenario cycle "
                         "with startup/cleanup allowances, and LOCUST_STOP_BEFORE_END")
    return dict(scenarios=list(ENDPOINTS), duration=duration, duration_seconds=seconds,
                start_delay_seconds=delay, stop_before_end_seconds=stop_before,
                ingestion_seconds=total,
                users=users, workers=workers, spawn_rate=spawn)


def save(state):
    temporary = ARTIFACT.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(ARTIFACT)


def read_result(log, scenario, config):
    """Require the final summary, rather than treating a successful log stream as a pass."""
    shutdown = list(re.finditer(r"\[([^]]+)\].*Shutting down \(exit code (\d+)\)", log))
    if not shutdown:
        raise ValueError("Locust did not report shutdown")
    final = log[shutdown[-1].end():]
    endpoint = re.escape(ENDPOINTS[scenario])
    row = re.search(r"^GET\s+" + endpoint + r"\s+(\d+)\s+(\d+)\([^)]*\)\s*\|"
                    r"\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\|\s*([\d.]+)", final, re.M)
    aggregate = re.search(r"^\s+Aggregated\s+(\d+)\s+(\d+)\(", final, re.M)
    if not row or int(row[1]) == 0 or not aggregate:
        raise ValueError("Locust has no final request summary for the selected endpoint")
    spawned = re.findall(r"All users spawned:.*\((\d+) total users\)", log)
    if not spawned or int(spawned[-1]) != config["users"]:
        raise ValueError("Locust did not reach the configured user count")
    start = re.search(r"\[([^]]+)\].*Run time limit set to (\d+) seconds", log)
    if not start or int(start[2]) != config["duration_seconds"]:
        raise ValueError("Locust did not confirm the configured duration")
    # Locust container timestamps use UTC. Retain the actual read window for overlap checks.
    started = datetime.strptime(start[1], "%Y-%m-%d %H:%M:%S,%f").replace(tzinfo=timezone.utc)
    ended = datetime.strptime(shutdown[-1][1], "%Y-%m-%d %H:%M:%S,%f").replace(tzinfo=timezone.utc)
    if (ended - started).total_seconds() < config["duration_seconds"] - 2:
        raise ValueError("Locust stopped before the configured duration")
    percentiles = re.search(
        r"^GET\s+" + endpoint + r"\s+((?:[\d.]+\s+){10}[\d.]+)\s+(\d+)\s*$", final, re.M)
    latency = dict(mean=float(row[3]), min=float(row[4]), max=float(row[5]), median=float(row[6]))
    if percentiles:
        names = ("p50", "p66", "p75", "p80", "p90", "p95", "p98", "p99", "p99_9", "p99_99", "p100")
        latency.update(zip(names, map(float, percentiles[1].split())))
    return dict(read_started_at=started.isoformat(), read_ended_at=ended.isoformat(),
                requests=int(row[1]), failed_requests=int(row[2]),
                total_failed_requests=int(aggregate[2]), locust_exit_code=int(shutdown[-1][2]),
                requests_per_second=float(row[7]), latency_ms=latency)


def verify_overlap():
    state = json.loads(ARTIFACT.read_text())
    runs = json.loads(Path("benchmark-output.json").read_text())["pipelineruns"]
    created = [timestamp(run["creationTimestamp"]) for run in runs.values()
               if run.get("creationTimestamp")]
    for iteration in state["iterations"]:
        iteration["overlap_verified"] = bool(
            created and iteration.get("read_started_at") and iteration.get("read_ended_at")
            and min(created) <= timestamp(iteration["read_started_at"])
            < timestamp(iteration["read_ended_at"]) <= max(created)
            and timestamp(iteration["read_ended_at"]) <= timestamp(state["read_cutoff_at"])
        )
    state["overlap_verified"] = bool(state["iterations"]) and all(
        iteration["overlap_verified"] for iteration in state["iterations"])
    if not created:
        state.update(status="failed", error="No PipelineRun creation timestamps available to verify read overlap")
        save(state)
        raise ValueError(state["error"])
    state["first_pipeline_created_at"] = datetime.fromtimestamp(min(created), timezone.utc).isoformat()
    state["last_pipeline_created_at"] = datetime.fromtimestamp(max(created), timezone.utc).isoformat()
    if not state["overlap_verified"]:
        state.update(status="failed", error="A Locust iteration was incomplete or outside the observed ingestion/read window")
    save(state)
    if not state["overlap_verified"]:
        raise ValueError(state["error"])


def cleanup(child, scenario):
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    errors = []
    for resource, name in (("locusttest", scenario + "-test"),
                           ("configmap", "locust." + scenario)):
        try:
            subprocess.run(
                ["kubectl", "delete", "-n", "locust-operator", resource, name,
                 "--ignore-not-found=true", "--wait=false", "--request-timeout=5s"],
                timeout=10, check=True,
            )
        except (OSError, subprocess.SubprocessError):
            errors.append(resource)
    try:
        # An interrupted master must not leave worker pods reading during the next iteration.
        subprocess.run(
            ["kubectl", "delete", "pod", "-n", "locust-operator", "-l",
             f"locust.io/test-run={scenario}-test", "--ignore-not-found=true",
             "--wait=true", "--timeout=10s", "--request-timeout=5s"],
            timeout=15, check=True,
        )
    except (OSError, subprocess.SubprocessError):
        errors.append("pods")
    if errors:
        raise RuntimeError("Locust cleanup failed for: " + ", ".join(errors))


def run_iteration(scenario, iteration, config, cutoff, check_parent):
    log_path = Path(iteration["log"])
    log_path.write_text("")
    child = None
    iteration.update(status="running", launched_at=utc_now())
    try:
        env = dict(os.environ, LOCUST_SCENARIO=scenario, LOCUST_LOG=str(log_path),
                   LOCUST_DURATION=config["duration"], LOCUST_RUN_PHASE="concurrent")
        child = subprocess.Popen(
            ["bash", "-euo", "pipefail", "-c",
             'source ../../ci-scripts/lib.sh; source scenario/common/lib.sh; '
             'run_locust "$LOCUST_SCENARIO" '
             '"${LOCUST_HOST:-https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080}" '
             '"${LOCUST_USERS:-100}" "${LOCUST_SPAWN_RATE:-10}" '
             '"$LOCUST_DURATION" "${LOCUST_WORKERS:-5}" '
             '"${LOCUST_EXTRA_CMD:-} --expect-workers=${LOCUST_WORKERS:-5}"'],
            env=env, start_new_session=True,
        )
        launched = time.monotonic()
        deadline = min(cutoff - CLEANUP_MARGIN,
                       time.time() + STARTUP_TIMEOUT + config["duration_seconds"])
        while child.poll() is None:
            check_parent()
            if time.time() >= deadline:
                raise TimeoutError("Iteration exceeded its startup/runtime budget or read cutoff")
            if (time.monotonic() - launched >= STARTUP_TIMEOUT
                    and "Run time limit set to" not in log_path.read_text()):
                raise TimeoutError("Locust did not start within its startup allowance")
            time.sleep(0.5)
        iteration.update(read_result(log_path.read_text(), scenario, config))
        if child.returncode or iteration["locust_exit_code"] or iteration["total_failed_requests"]:
            iteration.update(status="failed", error="Locust reported failed requests or a nonzero exit")
        else:
            iteration["status"] = "completed"
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        iteration.update(status="incomplete", error=str(exc))
    finally:
        if iteration["status"] == "running":
            iteration.update(status="incomplete", error="Ingestion exited or coordinator was interrupted")
        try:
            cleanup(child, scenario)
        except RuntimeError as exc:
            iteration.update(status="failed", cleanup_error=str(exc))
            raise
        finally:
            iteration["coordinator_ended_at"] = utc_now()
            with LOG.open("a") as combined:
                combined.write(f"\n# Iteration {iteration['number']}: {scenario}\n")
                combined.write(log_path.read_text())


def run(config, parent_pid):
    state = dict(config, status="waiting", overlap_verified=False, iterations=[])

    def check_parent():
        if os.getppid() != parent_pid:
            raise RuntimeError("Ingestion process exited before concurrent reads completed")

    def interrupted(signum, _frame):
        raise RuntimeError(f"Concurrent read coordinator interrupted by signal {signum}")

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    save(state)
    LOG.write_text("")
    LOG_DIR.mkdir(exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
    try:
        namespace = "benchmark" if os.environ.get("TEST_NAMESPACE", "1") == "1" else "benchmark1"
        deadline = time.monotonic() + 300
        while True:
            check_parent()
            if time.monotonic() >= deadline:
                raise RuntimeError("No PipelineRun observed within 300 seconds")
            result = subprocess.run(
                ["kubectl", "get", "pipelineruns", "-n", namespace, "--request-timeout=10s",
                 "-o", "jsonpath={.items[*].metadata.creationTimestamp}"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, timeout=15, check=True,
            )
            created = result.stdout.split()
            if created:
                first = min(map(timestamp, created))
                break
            time.sleep(2)
        state["first_observed_pipeline_at"] = datetime.fromtimestamp(first, timezone.utc).isoformat()
        cutoff = first + config["ingestion_seconds"] - config["stop_before_end_seconds"]
        state["read_cutoff_at"] = datetime.fromtimestamp(cutoff, timezone.utc).isoformat()
        save(state)
        while time.time() < first + config["start_delay_seconds"]:
            check_parent()
            time.sleep(1)
        state["status"] = "running"
        for scenario in cycle(config["scenarios"]):
            check_parent()
            if time.time() + config["duration_seconds"] + STARTUP_TIMEOUT + CLEANUP_MARGIN >= cutoff:
                state["stop_reason"] = "Insufficient time for another full iteration before the read cutoff"
                break
            number = len(state["iterations"]) + 1
            iteration = dict(number=number, scenario=scenario, status="starting",
                             log=str(LOG_DIR / f"{run_id}-{number:03d}-{scenario}.log"))
            state["iterations"].append(iteration)
            save(state)
            run_iteration(scenario, iteration, config, cutoff, check_parent)
            save(state)
        seen = {iteration["scenario"] for iteration in state["iterations"]}
        state["status"] = "completed" if seen == set(config["scenarios"]) and all(
            iteration["status"] == "completed" for iteration in state["iterations"]) else "failed"
        if state["status"] == "failed":
            state["error"] = "One or more read iterations failed, were incomplete, or did not run"
    except Exception as exc:
        # Preserve failure state even for an unexpected runtime/programming error.
        state.update(status="failed", error=str(exc))
        raise
    finally:
        state["coordinator_ended_at"] = utc_now()
        save(state)
    if state["status"] != "completed":
        raise RuntimeError(state["error"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--verify-overlap", action="store_true")
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()
    try:
        if args.verify_overlap:
            verify_overlap()
        else:
            config = settings(os.environ)
            if not args.validate:
                if args.parent_pid is None:
                    raise ValueError("--parent-pid is required")
                run(config, args.parent_pid)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Concurrent Locust failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
