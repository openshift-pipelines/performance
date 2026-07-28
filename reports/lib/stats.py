"""MAD-based outlier detection and version comparison statistics."""

import logging
from statistics import median, mean

logger = logging.getLogger(__name__)


def _mad(values):
    """Compute Median Absolute Deviation. Falls back to mean absolute deviation if MAD is 0."""
    med = median(values)
    abs_devs = [abs(v - med) for v in values]
    mad_val = median(abs_devs)
    if mad_val == 0:
        mad_val = mean(abs_devs) if abs_devs else 0
    return med, mad_val


def detect_outliers(runs, metric_keys, mad_threshold=2.5):
    """Flag metrics per run that deviate beyond mad_threshold * MAD.

    Returns dict: {run_index: set_of_flagged_metric_keys}
    """
    flags = {i: set() for i in range(len(runs))}

    for key in metric_keys:
        values = []
        for run in runs:
            v = run.get(key)
            if v is not None:
                try:
                    values.append(float(v))
                except (TypeError, ValueError):
                    values.append(None)
            else:
                values.append(None)

        numeric_vals = [v for v in values if v is not None]
        if len(numeric_vals) < 3:
            continue

        med, mad_val = _mad(numeric_vals)
        if mad_val == 0:
            continue

        for i, v in enumerate(values):
            if v is not None and abs(v - med) > mad_threshold * mad_val:
                flags[i].add(key)

    return flags


def exclude_outlier_runs(runs, metric_keys, mad_threshold=2.5,
                         outlier_ratio=0.5, min_runs=2):
    """Exclude runs flagged as outliers across too many metrics.

    Returns (surviving_runs, exclusion_info_list).
    """
    if len(runs) <= min_runs:
        return runs, []

    flags = detect_outliers(runs, metric_keys, mad_threshold)
    total_metrics = len([k for k in metric_keys if any(
        r.get(k) is not None for r in runs
    )])

    if total_metrics == 0:
        return runs, []

    survivors = []
    excluded = []
    for i, run in enumerate(runs):
        flagged_count = len(flags[i])
        ratio = flagged_count / total_metrics if total_metrics > 0 else 0
        if ratio > outlier_ratio:
            excluded.append({
                "run_index": i,
                "build_id": run.get("_build_id", "unknown"),
                "start": run.get("_start", "unknown"),
                "flagged_metrics": flagged_count,
                "total_metrics": total_metrics,
                "ratio": round(ratio, 2),
            })
        else:
            survivors.append(run)

    if len(survivors) < min_runs:
        logger.warning(
            "Only %d runs survive outlier exclusion (minimum %d). "
            "Keeping all runs.", len(survivors), min_runs
        )
        return runs, []

    return survivors, excluded


def compute_mean(runs, metric_key):
    """Compute mean of a metric across runs, skipping None values."""
    values = []
    for run in runs:
        v = run.get(metric_key)
        if v is not None:
            try:
                values.append(float(v))
            except (TypeError, ValueError):
                pass
    if not values:
        return None
    return mean(values)


def pct_change(old, new):
    """Compute percentage change. Returns None if old is 0 or None."""
    if old is None or new is None or old == 0:
        return None
    return ((new - old) / abs(old)) * 100


def classify_change(pct, lower_is_better, significant_pct=5, major_pct=15):
    """Classify a percentage change as improvement, regression, or stable."""
    if pct is None:
        return "no_data"

    abs_pct = abs(pct)
    if abs_pct < significant_pct:
        return "stable"

    if lower_is_better:
        is_improvement = pct < 0
    else:
        is_improvement = pct > 0

    if abs_pct >= major_pct:
        return "major_improvement" if is_improvement else "major_regression"
    return "improvement" if is_improvement else "regression"


def compute_benchmark(runs, metrics_config, thresholds):
    """Compute benchmark statistics for a single version (no comparison).

    Returns dict with per-metric mean values and data quality info.
    """
    metric_keys = [m["key"] for m in metrics_config]

    survivors, excluded = exclude_outlier_runs(
        runs, metric_keys,
        mad_threshold=thresholds["mad_threshold"],
        outlier_ratio=thresholds["outlier_metric_ratio"],
        min_runs=thresholds["min_runs_after_exclusion"],
    )

    data_quality = {
        "total_runs": len(runs),
        "used_runs": len(survivors),
        "excluded": excluded,
    }

    metric_results = {}
    for m in metrics_config:
        key = m["key"]
        mean_val = compute_mean(survivors, key)
        values = []
        for r in survivors:
            v = r.get(key)
            if v is not None:
                try:
                    values.append(float(v))
                except (TypeError, ValueError):
                    pass
        min_val = min(values) if values else None
        max_val = max(values) if values else None

        metric_results[key] = {
            "display": m["display"],
            "unit": m["unit"],
            "category": m["category"],
            "lower_is_better": m["lower_is_better"],
            "mean": round(mean_val, 4) if mean_val is not None else None,
            "min": round(min_val, 4) if min_val is not None else None,
            "max": round(max_val, 4) if max_val is not None else None,
        }

    return {
        "data_quality": data_quality,
        "metrics": metric_results,
    }


def compute_comparison(runs_a, runs_b, metrics_config, thresholds):
    """Compare two sets of runs across all configured metrics.

    Returns dict with per-metric comparison results and data quality info.
    """
    metric_keys = [m["key"] for m in metrics_config]

    survivors_a, excluded_a = exclude_outlier_runs(
        runs_a, metric_keys,
        mad_threshold=thresholds["mad_threshold"],
        outlier_ratio=thresholds["outlier_metric_ratio"],
        min_runs=thresholds["min_runs_after_exclusion"],
    )
    survivors_b, excluded_b = exclude_outlier_runs(
        runs_b, metric_keys,
        mad_threshold=thresholds["mad_threshold"],
        outlier_ratio=thresholds["outlier_metric_ratio"],
        min_runs=thresholds["min_runs_after_exclusion"],
    )

    data_quality = {
        "version_a": {
            "total_runs": len(runs_a),
            "used_runs": len(survivors_a),
            "excluded": excluded_a,
        },
        "version_b": {
            "total_runs": len(runs_b),
            "used_runs": len(survivors_b),
            "excluded": excluded_b,
        },
    }

    metric_results = {}
    for m in metrics_config:
        key = m["key"]
        mean_a = compute_mean(survivors_a, key)
        mean_b = compute_mean(survivors_b, key)
        pct = pct_change(mean_a, mean_b)
        verdict = classify_change(
            pct, m["lower_is_better"],
            thresholds["significant_change_pct"],
            thresholds["major_change_pct"],
        )
        metric_results[key] = {
            "display": m["display"],
            "unit": m["unit"],
            "category": m["category"],
            "lower_is_better": m["lower_is_better"],
            "version_a": round(mean_a, 4) if mean_a is not None else None,
            "version_b": round(mean_b, 4) if mean_b is not None else None,
            "pct_change": round(pct, 2) if pct is not None else None,
            "verdict": verdict,
        }

    return {
        "data_quality": data_quality,
        "metrics": metric_results,
    }
