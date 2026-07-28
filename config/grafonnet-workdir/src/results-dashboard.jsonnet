local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/results-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local testId = common.testId;
local versionExpr = common.versionExpr;
local datasourceVar = common.datasourceVar;

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Filter by deployment version.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT %s AS version FROM data WHERE horreum_testid = %g AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testId],
  multi: false,
  includeAll: false,
  current: { text: 'nightly', value: 'nightly' },
  refresh: 2,
  sort: 0,
};

local concurrencyVar = {
  type: 'query',
  name: 'concurrency',
  label: 'Concurrency',
  description: 'Filter by concurrency level.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency FROM data WHERE horreum_testid = %g AND $__timeFilter(start) AND label_values ? '__parameters_test_concurrent' ORDER BY concurrency" % testId,
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 3,
};

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
|||;

local createQuery(fieldName, metricLabel, additionalFields={}) =
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
        '%s @ ' || version || ' / c' || concurrency AS metric,
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
          %s AS version,
          (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency,
          %s
        FROM data
        WHERE horreum_testid = %g
          AND $__timeFilter(start)
          AND %s = '${version}'
          %s
          AND %s
        GROUP BY day, version, concurrency
      )

      %s

      ORDER BY time, metric;
    ||| % [versionExpr, fieldSelections, testId, versionExpr, concurrencyPredicate, fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

local createPanel(title, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, additionalFields={}, description='', axisSoftMax=null) =
  timeSeries.new(title)
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
  + (if axisSoftMax != null then { fieldConfig+: { defaults+: { custom+: { axisSoftMax: axisSoftMax } } } } else {})
  + timeSeries.queryOptions.withTargets([
    createQuery(fieldName, metricLabel, additionalFields),
  ]);

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  // ── PipelineRun Ingestion ──────────────────────────────────────
  row('PipelineRun Ingestion', 0),
  createPanel(
    'PR Ingestion Throughput',
    '__results_PipelineRuns_ingestion_throughput', 'throughput', 'short',
    0, 1, 12, 8,
    description='Rate at which the Results watcher ingests completed PipelineRuns into the Results API (records/sec). Higher indicates faster ingestion. Measured during the signing+ingestion phase of the test.'
  ),
  createPanel(
    'PR Ingestion Duration',
    '__results_PipelineRuns_ingestion_duration', 'duration', 's',
    12, 1, 12, 8,
    description='Total wall-clock time for the Results watcher to ingest all completed PipelineRuns. Lower means the watcher kept up with the pipeline creation rate.'
  ),
  createPanel(
    'PR Stored Successfully',
    '__results_PipelineRuns_ingestion_count_stored_true', 'stored_ok', 'short',
    0, 9, 12, 8,
    description='Number of PipelineRun records the Results watcher successfully persisted to the Results API database.'
  ),
  createPanel(
    'PR Store Failures',
    '__results_PipelineRuns_ingestion_count_stored_false', 'stored_fail', 'short',
    12, 9, 12, 8,
    description='Number of PipelineRun records the Results watcher failed to persist. Non-zero values indicate API errors, DB write failures, or resource exhaustion.'
  ),

  // ── TaskRun Ingestion ──────────────────────────────────────────
  row('TaskRun Ingestion', 17),
  createPanel(
    'TR Ingestion Throughput',
    '__results_TaskRuns_ingestion_throughput', 'throughput', 'short',
    0, 18, 12, 8,
    description='Rate at which the Results watcher ingests completed TaskRuns into the Results API (records/sec). Each PipelineRun contains multiple TaskRuns (5 tasks × steps).'
  ),
  createPanel(
    'TR Ingestion Duration',
    '__results_TaskRuns_ingestion_duration', 'duration', 's',
    12, 18, 12, 8,
    description='Total wall-clock time for the Results watcher to ingest all completed TaskRuns.'
  ),
  createPanel(
    'TR Stored Successfully',
    '__results_TaskRuns_ingestion_count_stored_true', 'stored_ok', 'short',
    0, 26, 12, 8,
    description='Number of TaskRun records the Results watcher successfully persisted to the Results API database.'
  ),
  createPanel(
    'TR Store Failures',
    '__results_TaskRuns_ingestion_count_stored_false', 'stored_fail', 'short',
    12, 26, 12, 8,
    description='Number of TaskRun records the Results watcher failed to persist. Non-zero values indicate API errors, DB write failures, or resource exhaustion.'
  ),

  // ── Results API ─────────────────────────────────────────────────
  row('Results API', 34),
  createPanel(
    '/record Latency',
    '__results_ResultsAPI_record_latency_avg', 'latency_avg', 'ms',
    0, 35, 12, 8,
    { latency_max: '__results_ResultsAPI_record_latency_max' },
    description='Latency of the Results API /record endpoint under Locust load test (100 users, 10 spawn/sec, 15 min).\n- **latency_avg**: mean response time\n- **latency_max**: worst-case response time'
  ),
  createPanel(
    '/record RPS',
    '__results_ResultsAPI_record_rps', 'rps', 'reqps',
    12, 35, 12, 8,
    description='Sustained requests per second to the Results API /record endpoint during the Locust load test. Measures single-record fetch throughput.'
  ),
  createPanel(
    '/records Latency',
    '__results_ResultsAPI_records_latency_avg', 'latency_avg', 'ms',
    0, 43, 12, 8,
    { latency_max: '__results_ResultsAPI_records_latency_max' },
    description='Latency of the Results API /records (list) endpoint under Locust load test.\n- **latency_avg**: mean response time\n- **latency_max**: worst-case response time'
  ),
  createPanel(
    '/records RPS',
    '__results_ResultsAPI_records_rps', 'rps', 'reqps',
    12, 43, 12, 8,
    description='Sustained requests per second to the Results API /records (list) endpoint during the Locust load test. Measures bulk-fetch throughput.'
  ),

  // ── Results Component Metrics ──────────────────────────────────
  row('Results Watcher & API Server', 51),
  createPanel(
    'Watcher CPU',
    '__measurements_tektonResultsWatcher_cpu_mean', 'cpu_mean', 'short',
    0, 52, 12, 8,
    { cpu_max: '__measurements_tektonResultsWatcher_cpu_max' },
    description='CPU usage of the tekton-results-watcher Pod (cores). The watcher watches for completed PipelineRuns/TaskRuns and persists them to the Results API.\n- **cpu_mean**: average over test duration\n- **cpu_max**: peak usage'
  ),
  createPanel(
    'Watcher Memory',
    '__measurements_tektonResultsWatcher_memory_mean', 'mem_mean', 'bytes',
    12, 52, 12, 8,
    { mem_max: '__measurements_tektonResultsWatcher_memory_max' },
    description='Memory (RSS) of the tekton-results-watcher Pod. High memory may indicate large watch caches or slow GC under high ingestion load.\n- **mem_mean**: average over test duration\n- **mem_max**: peak usage'
  ),
  createPanel(
    'API Server CPU',
    '__measurements_tektonResultsApi_cpu_mean', 'cpu_mean', 'short',
    0, 60, 12, 8,
    { cpu_max: '__measurements_tektonResultsApi_cpu_max' },
    description='CPU usage of the tekton-results-api Pod (cores). Serves the Results REST API hit by the Locust load test (/record, /records endpoints).\n- **cpu_mean**: average over test duration\n- **cpu_max**: peak usage'
  ),
  createPanel(
    'API Server Memory',
    '__measurements_tektonResultsApi_memory_mean', 'mem_mean', 'bytes',
    12, 60, 12, 8,
    { mem_max: '__measurements_tektonResultsApi_memory_max' },
    description='Memory (RSS) of the tekton-results-api Pod. High memory may indicate query result caching or connection pool growth under Locust load.\n- **mem_mean**: average over test duration\n- **mem_max**: peak usage'
  ),

  // ── Pipeline Performance ───────────────────────────────────────
  row('Pipeline Performance', 68),
  createPanel(
    'PipelineRun Duration (avg)',
    '__results_PipelineRuns_duration_avg', 'pr_duration', 's',
    0, 69, 12, 8,
    description='Average wall-clock time from PipelineRun creation to completion. Each pipeline has 5 tasks × 10 steps × 15 log lines. Includes scheduling, execution, and signing overhead.'
  ),
  createPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short',
    12, 69, 12, 8,
    description='Total PipelineRuns that completed successfully. The test creates PRs at a constant rate with 30 concurrent; all should succeed.'
  ),

  // ── Cluster & Infrastructure ───────────────────────────────────
  row('Cluster & Infrastructure', 85),
  createPanel(
    'Cluster CPU',
    '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short',
    0, 86, 12, 8,
    description='Mean total cluster CPU usage rate (cores) across all nodes during the test. Reflects the combined load of pipelines execution, signing, ingestion, and Locust testing.'
  ),
  createPanel(
    'Cluster Memory',
    '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes',
    12, 86, 12, 8,
    description='Mean total cluster RSS memory across all nodes during the test.'
  ),
  createPanel(
    'Pipelines Controller CPU',
    '__measurements_tektonPipelinesController_cpu_mean', 'ctrl_cpu', 'short',
    0, 94, 12, 8,
    description='Mean CPU of the Tekton Pipelines controller. Handles PipelineRun/TaskRun reconciliation. Higher values indicate more reconciliation overhead.'
  ),
  createPanel(
    'Pipelines Controller Memory',
    '__measurements_tektonPipelinesController_memory_mean', 'ctrl_mem', 'bytes',
    12, 94, 12, 8,
    description='Mean memory (RSS) of the Tekton Pipelines controller. Growth may indicate large informer caches from many concurrent PipelineRuns.'
  ),

  // ── etcd ───────────────────────────────────────────────────────
  row('etcd', 102),
  createPanel(
    'etcd DB Size',
    '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes',
    0, 103, 12, 8,
    description='Mean etcd MVCC database total size. Reflects the cumulative Kubernetes object storage. Rapid growth during the test indicates high PipelineRun/TaskRun creation rate.'
  ),
  createPanel(
    'etcd Request Duration',
    '__measurements_etcdRequestDurationSecondsAverage_mean', 'req_duration', 's',
    12, 103, 12, 8,
    description='Mean etcd request latency. High latency indicates etcd is under pressure from the volume of Kubernetes API operations (PR/TR CRUD + status updates).'
  ),
];

dashboard.new('Results Performance Dashboard')
+ dashboard.withUid('Results_Performance')
+ dashboard.withDescription('Tekton Results performance — watcher ingestion latency, API load testing, and component resource usage across versions. Test ID 425.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, versionVar, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['results', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
