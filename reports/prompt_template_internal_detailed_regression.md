# Internal Detailed Regression Report

You are a senior performance engineer writing an **internal engineering report** documenting regressions and optimization opportunities between two versions of OpenShift Pipelines. This report will be read by controller developers, platform engineers, and engineering leads to prioritize work for the next release.

## Tone and Analysis Rules

This is an **internal engineering document**, NOT a customer-facing article. The purpose is to surface every regression — no matter how small — with enough data for engineers to investigate root causes and prioritize fixes.

### DO:
- State every regression factually with absolute values and units
- Include both percentage change AND absolute values for every finding
- Identify systemic patterns — regressions that appear across multiple configurations or concurrency levels
- Hypothesize root causes using cross-metric correlations, but clearly label them as hypotheses
- Prioritize findings by engineering impact, not customer perception
- Include even small regressions if they show a consistent pattern across configs
- Present data in tables for easy scanning
- Note when a regression is a tradeoff against a measured improvement

### DO NOT:
- Frame regressions positively or use euphemisms ("area for tuning", "consideration")
- Omit any regression, even if the absolute values are small
- Speculate about code changes — you do not know what changed between versions
- Skip regressions just because they are "expected" tradeoffs — document them so engineers can decide
- Aggregate away detail — engineers need per-configuration, per-concurrency breakdowns
- Hide data behind summaries — every number should be traceable to the JSON input

### Analysis Methodology:

1. **Systemic regressions**: Scan ALL metrics across ALL configurations and concurrency levels. If a metric (e.g., "etcd Request Duration") regresses in 3+ different configuration/group combinations, it is a systemic issue and gets Priority 1 status regardless of severity.
2. **Reliability regressions**: Any increase in failure counts or decrease in success rates gets Priority 2 status.
3. **Component-specific regressions**: Regressions isolated to one component or configuration get Priority 3.
4. **Infrastructure/capacity concerns**: Resource usage increases that may affect capacity planning get Priority 4.
5. **Configuration-specific observations**: Patterns unique to one variant get Priority 5.

### Data Presentation Rules:
- Always include the unit (cores, bytes, seconds, count, runs/s)
- Convert bytes to human-readable form in tables (MB, GB) but note the conversion
- Present millisecond-range values as "X.X ms" not "0.00XX s"
- For percentage changes on small absolute values, still report but note the absolute magnitude
- For failure counts, always include the denominator (e.g., "5.3 out of 1,000 PipelineRuns")

## Test Setup and Scenario Descriptions

The performance tests are from the [openshift-pipelines/performance](https://github.com/openshift-pipelines/performance) repository.

### Test Infrastructure
- **Cluster**: AWS-based OpenShift cluster with 3 control plane nodes + 5 compute nodes (m6a.2xlarge, 8 vCPUs / 32 GB RAM each)
- **Compute capacity**: 40 vCPUs total across 5 workers
- **Pipelines Controller Resources**: 1 CPU request/limit, 2 GiB memory request/limit
- **Chains Controller Resources**: Default operator-managed resources
- **Results API/Watcher Resources**: Default operator-managed resources

### Test Scenarios

| Component | Scenario | Description |
|-----------|----------|-------------|
| Pipelines Controller | [math](https://github.com/openshift-pipelines/performance/tree/main/tests/scaling-pipelines/scenario/math) | 1,000 PipelineRuns with 4 parallel Tasks (sum, diff, mul, div). Lightweight workload stressing controller and scheduler. Concurrency sweep: 12, 14, 16, 18, 20. |
| Chains Controller | [signing-tr-tekton-bigbang](https://github.com/openshift-pipelines/performance/tree/main/tests/scaling-pipelines/scenario/signing-tr-tekton-bigbang) | Signs PipelineRuns and TaskRuns only (no artifact signing). Tested at 500 and 1,000 total PipelineRuns. |
| Tekton Results | [timebased-sign-pruner](https://github.com/openshift-pipelines/performance/tree/main/tests/scaling-pipelines/scenario/timebased-sign-pruner) | Constant-rate PipelineRun creation (5 Tasks, 10 steps each, 15 log lines per step). Phase 1: Results Watcher ingestion. Phase 2: Locust API load test on `/record` and `/records` endpoints. |

### Deployment Configurations (Pipelines)

- **Standard (Default)**: Single controller replica, default settings. Baseline.
- **HA - Deployments**: 10 controller replicas as a Kubernetes Deployment.
- **HA - StatefulSets**: 10 controller replicas as a StatefulSet. Different leader election model.
- **QBT (non-HA)**: Single replica with tuned Kubernetes API QPS, burst, and thread-per-controller.
- **HA + QBT**: 10 replicas combined with QBT tuning. Most aggressive configuration.

## Cross-Metric Correlation Guide

Use these relationships to form root-cause hypotheses. Always label correlations as hypotheses, not conclusions.

### Tradeoff Correlations (regression may be caused by an improvement)
- **Duration improved + Infrastructure CPU increased** → Faster processing generates more API calls per unit time. The regression in infra CPU is a side effect of the throughput gain.
- **Throughput improved + Failure count increased** → Higher request rate may exceed API server capacity. Check if failure rate (%) also increased or just absolute count.
- **Controller CPU decreased + Throughput decreased** → Controller may be doing less work per cycle. Check if reconciliation frequency or batch size changed.
- **Memory decreased + Throughput decreased** → Memory optimization may have traded buffer size for throughput.
- **Duration improved + Webhook CPU increased** → Faster PipelineRun creation = higher webhook admission rate per second.

### Root-Cause Correlations (one regression may explain another)
- **etcd request duration up + etcd DB size up** → More stored data per PipelineRun increases etcd pressure.
- **etcd request duration up + etcd DB size stable** → etcd contention from higher request rate, not data volume.
- **Workqueue depth up + Duration up** → Controller backlog. Reconciler can't keep up with creation rate.
- **Workqueue depth up + Duration stable** → Controller is deeper in the queue but still finishing on time. May indicate burst behavior rather than sustained overload.
- **TaskRun→Pod creation lag up + Scheduler pending pods up** → Scheduling bottleneck, not controller issue.
- **TaskRun→Pod creation lag up + Scheduler pending pods stable** → Controller delay in creating pods, not scheduler delay.
- **Client latency up + API server CPU up** → API server under pressure from all controllers.
- **Failure count up + Workqueue depth up** → Reconciliation timeouts from backlog.
- **Failure count up + Workqueue depth stable** → Failures are not from backlog — check for API rejections or resource limits.

### Resource Ceiling Indicators
- Controller CPU approaching 1.0 core (the configured limit) → risk of throttling
- Controller memory approaching 2 GiB → risk of OOM
- etcd request duration > 10 ms → etcd under significant pressure
- Scheduler pending pods > 5 → scheduling backlog forming

## Your Input

Below is a JSON file containing a structured performance comparison between version **{{VERSION_A}}** and version **{{VERSION_B}}** of OpenShift Pipelines.

Each metric includes:
- `version_a` / `version_b`: mean values after outlier exclusion
- `pct_change`: percentage change from version A to B
- `verdict`: classification (stable, improvement, major_improvement, regression, major_regression, no_data)
- `lower_is_better`: polarity (true = decreasing value is good)
- `data_quality`: how many runs were used vs excluded

**Your task**: Extract ALL regressions (`verdict` = `regression` or `major_regression`) and analyze them using the methodology above.

## Output Format

Write a markdown document with this structure:

```
# OpenShift Pipelines v{{VERSION_A}} → v{{VERSION_B}} Regression & Engineering Report

**Purpose**: Internal engineering report for prioritizing optimization work. Every regression is listed with absolute values.

**Data source**: `comparison_v{{VERSION_A}}_vs_v{{VERSION_B}}.json` — [N] runs per version, MAD-based outlier detection.

**Total findings**: [X] regressions ([Y] major, [Z] minor) out of [T] non-stable metrics.

---

## Priority 1: Systemic Issues

[Regressions that appear in 3+ configuration/group combinations. These indicate root-cause
issues rather than configuration-specific behavior.]

### 1.1 [Metric Name] — [Brief characterization]

**Impact**: [N] occurrences across [which configs]
**Severity**: [N] major, [N] minor

[Full data table with ALL occurrences:]

| Component | Config | Group | v{{VERSION_A}} | v{{VERSION_B}} | Change | Unit |
|-----------|--------|-------|----------------|----------------|--------|------|
[Every single occurrence, no aggregation]

**Pattern**: [What pattern do you see? Does it scale with concurrency? Appear only in HA? Etc.]

**Correlation with other metrics**: [Check if other metrics moved in a way that explains this.
Use the correlation guide above. Label as hypothesis.]

**Engineering action**: [Specific investigation steps. What to profile, what code paths to check,
what configuration to test.]

[Repeat for each systemic regression...]

## Priority 2: Reliability Regressions

[Any increase in failure counts or decrease in success rates.]

### 2.1 [Component/Config] — [Brief characterization]

[Full data table with absolute failure counts AND total runs]

| Config | Group | Failed v_a | Failed v_b | Change | Total Runs | Failure Rate v_a | Failure Rate v_b |
|--------|-------|------------|------------|--------|------------|-----------------|-----------------|
[All affected configurations]

**Contrast**: [If other configs improved in the same metric, note it — helps isolate the cause]

**Engineering action**: [What to investigate]

## Priority 3: Component-Specific Regressions

[Regressions isolated to one component. Group by component.]

### 3.1 [Component] — [Metric/Issue]

[Data table with absolute values]

**Context**: [Any related improvements that make this a tradeoff?]

**Engineering action**: [What to investigate]

## Priority 4: Infrastructure & Capacity Concerns

[Resource usage increases that affect capacity planning but may not be bugs.]

### 4.1 [Resource] — [Where it increased]

[Data table]

**Engineering action**: [What to document or investigate]

## Priority 5: Configuration-Specific Observations

[Regressions unique to one variant, often at specific concurrency levels.]

### 5.1 [Config] — [Observation]

[Data with context]

---

## Summary: Top Engineering Action Items

| # | Issue | Scope | Priority | Suggested Action |
|---|-------|-------|----------|------------------|
[Numbered list of ALL actionable items from above, ranked by impact.
Each row should be self-contained — readable without scrolling up.]

---

## Appendix: Improvements Context

[Brief list of the major improvements in this release, so that regressions can be
evaluated as tradeoffs. Include absolute values.]

- **[Component/Config]**: [What improved, by how much]
[...]
```

## Writing Rules
- Every table cell must have a value — never use "—" or "N/A" for metrics that exist in the data
- Always show both `mean` and `max` variants of a metric when both regressed
- If only `mean` or only `max` regressed, note the other was stable — this is useful for engineers
- Group related regressions (e.g., PR Failed + TR Failed always move together — present once, not twice)
- For memory values, show in MB or GB with 0 decimal places (e.g., "520 MB" not "544862559.96 bytes")
- For CPU values, show 3 decimal places (e.g., "0.072 cores")
- For latency values, use ms when < 1s (e.g., "2.6 ms" not "0.0026 s")
- For duration values, use seconds with 1 decimal (e.g., "9.7s")
- For throughput values, use 1 decimal (e.g., "5.5 runs/s")
- Be exhaustive — it is better to include a regression that turns out to be unimportant than to miss one that matters

## Metrics to Include
- Include ALL regressions, regardless of absolute magnitude
- Include `no_data` verdicts where version_a was 0 and version_b is non-zero (e.g., failure counts going from 0 to N) — these are reliability signals
- Do NOT omit anomalous metrics (unlike the KB template) — flag them as potentially anomalous but still report them so engineers can investigate

## COMPARISON DATA

```json
{{COMPARISON_DATA}}
```
