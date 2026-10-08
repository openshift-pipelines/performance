#!/usr/bin/env python3
"""Download one Prow artifact and store its labels and Dashboard result.

compute_labels.py reads a local schema, and labels_to_postgresql.py writes the
existing data table. Neither tool needs a Horreum API or token.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import requests

ROOT = Path(__file__).resolve().parents[1]
LABEL_SCHEMA = ROOT / "config" / "benchmark-label-schema.json"
SCHEMA_URI = json.loads(LABEL_SCHEMA.read_text())["uri"]
CHECK_LABEL = "__metadata_env_SUBJOB_BUILD_ID"

# Preserve IDs used by the existing reports and Grafana queries.
PIPELINES = {
    "": (423, "standard", "standard"),
    "-ha-10": (419, "ha-10", "ha_deployement"),
    "-ha-10-state": (421, "ha-10-state", "ha_statefulsets"),
    "-qbt": (422, "qbt", "qbt_deployement"),
    "-ha-10-qbt": (420, "ha-10-qbt", "ha_qbt"),
}
CHAINS = {
    "": (427, "standard", "standard"),
    "-ha-10": (428, "ha-10", "ha"),
    "-qbt": (429, "qbt", "qbt"),
    "-ha-10-qbt": (430, "ha-10-qbt", "ha_qbt"),
}
RESOLVERS = {
    "-gr": (437, "standard", "git-resolver"),
    "-br": (437, "standard", "bundle-resolver"),
    "-cr": (437, "standard", "cluster-resolver"),
    "-gr-ha-10": (438, "ha-10", "git-resolver"),
    "-br-ha-10": (438, "ha-10", "bundle-resolver"),
    "-cr-ha-10": (438, "ha-10", "cluster-resolver"),
    "-cr-ha-10-cache": (438, "ha-10-cache", "cluster-resolver"),
}


def job_metadata(prow_run: str) -> tuple[int, str, str, Optional[str], str]:
    """Return test ID, family, variant, resolver type, and expected test name."""
    if re.fullmatch(r"tkn-res-downstream-(?:nightly|pipelines1-\d+)", prow_run):
        return 425, "results", "standard", None, "Results Performance test-standard"

    prefix = "max-concurrency-downstream-"
    if not prow_run.startswith(prefix):
        raise ValueError(f"Unknown Prow run: {prow_run}")
    run = prow_run[len(prefix):]
    match = re.fullmatch(r"(?:nightly|(?:pipelines)?1-\d+)(-sign-tkn-bb)?(.*)", run)
    if not match:
        raise ValueError(f"Unknown Prow run: {prow_run}")
    chain, suffix = match.groups()
    if chain:
        try:
            test_id, variant, name_suffix = CHAINS[suffix]
        except KeyError as exc:
            raise ValueError(f"Unknown Prow variant: {prow_run}") from exc
        return test_id, "chains", variant, None, f"Chains signing test-{name_suffix}"
    if suffix in RESOLVERS:
        test_id, variant, resolver_type = RESOLVERS[suffix]
        test_name = "ha" if test_id == 438 else "standard"
        return test_id, "resolvers", variant, resolver_type, f"Resolvers Performance test-{test_name}"
    try:
        test_id, variant, name_suffix = PIPELINES[suffix]
    except KeyError as exc:
        raise ValueError(f"Unknown Prow variant: {prow_run}") from exc
    return test_id, "pipelines", variant, None, f"Scaling Pipelines test-{name_suffix}"


def prepare(document: dict, prow_run: str, prow_job: str, job_run_id: str, subjob: str):
    test_id, family, variant, resolver_type, expected_name = job_metadata(prow_run)
    if document["name"] != expected_name:
        raise ValueError(f"Unexpected test name {document['name']!r} for {prow_run}")

    started = datetime.fromisoformat(document["started"].replace("Z", "+00:00"))
    if started.utcoffset() != timedelta(0):
        raise ValueError("Prow start time must be UTC")
    run_id = int(started.strftime("%Y%m%d"))
    dataset_id = int(started.strftime("%H%M%S"))

    document["_storage"] = {
        "test_family": family,
        "test_variant": variant,
        "resolver_type": resolver_type,
        "prow_job": prow_job,
        "prow_run_id": job_run_id,
        "prow_subjob": subjob,
    }
    # The historical table has TIMESTAMP WITHOUT TIME ZONE; write UTC there.
    return document, test_id, run_id, dataset_id, started.replace(tzinfo=None).isoformat()


def mirror_command(mirror_dir: Path, script: str, *args: str) -> list[str]:
    if not (mirror_dir / script).is_file():
        raise ValueError(f"Missing {mirror_dir / script}")
    return ["uv", "run", "--locked", "--no-active", "python", script, *args]


def compute_labels(source: Path, labels_file: Path, mirror_dir: Path) -> dict:
    command = mirror_command(
        mirror_dir, "compute_labels.py", "--source", str(source),
        "--schema", str(LABEL_SCHEMA),
    )
    with labels_file.open("w") as output:
        subprocess.run(command, cwd=mirror_dir, stdout=output, check=True)
    with labels_file.open() as stream:
        labels = json.load(stream)
    if len({item["name"] for item in labels}) != len(labels):
        raise ValueError(f"{LABEL_SCHEMA}: duplicate label names")
    # Historical Horreum rows omit missing labels. Keep that JSONB shape so
    # dashboard queries using `label_values ? key` still work as before.
    labels = [item for item in labels if item["value"] is not None]
    values = {item["name"]: item["value"] for item in labels}
    if not values.get(CHECK_LABEL):
        raise ValueError(f"{source}: missing {CHECK_LABEL} label")
    labels_file.write_text(json.dumps(labels))
    return values


def connection_args() -> list[str]:
    keys = {
        "--postgresql-host": "POSTGRES_PIPELINE_DB_HOST",
        "--postgresql-user": "POSTGRES_PIPELINE_DB_USER",
        "--postgresql-pass": "POSTGRES_PIPELINE_DB_PASSWORD",
        "--postgresql-db": "POSTGRES_PIPELINE_DB_NAME",
    }
    missing = [env for env in keys.values() if not os.environ.get(env)]
    if missing:
        raise ValueError("Missing PostgreSQL environment variables: " + ", ".join(missing))
    args = [item for flag, env in keys.items() for item in (flag, os.environ[env])]
    args += ["--postgresql-port", os.environ.get("POSTGRES_PIPELINE_DB_PORT", "5432")]
    return args


def load_labels(labels_file: Path, mirror_dir: Path, test_id: int, run_id: int,
                dataset_id: int, started: str, subjob_id: str) -> str:
    db_args = connection_args()
    password = os.environ["POSTGRES_PIPELINE_DB_PASSWORD"]
    # First try IDs from the UTC start date/time. Negative IDs provide separate slots
    # if distinct artifacts with the same test ID start in the same second.
    for attempt in range(1000):
        candidate = dataset_id if attempt == 0 else -(dataset_id * 1000 + attempt)
        command = mirror_command(
            mirror_dir, "labels_to_postgresql.py",
            "--label-values", str(labels_file),
            "--horreum-test-id", str(test_id),
            "--horreum-run-id", str(run_id),
            "--horreum-dataset-id", str(candidate),
            "--start", started,
            "--check-label", CHECK_LABEL,
            *db_args,
        )
        result = subprocess.run(command, cwd=mirror_dir, text=True, capture_output=True)
        output = (result.stdout + result.stderr).replace(password, "***")
        if result.returncode == 0:
            return "inserted"
        if f"Data with {CHECK_LABEL}=" in output and "already exists" in output:
            return "already stored"
        if "Data for test=" in output and "already exists" in output:
            continue
        raise RuntimeError(f"PostgreSQL label load failed for {subjob_id}: {output.strip()}")
    raise RuntimeError(f"Could not allocate a dataset ID for {subjob_id}")


def download(url: str) -> dict | None:
    response = requests.get(url, timeout=60)
    if response.status_code == 404:
        print(f"No artifact at {url}, skipping")
        return None
    response.raise_for_status()
    try:
        document = response.json()
    except ValueError:
        print(f"Invalid JSON at {url}, skipping")
        return None
    if not isinstance(document, dict):
        raise ValueError(f"Expected a JSON object at {url}")
    document["jobLink"] = url
    return document


def enrich(document: dict, subjob: str) -> dict | None:
    results = document.get("results")
    if not isinstance(results, dict) or not results.get("started") or not results.get("ended"):
        print("Missing start or end time, skipping")
        return None

    env = document["metadata"]["env"]
    build_id = env["BUILD_ID"]
    if not isinstance(build_id, str) or not build_id:
        raise ValueError("Missing string metadata.env.BUILD_ID")
    document["started"] = results["started"]
    document["ended"] = results["ended"]
    env["SUBJOB_BUILD_ID"] = build_id + subjob
    document["$schema"] = SCHEMA_URI
    document["result"] = "PASS"
    return document


def dashboard_command(file: Path, base_url: str) -> list[str]:
    return [
        "shovel.py", "resultsdashboard", "--base-url", base_url, "upload",
        "--input-file", str(file), "--group", "Developer",
        "--product", "OpenShift Pipelines", "--test", "@name",
        "--result-id", "@metadata.env.SUBJOB_BUILD_ID",
        "--result", "@result", "--date", "@started", "--link", "@jobLink",
        "--release", "latest", "--version", datetime.now(timezone.utc).date().isoformat(),
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prow-logs-url", required=True)
    parser.add_argument("--prow-run", required=True)
    parser.add_argument("--prow-job", required=True)
    parser.add_argument("--job-run-id", required=True)
    parser.add_argument("--artifact-dir", required=True)
    parser.add_argument("--subjob", default="")
    parser.add_argument("--mirror-dir", type=Path, default=os.environ.get("HDM_DIR"))
    parser.add_argument(
        "--dashboard-url", default=os.environ.get(
            "ES_HOST", "http://elasticsearch.intlab.perf-infra.lab.eng.rdu2.redhat.com"
        )
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--show-label-values", action="store_true",
        help="print the PostgreSQL label_values object during a dry run",
    )
    args = parser.parse_args()
    if args.mirror_dir is None:
        parser.error("--mirror-dir or HDM_DIR is required")
    if args.show_label_values and not args.dry_run:
        parser.error("--show-label-values requires --dry-run")
    mirror_dir = Path(args.mirror_dir).resolve()

    artifact_path = f"{args.artifact_dir}{args.subjob + '/' if args.subjob else ''}benchmark-tekton.json"
    url = (
        f"{args.prow_logs_url.rstrip('/')}/{args.prow_job}/{args.job_run_id}"
        f"/artifacts/{args.prow_run}/{artifact_path}"
    )
    document = download(url)
    if document is None:
        return
    document = enrich(document, args.subjob)
    if document is None:
        return

    source, test_id, run_id, dataset_id, started = prepare(
        document, args.prow_run, args.prow_job, args.job_run_id, args.subjob
    )
    with tempfile.TemporaryDirectory(prefix="prow-labels-") as directory:
        source_file = Path(directory) / "benchmark.json"
        labels_file = Path(directory) / "labels.json"
        source_file.write_text(json.dumps(source))
        labels = compute_labels(source_file, labels_file, mirror_dir)
        subjob_id = str(labels[CHECK_LABEL])
        if args.dry_run:
            if args.show_label_values:
                print(f"DRY_RUN: artifact {url}")
                print("DRY_RUN: label_values " + json.dumps(labels, indent=2, sort_keys=True))
            print(
                f"DRY_RUN: would load {args.prow_run} {subjob_id} into data "
                f"(test_id={test_id}, run_id={run_id}, dataset_id={dataset_id}, "
                f"family={labels['__test_family']}, variant={labels['__test_variant']}, "
                f"schema={SCHEMA_URI}, labels={len(labels)})"
            )
            print(f"DRY_RUN: would upload to Results Dashboard (result ID: {subjob_id})")
            return

        result = load_labels(
            labels_file, mirror_dir, test_id, run_id, dataset_id, started, subjob_id
        )
        print(f"{result.capitalize()}: {args.prow_run} {subjob_id}")
        subprocess.run(dashboard_command(source_file, args.dashboard_url), check=True)


if __name__ == "__main__":
    main()
