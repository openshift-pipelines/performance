# Performance Report Generator

Automated pipeline for generating Red Hat KB-style performance articles for OpenShift Pipelines. Fetches data from a PostgreSQL database containing performance test results, applies statistical normalization, and produces a structured JSON that an LLM turns into a publishable markdown article.

## Quick Start

```bash
cd reports/

# Setup
python3 -m venv ../venv
source ../venv/bin/activate
pip install psycopg2-binary pyyaml

# Set DB connection via environment variables
export POSTGRES_PIPELINE_DB_HOST="your-db-host"
export POSTGRES_PIPELINE_DB_USER="your-db-user"
export POSTGRES_PIPELINE_DB_NAME="your-db-name"
export POSTGRES_PIPELINE_DB_PASSWORD="your-db-password"

# Generate comparison data
python generate_comparison.py --version-a 1.22 --version-b 1.23
```

This produces `output/comparison_v1.22_vs_v1.23.json` and copies the prompt templates alongside it (KB article template + regression report template).

## Pipeline Overview

```
┌─────────────────────────┐      ┌─────────────────────────┐
│  generate_comparison.py │      │   Your LLM of choice    │
│                         │      │                         │
│  PostgreSQL ──► JSON    │ ───► │  JSON + Prompt ──► .md  │
│  (fetch, normalize,     │      │  (Claude, ChatGPT, etc) │
│   compare/benchmark)    │      │                         │
└─────────────────────────┘      └─────────────────────────┘
```

**Stage 1** (`generate_comparison.py`) connects to the database (read-only), fetches the last N runs per version, excludes outlier runs using MAD (Median Absolute Deviation), computes means and percentage changes, and writes a structured JSON file. It also saves intermediate artifacts (`raw_data_*.json` and `mad_analysis_*.json`) so QE teams can cross-verify the analysis against source data. A prompt template is copied alongside the output.

**Stage 2** (manual): Feed the JSON and a prompt template into your preferred LLM (Claude, ChatGPT, or any other) to generate the report. Use `prompt_template.md` for the customer-facing KB article, or `prompt_template_internal_detailed_regression.md` for the internal detailed regression report.

## Environment Variables

All database connection details are configured via environment variables to avoid exposing infrastructure details:

| Variable | Required | Description |
|----------|----------|-------------|
| `POSTGRES_PIPELINE_DB_HOST` | Yes | PostgreSQL host |
| `POSTGRES_PIPELINE_DB_USER` | Yes | Database user |
| `POSTGRES_PIPELINE_DB_NAME` | Yes | Database name |
| `POSTGRES_PIPELINE_DB_PASSWORD` | Yes | Database password |
| `POSTGRES_PIPELINE_DB_PORT` | No | PostgreSQL port (default: `5432`) |
| `POSTGRES_PIPELINE_DB_SSLMODE` | No | SSL mode (default: `prefer`) |

All values can also be passed as CLI arguments (`--db-host`, `--db-user`, etc.) which override the environment variables.

## Modes

### 1. Version Comparison (default)

Compare two released versions side by side.

```bash
python generate_comparison.py --version-a 1.22 --version-b 1.23
```

Output: `output/comparison_v1.22_vs_v1.23.json`

### 2. Nightly Comparison

Compare a released version against the latest nightly builds.

```bash
python generate_comparison.py --version-a 1.23 --version-b nightly
```

Output: `output/comparison_v1.23_vs_vnightly.json`

### 3. Single-Version Benchmark

Generate a performance profile for one version (no comparison).

```bash
python generate_comparison.py --version-a 1.23
```

Output: `output/benchmark_v1.23.json`

## Generating Reports

Once you have the JSON output and prompt templates from Stage 1:

1. Open the desired prompt template from `output/`:
   - `prompt_template.md` — Customer-facing KB article (comparison mode)
   - `prompt_template_benchmark.md` — Customer-facing benchmark report (benchmark mode)
   - `prompt_template_internal_detailed_regression.md` — Internal detailed regression report (comparison mode)
2. Copy the JSON data from the output file (e.g., `output/comparison_v1.22_vs_v1.23.json`)
3. Feed both into your preferred LLM (Claude, ChatGPT, or any other AI assistant)
4. Each prompt template contains tone, framing, and output format guidelines specific to its report type

## CLI Reference

### generate_comparison.py

| Argument | Default | Description |
|----------|---------|-------------|
| `--version-a` | *(required)* | Version to analyze (e.g., `1.23`) |
| `--version-b` | *(none)* | Comparison version (e.g., `1.22`, `nightly`). Omit for benchmark mode |
| `--runs` | `3` | Number of recent runs to fetch per version for normalization |
| `--output` | `output/` | Output directory |
| `--db-host` | env `POSTGRES_PIPELINE_DB_HOST` | PostgreSQL host |
| `--db-port` | env `POSTGRES_PIPELINE_DB_PORT` or `5432` | PostgreSQL port |
| `--db-name` | env `POSTGRES_PIPELINE_DB_NAME` | Database name |
| `--db-user` | env `POSTGRES_PIPELINE_DB_USER` | Database user |
| `--db-sslmode` | env `POSTGRES_PIPELINE_DB_SSLMODE` or `prefer` | SSL mode |
| `--db-password-env` | `POSTGRES_PIPELINE_DB_PASSWORD` | Env var containing the DB password |

## Configuration

All metric definitions, test IDs, thresholds, and component/variant mappings are in `config.yaml`.

### Thresholds

| Setting | Default | Description |
|---------|---------|-------------|
| `significant_change_pct` | `5` | Below this percentage change -> "stable" |
| `major_change_pct` | `15` | Above this -> "major improvement/regression" |
| `mad_threshold` | `2.5` | MAD multiplier for outlier detection |
| `outlier_metric_ratio` | `0.5` | If >50% of metrics flagged on a run, exclude it |
| `min_runs_after_exclusion` | `2` | Minimum runs that must survive outlier exclusion |
| `default_runs` | `3` | Default number of runs to fetch per version |

### Components and Variants

The config defines three components, each with deployment variants and per-variant test IDs:

**Pipelines** (grouped by `test_concurrent`): Standard (423), HA-Deployments (419), HA-StatefulSets (421), QBT (422), HA+QBT (420)

**Chains** (grouped by `test_total`): Standard (427), HA (428), QBT (429), HA+QBT (430)

**Results** (no grouping): Standard (425)

Each variant has a `new_test_id` and optionally a `legacy_test_id` with filters for backward compatibility with older data.

### Adding a New Metric

Add an entry under the component's `metrics` list in `config.yaml`:

```yaml
- key: results_PipelineRuns_new_metric_avg    # JSONB field name (without __ prefix)
  display: "New Metric (avg)"                  # Human-readable name for the article
  unit: "s"                                    # s, count, cores, bytes, ms, req/s, etc.
  lower_is_better: true                        # true = decrease is improvement
  category: pipeline_performance               # groups metrics in the output JSON
```

### Adding a New Variant

Add under the component's `variants` in `config.yaml`:

```yaml
new_variant:
  display_name: "New Variant"
  new_test_id: 999           # Test ID for this variant
  legacy_test_id: null       # Optional: legacy test ID for older data
  legacy_filter: null        # Required if legacy_test_id is set
```

## Outlier Detection

### Why MAD?

Performance CI runs execute 3-4 times per version. Infrastructure flakiness (noisy neighbors, scheduling delays, node pressure) can produce one bad run that skews averages — fabricating regressions that don't exist or hiding real improvements. We need an outlier detection method that works reliably with very small sample sizes.

**Standard approaches don't work here:**
- **Z-score** (standard deviation) assumes normal distribution and needs 20-30+ samples. With 3 runs, one outlier shifts both the mean and standard deviation, so the outlier doesn't even register as anomalous.
- **IQR (Interquartile Range)** requires enough data points to compute meaningful quartiles. With 3 samples, Q1 and Q3 collapse to the min and max — it cannot distinguish signal from noise.

**MAD (Median Absolute Deviation)** uses the **median** instead of the mean as its reference point, so a single bad run cannot pull the baseline toward itself. It is well-studied in robust statistics and reliable with as few as 3 data points.

### How it works

1. For each metric across N runs, compute the median and MAD
2. Flag individual metric values that deviate beyond `2.5 x MAD` from the median
3. If a run has >50% of its metrics flagged, exclude the entire run — this signals a systemic infrastructure issue (e.g., node under pressure), not a real performance change affecting one metric
4. Safety guardrail: at least 2 runs must survive exclusion. If removing outliers would leave fewer, all runs are kept to avoid drawing conclusions from a single data point

The **whole-run exclusion logic** is the key design decision. A run with most metrics deviating is almost certainly an infrastructure problem. But if only one metric deviates on an otherwise normal run, that could be a real signal worth preserving.

### Configuration

All thresholds are tunable in `config.yaml`:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `mad_threshold` | `2.5` | MAD multiplier — values beyond `median +/- 2.5 x MAD` are flagged |
| `outlier_metric_ratio` | `0.5` | If >50% of metrics flagged on a run, exclude the whole run |
| `min_runs_after_exclusion` | `2` | Minimum runs that must survive — prevents over-exclusion |

## QE Validation Artifacts

Stage 1 saves two intermediate files alongside the final output so QE teams can trace any reported number back to source data:

| File | Contents |
|------|----------|
| `raw_data_*.json` | Every row fetched from the DB — metric values, timestamps, build IDs, version labels. This is the unprocessed source of truth. |
| `mad_analysis_*.json` | Post-outlier-detection results — which runs survived, which were excluded (with flagged metric counts and ratios), and the computed per-metric means/comparisons. |

To validate a number in the final report: final JSON -> `mad_analysis` (check outlier decisions and means) -> `raw_data` (check actual DB values).

## Database Safety

The database connection enforces **read-only mode** at the PostgreSQL session level (`SET SESSION READ ONLY`). This prevents any write operations even if a code bug introduces one. Only SELECT queries are executed.

## File Structure

```
reports/
├── README.md                       # This file
├── config.yaml                     # Metric definitions, test IDs, thresholds
├── generate_comparison.py          # DB -> JSON (fetch, normalize, compare)
├── prompt_template.md              # LLM prompt for comparison mode (customer-facing KB)
├── prompt_template_benchmark.md    # LLM prompt for benchmark mode
├── prompt_template_internal_detailed_regression.md  # LLM prompt for internal regression report
├── lib/
│   ├── __init__.py
│   ├── db.py                       # PostgreSQL fetcher (read-only)
│   ├── stats.py                    # MAD outlier detection, comparison stats
│   └── formatter.py                # JSON output structuring
└── output/                         # Generated files (gitignored)
    ├── raw_data_v1.22_vs_v1.23.json        # Raw DB rows for QE validation
    ├── mad_analysis_v1.22_vs_v1.23.json    # Outlier detection results
    ├── comparison_v1.22_vs_v1.23.json      # Final processed output
    ├── benchmark_v1.23.json
    ├── kb_article_v1.22_vs_v1.23.md
    └── regression_report_v1.22_vs_v1.23.md
```

## End-to-End Example

```bash
# Activate virtual environment
source ../venv/bin/activate

# Set credentials
export POSTGRES_PIPELINE_DB_HOST="your-db-host"
export POSTGRES_PIPELINE_DB_USER="your-db-user"
export POSTGRES_PIPELINE_DB_NAME="your-db-name"
export POSTGRES_PIPELINE_DB_PASSWORD="your-db-password"

# Fetch and process data
python generate_comparison.py --version-a 1.22 --version-b 1.23 --runs 3

# Feed output/comparison_v1.22_vs_v1.23.json + output/prompt_template.md
# into your preferred LLM to generate the KB article
```
