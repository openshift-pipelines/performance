"""Format comparison and benchmark results into structured JSON for LLM consumption."""

from collections import defaultdict
from datetime import datetime, timezone


def format_benchmark_data(all_benchmarks, config, version):
    """Structure benchmark results (single version) into the final output JSON."""
    thresholds = config["thresholds"]
    categories_config = config.get("categories", {})

    output = {
        "meta": {
            "mode": "benchmark",
            "version": version,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "runs_fetched": thresholds["default_runs"],
            "mad_threshold": thresholds["mad_threshold"],
        },
        "components": {},
    }

    for comp_name, comp_config in config["components"].items():
        comp_output = {
            "display_name": comp_config["display_name"],
            "variants": {},
        }
        group_label = comp_config.get("group_label")

        for var_name, var_config in comp_config["variants"].items():
            var_output = {
                "display_name": var_config["display_name"],
                "groups": {},
            }

            comp_benchmarks = all_benchmarks.get(comp_name, {})
            var_benchmarks = comp_benchmarks.get(var_name, {})

            for group_key, benchmark in sorted(var_benchmarks.items()):
                if group_label and group_key != "_all":
                    label = f"{group_key} {group_label}"
                else:
                    label = "all runs"

                categorized = defaultdict(dict)
                for metric_key, metric_data in benchmark["metrics"].items():
                    cat = metric_data["category"]
                    categorized[cat][metric_key] = {
                        k: v for k, v in metric_data.items() if k != "category"
                    }

                categories_output = {}
                for cat_key, cat_metrics in categorized.items():
                    cat_info = categories_config.get(cat_key, {})
                    categories_output[cat_key] = {
                        "display_name": cat_info.get("display_name", cat_key),
                        "description": cat_info.get("description", ""),
                        "metrics": cat_metrics,
                    }

                var_output["groups"][group_key] = {
                    "group_label": label,
                    "data_quality": benchmark["data_quality"],
                    "categories": categories_output,
                }

            comp_output["variants"][var_name] = var_output

        output["components"][comp_name] = comp_output

    return output


def format_comparison_data(all_comparisons, config, version_a, version_b):
    """Structure all comparison results into the final output JSON.

    Args:
        all_comparisons: {comp: {variant: {group_key: comparison_result}}}
        config: loaded config.yaml
        version_a: baseline version string
        version_b: comparison version string

    Returns:
        dict ready for JSON serialization
    """
    thresholds = config["thresholds"]
    categories_config = config.get("categories", {})

    output = {
        "meta": {
            "version_a": version_a,
            "version_b": version_b,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "runs_fetched": thresholds["default_runs"],
            "mad_threshold": thresholds["mad_threshold"],
            "significant_change_pct": thresholds["significant_change_pct"],
            "major_change_pct": thresholds["major_change_pct"],
        },
        "components": {},
        "summary": {},
    }

    global_improvements = []
    global_regressions = []

    for comp_name, comp_config in config["components"].items():
        comp_output = {
            "display_name": comp_config["display_name"],
            "variants": {},
        }
        group_label = comp_config.get("group_label")

        for var_name, var_config in comp_config["variants"].items():
            var_output = {
                "display_name": var_config["display_name"],
                "groups": {},
            }

            comp_comparisons = all_comparisons.get(comp_name, {})
            var_comparisons = comp_comparisons.get(var_name, {})

            for group_key, comparison in sorted(var_comparisons.items()):
                if group_label and group_key != "_all":
                    label = f"{group_key} {group_label}"
                else:
                    label = "all runs"

                categorized = defaultdict(dict)
                for metric_key, metric_data in comparison["metrics"].items():
                    cat = metric_data["category"]
                    categorized[cat][metric_key] = {
                        k: v for k, v in metric_data.items() if k != "category"
                    }

                    verdict = metric_data["verdict"]
                    if "improvement" in verdict:
                        global_improvements.append({
                            "component": comp_name,
                            "variant": var_name,
                            "group": group_key,
                            "metric": metric_data["display"],
                            "pct_change": metric_data["pct_change"],
                            "verdict": verdict,
                        })
                    elif "regression" in verdict:
                        global_regressions.append({
                            "component": comp_name,
                            "variant": var_name,
                            "group": group_key,
                            "metric": metric_data["display"],
                            "pct_change": metric_data["pct_change"],
                            "verdict": verdict,
                        })

                categories_output = {}
                for cat_key, cat_metrics in categorized.items():
                    cat_info = categories_config.get(cat_key, {})
                    categories_output[cat_key] = {
                        "display_name": cat_info.get("display_name", cat_key),
                        "description": cat_info.get("description", ""),
                        "metrics": cat_metrics,
                    }

                var_output["groups"][group_key] = {
                    "group_label": label,
                    "data_quality": comparison["data_quality"],
                    "categories": categories_output,
                }

            comp_output["variants"][var_name] = var_output

        output["components"][comp_name] = comp_output

    global_improvements.sort(key=lambda x: abs(x["pct_change"] or 0), reverse=True)
    global_regressions.sort(key=lambda x: abs(x["pct_change"] or 0), reverse=True)

    output["summary"] = {
        "top_improvements": global_improvements[:10],
        "top_regressions": global_regressions[:10],
        "total_improvements": len(global_improvements),
        "total_regressions": len(global_regressions),
    }

    return output
