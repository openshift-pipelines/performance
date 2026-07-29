# Performance Report Generator

Automated pipeline for generating Red Hat KB-style performance articles for OpenShift Pipelines. Fetches data from the Horreum PostgreSQL database, applies statistical normalization, and produces a structured JSON that an LLM turns into a publishable markdown article.

## Quick Start

```bash
cd reports/

# Setup
python3 -m venv ../venv
source ../venv/bin/activate
pip install psycopg2-binary pyyaml openai

# Set DB connection via environment variables
export HORREUM_DB_HOST="your-db-host"
export HORREUM_DB_USER="your-db-user"
export HORREUM_DB_NAME="your-db-name"
export HORREUM_DB_PASSWORD="your-db-password"

# Generate comparison data
python generate_comparison.py --version-a 1.22 --version-b 1.23
```

This produces `output/comparison_v1.22_vs_v1.23.json` and copies the prompt template alongside it.

## Pipeline Overview

The workflow has two stages:

```
┌─────────────────────────┐      ┌─────────────────────────┐
│  generate_comparison.py │      │   generate_article.py   │
│                         │      │                         │
│  Horreum DB ──► JSON    │ ───► │  JSON + Prompt ──► .md  │
│  (fetch, normalize,     │      │  (OpenAI API call)      │
│   compare/benchmark)    │      │                         │
└─────────────────────────┘      └─────────────────────────┘
```

**Stage 1** connects to the database (read-only), fetches the last N runs per version, excludes outlier runs using MAD (Median Absolute Deviation), computes means and percentage changes, and writes a structured JSON file. It also saves intermediate artifacts (`raw_data_*.json` and `mad_analysis_*.json`) so QE teams can cross-verify the analysis against source data.

**Stage 2** takes that JSON, injects it into a prompt template with tone/framing guidelines, sends it to an OpenAI model, and writes the final KB article as markdown.

## Environment Variables

All database connection details are configured via environment variables to avoid exposing infrastructure details:

| Variable | Required | Description |
|----------|----------|-------------|
| `HORREUM_DB_HOST` | Yes | PostgreSQL host |
| `HORREUM_DB_USER` | Yes | Database user |
| `HORREUM_DB_NAME` | Yes | Database name |
| `HORREUM_DB_PASSWORD` | Yes | Database password |
| `HORREUM_DB_PORT` | No | PostgreSQL port (default: `5432`) |
| `HORREUM_DB_SSLMODE` | No | SSL mode (default: `prefer`) |
| `OPENAI_API_KEY` | For Stage 2 | OpenAI API key |

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

## Generating the KB Article

Once you have the JSON output from Stage 1:

```bash
export OPENAI_API_KEY="sk-..."

# Auto-detects comparison vs benchmark from the JSON
python generate_article.py --input output/comparison_v1.22_vs_v1.23.json

# Custom model
python generate_article.py --input output/comparison_v1.22_vs_v1.23.json --model gpt-4o-mini

# Explicit output path
python generate_article.py --input output/benchmark_v1.23.json --output output/my_article.md
```

Output: `output/kb_article_v1.22_vs_v1.23.md`

## CLI Reference

### generate_comparison.py

| Argument | Default | Description |
|----------|---------|-------------|
| `--version-a` | *(required)* | Version to analyze (e.g., `1.23`) |
| `--version-b` | *(none)* | Comparison version (e.g., `1.22`, `nightly`). Omit for benchmark mode |
| `--runs` | `3` | Number of recent runs to fetch per version for normalization |
| `--output` | `output/` | Output directory |
| `--db-host` | env `HORREUM_DB_HOST` | PostgreSQL host |
| `--db-port` | env `HORREUM_DB_PORT` or `5432` | PostgreSQL port |
| `--db-name` | env `HORREUM_DB_NAME` | Database name |
| `--db-user` | env `HORREUM_DB_USER` | Database user |
| `--db-sslmode` | env `HORREUM_DB_SSLMODE` or `prefer` | SSL mode |
| `--db-password-env` | `HORREUM_DB_PASSWORD` | Env var containing the DB password |

### generate_article.py

| Argument | Default | Description |
|----------|---------|-------------|
| `--input` | *(required)* | Path to comparison or benchmark JSON |
| `--output` | *(auto)* | Output markdown path. Auto-generated if omitted |
| `--model` | `gpt-4o` | OpenAI model to use |
| `--api-key-env` | `OPENAI_API_KEY` | Env var containing the OpenAI API key |

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

The config defines three components, each with deployment variants and per-variant Horreum test IDs:

**Pipelines** (grouped by `test_concurrent`): Standard (423), HA-Deployments (419), HA-StatefulSets (421), QBT (422), HA+QBT (420)

**Chains** (grouped by `test_total`): Standard (427), HA (428), QBT (429), HA+QBT (430)

**Results** (no grouping): Standard (425)

Each variant has a `new_test_id` and optionally a `legacy_test_id` with filters for backward compatibility with older Horreum data.

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
  new_test_id: 999           # Horreum test ID for this variant
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
├── generate_comparison.py          # Stage 1: DB -> JSON
├── generate_article.py             # Stage 2: JSON -> KB article via OpenAI
├── prompt_template.md              # LLM prompt for comparison mode
├── prompt_template_benchmark.md    # LLM prompt for benchmark mode
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
    └── kb_article_v1.22_vs_v1.23.md
```

## End-to-End Example

```bash
# Activate virtual environment
source ../venv/bin/activate

# Set credentials
export HORREUM_DB_HOST="your-db-host"
export HORREUM_DB_USER="your-db-user"
export HORREUM_DB_NAME="your-db-name"
export HORREUM_DB_PASSWORD="your-db-password"
export OPENAI_API_KEY="sk-your-api-key"

# Stage 1: Fetch and process data
python generate_comparison.py --version-a 1.22 --version-b 1.23 --runs 3

# Stage 2: Generate the article
python generate_article.py --input output/comparison_v1.22_vs_v1.23.json

# Result
cat output/kb_article_v1.22_vs_v1.23.md
```
