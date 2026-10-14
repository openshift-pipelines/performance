#!/usr/bin/env python3
"""Check newly inserted Prow rows against PostgreSQL alert YAML bounds.

The collector writes one JSON line per new row to --manifest. Existing rows are
never re-alerted. Print a complete report and optionally write one notification
per Prow build for Jenkins to send.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
from dataclasses import dataclass
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONFIG_ROOT = ROOT / "tools" / "horreum"

# These IDs are the same per-variant IDs used by prow-to-storage.py.
CONFIG_BY_TEST_ID = {
    419: "pipelines/ha_deployement.yaml",
    420: "pipelines/ha_qbt.yaml",
    421: "pipelines/ha_statefulsets.yaml",
    422: "pipelines/qbt_deployement.yaml",
    423: "pipelines/standard.yaml",
    425: "results/standard.yaml",
    427: "chains/standard.yaml",
    428: "chains/ha.yaml",
    429: "chains/qbt.yaml",
    430: "chains/ha_qbt.yaml",
    437: "resolvers/standard.yaml",
    438: "resolvers/ha.yaml",
}


@dataclass(frozen=True)
class Finding:
    metric: str
    current: float
    reference: str
    direction: str | None
    kind: str


def numeric(value):
    """Return a finite metric value, or None for absent/non-numeric labels."""
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def label_text(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def load_rules(test_id, config_root=CONFIG_ROOT):
    try:
        path = config_root / CONFIG_BY_TEST_ID[test_id]
    except KeyError as exc:
        raise ValueError(f"No safe-bounds configuration for test ID {test_id}") from exc
    config = yaml.safe_load(path.read_text())
    defaults = config["change_detection_defaults"]
    groups = config["change_detection_groups"]
    rules = []
    seen_metrics = set()
    for group_name, group in groups.items():
        metrics = group.get("metrics")
        if not isinstance(metrics, list) or not metrics:
            raise ValueError(f"{path}: group {group_name!r} needs a nonempty metrics list")
        for metric in metrics:
            if not isinstance(metric, str) or not metric:
                raise ValueError(f"{path}: group {group_name!r} has an invalid metric name")
            if metric in seen_metrics:
                raise ValueError(f"{path}: metric {metric!r} appears in multiple groups")
            seen_metrics.add(metric)
            rules.append((metric, {
                "model": group.get("model", defaults["model"]),
                "threshold": group.get("threshold", defaults.get("threshold")),
                "window": group.get("window", defaults.get("window", 10)),
                "min_previous": group.get("min_previous", defaults.get("min_previous", 5)),
                "fixed_threshold": group.get("fixed_threshold"),
            }))
    return config["test"]["fingerprintLabels"], rules


def fixed_breach(value, bound):
    if bound.get("min_enabled"):
        minimum = float(bound["min_value"])
        if value < minimum or (value == minimum and not bound.get("min_inclusive", True)):
            return f"below minimum {minimum:g}"
    if bound.get("max_enabled"):
        maximum = float(bound["max_value"])
        if value > maximum or (value == maximum and not bound.get("max_inclusive", True)):
            return f"above maximum {maximum:g}"
    return None


def evaluate(labels, history, rules):
    """Compare each monitored metric to a fixed bound or recent-run median."""
    findings = []
    missing = insufficient = checked = 0
    for metric, rule in rules:
        current = numeric(labels.get("__" + metric))
        if current is None:
            missing += 1
            continue
        checked += 1
        if rule["model"] == "fixedThreshold":
            breach = fixed_breach(current, rule["fixed_threshold"])
            if breach:
                findings.append(Finding(metric, current, breach, None, "BOUND"))
        elif rule["model"] == "relativeDifference":
            previous = [numeric(row.get("__" + metric)) for row in history]
            previous = [value for value in previous if value is not None][:rule["window"]]
            if len(previous) < rule["min_previous"]:
                insufficient += 1
                continue
            baseline = statistics.median(previous)
            direction = "up" if current > baseline else "down" if current < baseline else "unchanged"
            if baseline == 0:
                significant = current != 0
                reference = "from zero baseline"
            else:
                change = (current - baseline) / abs(baseline)
                significant = abs(change) > rule["threshold"]
                reference = f"{abs(change):.1%} vs median {baseline:.4g} (limit {rule['threshold']:.0%})"
            if significant:
                findings.append(Finding(metric, current, reference, direction, "CHANGE"))
        else:
            raise ValueError(f"Unsupported change detection model: {rule['model']}")
    return findings, checked, missing, insufficient


def comparable_rows(conn, test_id, subjob_id, fingerprints, window):
    """Fetch this row and earlier rows with the same workload fingerprint.

    A current row with a missing fingerprint has no safe historical baseline.
    Nightly runs stay separate from release runs. Resolver types must match too;
    missing resolver-type provenance is not a safe comparison baseline.
    """
    with conn.cursor() as cursor:
        cursor.execute(
            "SELECT start, label_values FROM data "
            "WHERE horreum_testid = %s "
            "AND label_values->>'__metadata_env_SUBJOB_BUILD_ID' = %s "
            "ORDER BY start DESC LIMIT 1",
            (test_id, subjob_id),
        )
        current = cursor.fetchone()
        if current is None:
            raise ValueError(f"Inserted row not found: test={test_id}, subjob={subjob_id}")
        started, labels = current
        if any(not label_text(labels.get("__" + name)) for name in fingerprints):
            return labels, []
        if test_id in (437, 438) and not label_text(labels.get("__resolver_type")):
            return labels, []
        clauses = [
            "horreum_testid = %s", "start < %s",
            "COALESCE(label_values->>'__deployment_nightly', 'false') = %s",
        ]
        params = [test_id, started, label_text(labels.get("__deployment_nightly")) or "false"]
        for name in fingerprints:
            value = label_text(labels.get("__" + name))
            clauses.append("label_values->>%s = %s")
            params.extend(("__" + name, value))
        if test_id in (437, 438):
            clauses.append("label_values->>'__resolver_type' = %s")
            params.append(label_text(labels["__resolver_type"]))
        # Allow missing metric values in recent rows without exhausting the
        # baseline. Every metric still uses at most its configured window.
        params.append(window * 3)
        cursor.execute(
            "SELECT label_values FROM data WHERE " + " AND ".join(clauses)
            + " ORDER BY start DESC LIMIT %s", params,
        )
        return labels, [row[0] for row in cursor.fetchall()]


def read_manifest(path):
    items = []
    seen = set()
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        key = (int(item["test_id"]), str(item["subjob_id"]))
        if key not in seen:
            items.append({
                "test_id": key[0], "subjob_id": key[1], "prow_run": item["prow_run"],
                # Older manually prepared manifests only have subjob_id. Prow
                # subjob IDs start with their parent build ID.
                "prow_run_id": str(item.get("prow_run_id") or key[1].split("run-", 1)[0]),
            })
            seen.add(key)
    return items


def check_items(conn, items, config_root=CONFIG_ROOT):
    summaries = []
    for item in items:
        fingerprints, rules = load_rules(item["test_id"], config_root)
        window = max(rule["window"] for _, rule in rules)
        labels, history = comparable_rows(
            conn, item["test_id"], item["subjob_id"], fingerprints, window,
        )
        findings, checked, missing, insufficient = evaluate(labels, history, rules)
        summaries.append((item, findings, checked, missing, insufficient, len(history)))
    return summaries


def format_finding(finding):
    detail = finding.reference
    if finding.direction is not None:
        detail = f"{finding.direction}; {detail}"
    return f"  [{finding.kind}] {finding.metric}: {finding.current:.4g} ({detail})"


def format_summary(summaries, build_url="", collection_errors=0):
    total_findings = sum(len(row[1]) for row in summaries)
    header = f"Prow performance check: {len(summaries)} new row(s), {total_findings} alert(s)"
    lines = [header]
    if build_url:
        lines.append(build_url)
    if collection_errors:
        lines.append(f"Collection had {collection_errors} failed listing(s) or upload(s); results may be partial.")
    for item, findings, checked, missing, insufficient, history_size in summaries:
        lines.append(
            f"{item['prow_run']} / {item['subjob_id']}: {len(findings)} alert(s); "
            f"{checked} metrics checked, {missing} missing, "
            f"{insufficient} without enough history, {history_size} comparable run(s)"
        )
        for finding in findings:
            lines.append(format_finding(finding))
    if not summaries:
        lines.append("No new PostgreSQL rows were inserted in this collection run.")
    return "\n".join(lines)


def build_notifications(summaries, build_url="", collection_errors=0):
    """Return one Slack message per alerting Prow job/build."""
    grouped = {}
    for row in summaries:
        item = row[0]
        key = (item["prow_run"], item["prow_run_id"])
        grouped.setdefault(key, []).append(row)

    notifications = []
    for (prow_run, prow_run_id), rows in grouped.items():
        total_findings = sum(len(row[1]) for row in rows)
        if not total_findings:
            continue
        lines = [
            f"Prow performance check: {prow_run} / {prow_run_id}: "
            f"{len(rows)} new row(s), {total_findings} alert(s)"
        ]
        if build_url:
            lines.append(build_url)
        for item, findings, checked, missing, insufficient, history_size in rows:
            lines.append(
                f"{item['subjob_id']}: {len(findings)} alert(s); "
                f"{checked} metrics checked, {missing} missing, "
                f"{insufficient} without enough history, {history_size} comparable run(s)"
            )
            for finding in findings:
                lines.append(format_finding(finding))
        notifications.append({
            "prow_run": prow_run,
            "prow_run_id": prow_run_id,
            "message": "\n".join(lines),
        })
    if collection_errors:
        message = (
            f"Prow performance collection had {collection_errors} failed listing(s) "
            f"or upload(s); results may be partial."
        )
        if build_url:
            message += f"\n{build_url}"
        notifications.append({"message": message})
    return notifications


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--collection-errors", type=int, default=0)
    parser.add_argument("--output", type=Path, help="write the complete report")
    parser.add_argument(
        "--notifications-json", type=Path,
        help="write a JSON array of per-Prow-build Slack messages for Jenkins",
    )
    args = parser.parse_args()
    items = read_manifest(args.manifest)
    summaries = []
    if items:
        import psycopg2

        required = (
            "POSTGRES_PIPELINE_DB_HOST", "POSTGRES_PIPELINE_DB_USER",
            "POSTGRES_PIPELINE_DB_NAME", "POSTGRES_PIPELINE_DB_PASSWORD",
        )
        missing = [name for name in required if not os.environ.get(name)]
        if missing:
            parser.error("Missing PostgreSQL environment variables: " + ", ".join(missing))
        conn = psycopg2.connect(
            host=os.environ["POSTGRES_PIPELINE_DB_HOST"],
            port=os.environ.get("POSTGRES_PIPELINE_DB_PORT", "5432"),
            user=os.environ["POSTGRES_PIPELINE_DB_USER"],
            dbname=os.environ["POSTGRES_PIPELINE_DB_NAME"],
            password=os.environ["POSTGRES_PIPELINE_DB_PASSWORD"],
        )
        try:
            conn.set_session(readonly=True, autocommit=True)
            summaries = check_items(conn, items)
        finally:
            conn.close()
    report = format_summary(summaries, os.environ.get("BUILD_URL", ""), args.collection_errors)
    print(report)
    if args.output:
        args.output.write_text(report + "\n", encoding="utf-8")
    if args.notifications_json:
        notifications = build_notifications(
            summaries, os.environ.get("BUILD_URL", ""), args.collection_errors,
        )
        args.notifications_json.write_text(json.dumps(notifications) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
