#!/usr/bin/env python3
"""Generate performance report data for OpenShift Pipelines versions.

Supports three modes:
    comparison  — compare two released versions (default when --version-b given)
    benchmark   — single-version metric snapshot (default when only --version-a)

Usage:
    # Set DB connection via environment variables:
    export POSTGRES_PIPELINE_DB_HOST="your-db-host"
    export POSTGRES_PIPELINE_DB_USER="your-db-user"
    export POSTGRES_PIPELINE_DB_NAME="your-db-name"
    export POSTGRES_PIPELINE_DB_PASSWORD="your-db-password"

    # Comparison:
    python generate_comparison.py --version-a 1.22 --version-b 1.23

    # Nightly comparison:
    python generate_comparison.py --version-a 1.23 --version-b nightly

    # Benchmark (single version):
    python generate_comparison.py --version-a 1.23
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path

import yaml

SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from lib.stats import compute_comparison, compute_benchmark
from lib.formatter import format_comparison_data, format_benchmark_data

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


def load_config():
    config_path = SCRIPT_DIR / "config.yaml"
    with open(config_path) as f:
        return yaml.safe_load(f)


def fetch_from_db(args, config, version_a, version_b):
    """Connect to PostgreSQL in READ-ONLY mode and fetch all data."""
    try:
        import psycopg2
    except ImportError:
        logger.error("psycopg2 not installed. Run: pip install psycopg2-binary")
        sys.exit(1)

    password = os.environ.get(args.db_password_env, "")
    if not password and args.db_password_env:
        logger.warning("Environment variable %s not set", args.db_password_env)

    conn = psycopg2.connect(
        host=args.db_host,
        port=args.db_port,
        dbname=args.db_name,
        user=args.db_user,
        password=password,
        sslmode=args.db_sslmode,
    )

    from lib.db import make_readonly_connection, fetch_all_data
    make_readonly_connection(conn)
    logger.info("Connected (READ ONLY) to %s:%s/%s", args.db_host, args.db_port, args.db_name)

    try:
        data = fetch_all_data(conn, config, version_a, version_b, args.runs)
    finally:
        conn.close()
    return data


def process_comparison(raw_data, config):
    """Run outlier detection and compute comparisons for all component/variant/group combos."""
    thresholds = config["thresholds"]
    all_comparisons = {}

    for comp_name, comp_config in config["components"].items():
        all_comparisons[comp_name] = {}
        metrics_config = comp_config["metrics"]

        comp_data = raw_data.get(comp_name, {})

        for var_name in comp_config["variants"]:
            var_data = comp_data.get(var_name, {})
            all_comparisons[comp_name][var_name] = {}

            groups_a = var_data.get("version_a", {})
            groups_b = var_data.get("version_b", {})
            all_groups = sorted(set(list(groups_a.keys()) + list(groups_b.keys())))

            for group_key in all_groups:
                runs_a = groups_a.get(group_key, [])
                runs_b = groups_b.get(group_key, [])

                if not runs_a and not runs_b:
                    continue

                comparison = compute_comparison(
                    runs_a, runs_b, metrics_config, thresholds,
                )
                all_comparisons[comp_name][var_name][group_key] = comparison

                logger.info(
                    "  %s / %s / %s: %d vs %d runs (%d vs %d after outlier exclusion)",
                    comp_name, var_name, group_key,
                    len(runs_a), len(runs_b),
                    comparison["data_quality"]["version_a"]["used_runs"],
                    comparison["data_quality"]["version_b"]["used_runs"],
                )

    return all_comparisons


def process_benchmark(raw_data, config):
    """Run outlier detection and compute benchmark stats for single-version data."""
    thresholds = config["thresholds"]
    all_benchmarks = {}

    for comp_name, comp_config in config["components"].items():
        all_benchmarks[comp_name] = {}
        metrics_config = comp_config["metrics"]

        comp_data = raw_data.get(comp_name, {})

        for var_name in comp_config["variants"]:
            var_data = comp_data.get(var_name, {})
            all_benchmarks[comp_name][var_name] = {}

            groups = var_data.get("version_a", {})

            for group_key in sorted(groups.keys()):
                runs = groups.get(group_key, [])
                if not runs:
                    continue

                benchmark = compute_benchmark(runs, metrics_config, thresholds)
                all_benchmarks[comp_name][var_name][group_key] = benchmark

                logger.info(
                    "  %s / %s / %s: %d runs (%d after outlier exclusion)",
                    comp_name, var_name, group_key,
                    len(runs),
                    benchmark["data_quality"]["used_runs"],
                )

    return all_benchmarks


def print_comparison_summary(output):
    """Print a human-readable summary of comparison findings."""
    summary = output["summary"]
    meta = output["meta"]

    print(f"\n{'='*70}")
    print(f"Performance Comparison: v{meta['version_a']} vs v{meta['version_b']}")
    print(f"{'='*70}")
    print(f"Total improvements: {summary['total_improvements']}")
    print(f"Total regressions:  {summary['total_regressions']}")

    if summary["top_improvements"]:
        print(f"\nTop Improvements:")
        for item in summary["top_improvements"][:5]:
            print(f"  {item['pct_change']:+.1f}%  {item['metric']}"
                  f"  ({item['component']}/{item['variant']}/{item['group']})")

    if summary["top_regressions"]:
        print(f"\nTop Regressions:")
        for item in summary["top_regressions"][:5]:
            print(f"  {item['pct_change']:+.1f}%  {item['metric']}"
                  f"  ({item['component']}/{item['variant']}/{item['group']})")

    print(f"{'='*70}\n")


def print_benchmark_summary(output):
    """Print a human-readable summary of benchmark results."""
    meta = output["meta"]

    print(f"\n{'='*70}")
    print(f"Performance Benchmark: v{meta['version']}")
    print(f"{'='*70}")

    for comp_name, comp_data in output["components"].items():
        print(f"\n  {comp_data['display_name']}:")
        for var_name, var_data in comp_data["variants"].items():
            for group_key, group_data in var_data["groups"].items():
                dq = group_data["data_quality"]
                print(f"    {var_data['display_name']} / {group_data['group_label']}: "
                      f"{dq['used_runs']}/{dq['total_runs']} runs used")

    print(f"{'='*70}\n")


def determine_mode(args):
    """Determine operating mode from CLI arguments."""
    if args.version_b is None:
        return "benchmark"
    return "comparison"


def main():
    parser = argparse.ArgumentParser(
        description="Generate performance report for OpenShift Pipelines versions."
    )
    parser.add_argument("--version-a", required=True,
                        help="Version to analyze (e.g. 1.23)")
    parser.add_argument("--version-b", default=None,
                        help="Comparison version (e.g. 1.22, or 'nightly'). "
                             "Omit for benchmark mode.")
    parser.add_argument("--runs", type=int, default=None,
                        help="Number of recent runs to fetch per version "
                             "(default: from config.yaml)")
    parser.add_argument("--output", default=str(SCRIPT_DIR / "output"),
                        help="Output directory")

    # DB connection args — all default to environment variables
    parser.add_argument("--db-host", default=os.environ.get("POSTGRES_PIPELINE_DB_HOST", ""),
                        help="PostgreSQL host (env: POSTGRES_PIPELINE_DB_HOST)")
    parser.add_argument("--db-port", type=int,
                        default=int(os.environ.get("POSTGRES_PIPELINE_DB_PORT", "5432")),
                        help="PostgreSQL port (env: POSTGRES_PIPELINE_DB_PORT)")
    parser.add_argument("--db-name", default=os.environ.get("POSTGRES_PIPELINE_DB_NAME", ""),
                        help="Database name (env: POSTGRES_PIPELINE_DB_NAME)")
    parser.add_argument("--db-sslmode", default=os.environ.get("POSTGRES_PIPELINE_DB_SSLMODE", "prefer"),
                        help="SSL mode (env: POSTGRES_PIPELINE_DB_SSLMODE)")
    parser.add_argument("--db-user", default=os.environ.get("POSTGRES_PIPELINE_DB_USER", ""),
                        help="Database user (env: POSTGRES_PIPELINE_DB_USER)")
    parser.add_argument("--db-password-env", default="POSTGRES_PIPELINE_DB_PASSWORD",
                        help="Environment variable containing DB password")

    args = parser.parse_args()
    config = load_config()

    runs = args.runs if args.runs is not None else config["thresholds"]["default_runs"]
    args.runs = runs
    config["thresholds"]["default_runs"] = runs

    mode = determine_mode(args)
    version_a = args.version_a
    version_b = args.version_b

    logger.info("Mode: %s | version_a=%s | version_b=%s | runs=%d",
                mode, version_a, version_b or "(none)", runs)

    # Fetch data
    if not args.db_host:
        logger.error("--db-host is required. Set POSTGRES_PIPELINE_DB_HOST or pass --db-host.")
        sys.exit(1)

    raw_data = fetch_from_db(args, config, version_a, version_b)

    # Process + format based on mode
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    version_suffix = (f"v{version_a}_vs_v{version_b}" if mode == "comparison"
                      else f"v{version_a}")

    # Save raw DB data for QE validation
    raw_file = output_dir / f"raw_data_{version_suffix}.json"
    with open(raw_file, "w") as f:
        json.dump(raw_data, f, indent=2, default=str)
    logger.info("Raw DB data saved to %s", raw_file)

    if mode == "comparison":
        logger.info("Processing comparison data with MAD outlier detection...")
        all_comparisons = process_comparison(raw_data, config)

        mad_file = output_dir / f"mad_analysis_{version_suffix}.json"
        with open(mad_file, "w") as f:
            json.dump(all_comparisons, f, indent=2, default=str)
        logger.info("MAD analysis saved to %s", mad_file)

        output = format_comparison_data(all_comparisons, config, version_a, version_b)
        output_file = output_dir / f"comparison_v{version_a}_vs_v{version_b}.json"
        prompt_name = "prompt_template.md"
        print_comparison_summary(output)
    else:
        logger.info("Processing benchmark data with MAD outlier detection...")
        all_benchmarks = process_benchmark(raw_data, config)

        mad_file = output_dir / f"mad_analysis_{version_suffix}.json"
        with open(mad_file, "w") as f:
            json.dump(all_benchmarks, f, indent=2, default=str)
        logger.info("MAD analysis saved to %s", mad_file)

        output = format_benchmark_data(all_benchmarks, config, version_a)
        output_file = output_dir / f"benchmark_v{version_a}.json"
        prompt_name = "prompt_template_benchmark.md"
        print_benchmark_summary(output)

    with open(output_file, "w") as f:
        json.dump(output, f, indent=2, default=str)
    logger.info("Output written to %s", output_file)

    # Copy prompt template alongside output
    prompt_src = SCRIPT_DIR / prompt_name
    if prompt_src.exists():
        prompt_dst = output_dir / prompt_name
        prompt_dst.write_text(prompt_src.read_text())
        logger.info("Prompt template copied to %s", prompt_dst)
        print(f"Next step: Feed {output_file} + {prompt_dst} to your LLM to generate the article.")
    else:
        logger.warning("Prompt template %s not found", prompt_src)


if __name__ == "__main__":
    main()
