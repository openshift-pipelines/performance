local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/results-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local testId = common.testId;
local versionExpr = common.versionExpr;
local datasourceVar = common.datasourceVar;

local versionQuery = "SELECT DISTINCT %s AS version FROM data WHERE horreum_testid = %g AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testId];

local createVersionVar(name, label, defaultVersion) = {
  type: 'query',
  name: name,
  label: label,
  description: '%s for comparison.' % label,
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: versionQuery,
  multi: false,
  includeAll: false,
  current: { text: defaultVersion, value: defaultVersion },
  refresh: 2,
  sort: 0,
};

local version1Var = createVersionVar('version1', 'Version 1', 'nightly');
local version2Var = createVersionVar('version2', 'Version 2', '1.22');

local versionPredicate(varName) = |||
        AND %s = '${%s}'
||| % [versionExpr, varName];

local createQuery(fieldName, metricLabel, versionVar, additionalFields={}) =
  local baseFields = { [metricLabel]: fieldName };
  local allFields = baseFields + additionalFields;
  local fieldSelections = std.join(',\n    ', [
    "AVG((label_values->>'%s')::DOUBLE PRECISION) AS %s" % [allFields[key], key]
    for key in std.objectFields(allFields)
  ]);
  local fieldConditions = std.join('\n    AND ', [
    "label_values ? '%s'" % allFields[key]
    for key in std.objectFields(allFields)
  ]);
  local selectStatements = std.join('\n\nUNION ALL\n\n', [
    |||
      SELECT
        EXTRACT(EPOCH FROM day) AS time,
        '%s' AS metric,
        %s AS value
      FROM daily_agg
    ||| % [key, key]
    for key in std.objectFields(allFields)
  ]);

  {
    rawSql: |||
      WITH daily_agg AS (
        SELECT
          DATE_TRUNC('day', start) AS day,
          %s
        FROM data
        WHERE horreum_testid = %g
          AND $__timeFilter(start)
          %s
          AND %s
        GROUP BY day
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testId, versionPredicate(versionVar), fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

local compPanel(title, fieldName, metricLabel, unit, gridX, gridY, gridW=12, gridH=8, versionVar='version1', additionalFields={}, description='') =
  timeSeries.new('%s — ${%s}' % [title, versionVar])
  + timeSeries.queryOptions.withDatasource(type='grafana-postgresql-datasource', uid='${datasource}')
  + (if description != '' then timeSeries.panelOptions.withDescription(description) else {})
  + timeSeries.gridPos.withX(gridX)
  + timeSeries.gridPos.withY(gridY)
  + timeSeries.gridPos.withW(gridW)
  + timeSeries.gridPos.withH(gridH)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
  + timeSeries.fieldConfig.defaults.custom.withLineWidth(2)
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(8)
  + timeSeries.fieldConfig.defaults.custom.withGradientMode('opacity')
  + timeSeries.fieldConfig.defaults.custom.withSpanNulls(false)
  + timeSeries.fieldConfig.defaults.custom.withShowPoints('always')
  + timeSeries.fieldConfig.defaults.custom.withPointSize(6)
  + timeSeries.standardOptions.withUnit(unit)
  + timeSeries.standardOptions.withMin(0)
  + timeSeries.options.withTooltip({ mode: 'multi', sort: 'desc' })
  + timeSeries.options.withLegend({ displayMode: 'list', placement: 'bottom', calcs: [] })
  + timeSeries.queryOptions.withTargets([
    createQuery(fieldName, metricLabel, versionVar, additionalFields),
  ]);

local sideBySide(title, fieldName, metricLabel, unit, y, additionalFields={}, description='') = [
  compPanel(title, fieldName, metricLabel, unit, 0, y, 12, 8, 'version1', additionalFields, description),
  compPanel(title, fieldName, metricLabel, unit, 12, y, 12, 8, 'version2', additionalFields, description),
];

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  // ── PipelineRun Ingestion ──────────────────────────────────────
  row('PipelineRun Ingestion', 0),
] + sideBySide('PR Ingestion Throughput', '__results_PipelineRuns_ingestion_throughput', 'throughput', 'short', 1,
    description='Rate at which the Results watcher ingests completed PipelineRuns (records/sec). Higher indicates faster ingestion.')
+ sideBySide('PR Ingestion Duration', '__results_PipelineRuns_ingestion_duration', 'duration', 's', 9,
    description='Total wall-clock time for the Results watcher to ingest all completed PipelineRuns. Lower means the watcher kept up with the pipeline creation rate.')
+ sideBySide('PR Stored Successfully', '__results_PipelineRuns_ingestion_count_stored_true', 'stored_ok', 'short', 17,
    description='Number of PipelineRun records successfully persisted to the Results API database.')
+ sideBySide('PR Store Failures', '__results_PipelineRuns_ingestion_count_stored_false', 'stored_fail', 'short', 25,
    description='Number of PipelineRun records that failed to persist. Non-zero indicates API errors, DB write failures, or resource exhaustion.')
+ [
  // ── TaskRun Ingestion ──────────────────────────────────────────
  row('TaskRun Ingestion', 33),
] + sideBySide('TR Ingestion Throughput', '__results_TaskRuns_ingestion_throughput', 'throughput', 'short', 34,
    description='Rate at which the Results watcher ingests completed TaskRuns (records/sec). Each PipelineRun contains 5 tasks × 10 steps.')
+ sideBySide('TR Ingestion Duration', '__results_TaskRuns_ingestion_duration', 'duration', 's', 42,
    description='Total wall-clock time for the Results watcher to ingest all completed TaskRuns.')
+ sideBySide('TR Stored Successfully', '__results_TaskRuns_ingestion_count_stored_true', 'stored_ok', 'short', 50,
    description='Number of TaskRun records successfully persisted to the Results API database.')
+ sideBySide('TR Store Failures', '__results_TaskRuns_ingestion_count_stored_false', 'stored_fail', 'short', 58,
    description='Number of TaskRun records that failed to persist. Non-zero indicates API errors, DB write failures, or resource exhaustion.')
+ [
  // ── Results API ────────────────────────────────────────────────
  row('Results API', 66),
] + sideBySide('/record Latency', '__results_ResultsAPI_record_latency_avg', 'latency_avg', 'ms', 67,
    { latency_max: '__results_ResultsAPI_record_latency_max' },
    description='Latency of the Results API /record endpoint under Locust load test (100 users, 10 spawn/sec, 15 min). Shows mean and worst-case response time.')
+ sideBySide('/record RPS', '__results_ResultsAPI_record_rps', 'rps', 'reqps', 75,
    description='Sustained requests per second to the Results API /record endpoint during Locust load test. Measures single-record fetch throughput.')
+ sideBySide('/records Latency', '__results_ResultsAPI_records_latency_avg', 'latency_avg', 'ms', 83,
    { latency_max: '__results_ResultsAPI_records_latency_max' },
    description='Latency of the Results API /records (list) endpoint under Locust load test. Typically higher than /record due to pagination and result set construction.')
+ sideBySide('/records RPS', '__results_ResultsAPI_records_rps', 'rps', 'reqps', 91,
    description='Sustained requests per second to the Results API /records (list) endpoint during Locust load test. Measures bulk-fetch throughput.')
+ [
  // ── Results Component Metrics ──────────────────────────────────
  row('Results Watcher & API Server', 99),
] + sideBySide('Watcher CPU', '__measurements_tektonResultsWatcher_cpu_mean', 'cpu_mean', 'short', 100,
    { cpu_max: '__measurements_tektonResultsWatcher_cpu_max' },
    description='CPU of the tekton-results-watcher Pod (cores). Watches for completed PipelineRuns/TaskRuns and persists them to the Results API.')
+ sideBySide('Watcher Memory', '__measurements_tektonResultsWatcher_memory_mean', 'mem_mean', 'bytes', 108,
    { mem_max: '__measurements_tektonResultsWatcher_memory_max' },
    description='Memory (RSS) of the tekton-results-watcher Pod. High memory may indicate large watch caches or slow GC under high ingestion load.')
+ sideBySide('API Server CPU', '__measurements_tektonResultsApi_cpu_mean', 'cpu_mean', 'short', 116,
    { cpu_max: '__measurements_tektonResultsApi_cpu_max' },
    description='CPU of the tekton-results-api Pod (cores). Serves the Results REST API hit by the Locust load test.')
+ sideBySide('API Server Memory', '__measurements_tektonResultsApi_memory_mean', 'mem_mean', 'bytes', 124,
    { mem_max: '__measurements_tektonResultsApi_memory_max' },
    description='Memory (RSS) of the tekton-results-api Pod. High memory may indicate query result caching or connection pool growth under Locust load.')
+ [
  // ── Pipeline Performance ───────────────────────────────────────
  row('Pipeline Performance', 132),
] + sideBySide('PipelineRun Duration (avg)', '__results_PipelineRuns_duration_avg', 'pr_duration', 's', 133,
    description='Average wall-clock time from PipelineRun creation to completion. Each pipeline has 5 tasks × 10 steps × 15 log lines. Includes scheduling, execution, and signing overhead.')
+ sideBySide('PipelineRun Succeeded', '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 141,
    description='Total PipelineRuns that completed successfully. The test creates PRs at a constant rate with 30 concurrent; all should succeed.')
+ [
  // ── Cluster & Infrastructure ───────────────────────────────────
  row('Cluster & Infrastructure', 149),
] + sideBySide('Cluster CPU', '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short', 150,
    description='Mean total cluster CPU usage rate (cores) across all nodes. Reflects the combined load of pipeline execution, signing, ingestion, and Locust testing.')
+ sideBySide('Cluster Memory', '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes', 158,
    description='Mean total cluster RSS memory across all nodes during the test.')
+ [
  // ── etcd ───────────────────────────────────────────────────────
  row('etcd', 166),
] + sideBySide('etcd DB Size', '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes', 167,
    description='Mean etcd MVCC database total size. Reflects Kubernetes object storage growth from PipelineRun/TaskRun creation.')
+ sideBySide('etcd Request Duration', '__measurements_etcdRequestDurationSecondsAverage_mean', 'req_duration', 's', 175,
    description='Mean etcd request latency. High latency indicates etcd is under pressure from the volume of Kubernetes API operations.');

dashboard.new('Results Comparison Dashboard')
+ dashboard.withUid('Results_Comparison')
+ dashboard.withDescription('Side-by-side comparison of two Tekton Results versions. Test ID 425.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, version1Var, version2Var])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['results', 'comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
