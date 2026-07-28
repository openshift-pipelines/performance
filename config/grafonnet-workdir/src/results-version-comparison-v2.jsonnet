local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/results-common.libsonnet';
local versionBarLib = import 'lib/version-bar-common.libsonnet';

local dashboard = grafonnet.dashboard;

local testId = common.testId;
local versionExpr = common.versionExpr;
local datasourceVar = common.datasourceVar;

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Select versions to compare. Use All to include every version.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT %s AS version FROM data WHERE horreum_testid = %g AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testId],
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 0,
};

local createQuery(fieldName, agg='AVG') =
  {
    rawSql: |||
      WITH daily AS (
        SELECT
          TO_CHAR(DATE_TRUNC('day', start), 'MM/DD') AS day,
          DATE_TRUNC('day', start) AS day_date,
          %s AS version,
          (label_values->>'%s')::DOUBLE PRECISION AS val
        FROM data
        WHERE horreum_testid = %g
          AND $__timeFilter(start)
          AND %s IN ($version)
          AND label_values ? '%s'
      )
      SELECT day, version, %s(val) AS value
      FROM daily
      GROUP BY day, version
      ORDER BY MIN(day_date),
        CASE WHEN version = 'nightly' THEN 0 ELSE 1 END,
        version ASC
    ||| % [versionExpr, fieldName, testId, versionExpr, fieldName, agg],
    format: 'table',
    refId: 'A',
  };

local row = versionBarLib.row;

local versionBar(title, fieldName, unit, x, y, w, h, description='', agg='AVG', axisSoftMax=null) =
  versionBarLib.versionBar(createQuery, title, fieldName, unit, x, y, w, h, description, agg, axisSoftMax);

local pw = 24;
local ph = 8;

local allPanels = [
  // ── PipelineRun Ingestion ──────────────────────────────────────
  row('PipelineRun Ingestion', 0),
  versionBar('PR Ingestion Throughput', '__results_PipelineRuns_ingestion_throughput', 'short', 0, 1, pw, ph,
    description='Rate at which the Results watcher ingests completed PipelineRuns (records/sec). Higher indicates faster ingestion. Compare across versions to detect watcher performance regressions.'),
  versionBar('PR Ingestion Duration', '__results_PipelineRuns_ingestion_duration', 's', 0, 9, pw, ph,
    description='Total wall-clock time for the Results watcher to ingest all completed PipelineRuns. Lower means the watcher kept up with the pipeline creation rate.'),
  versionBar('PR Stored Successfully', '__results_PipelineRuns_ingestion_count_stored_true', 'none', 0, 17, pw, ph,
    description='Number of PipelineRun records successfully persisted to the Results API database per version per day.', agg='SUM'),
  versionBar('PR Store Failures', '__results_PipelineRuns_ingestion_count_stored_false', 'none', 0, 25, pw, ph,
    description='Number of PipelineRun records that failed to persist. Non-zero values indicate API errors, DB write failures, or resource exhaustion.', agg='SUM'),

  // ── TaskRun Ingestion ──────────────────────────────────────────
  row('TaskRun Ingestion', 33),
  versionBar('TR Ingestion Throughput', '__results_TaskRuns_ingestion_throughput', 'short', 0, 34, pw, ph,
    description='Rate at which the Results watcher ingests completed TaskRuns (records/sec). Each PipelineRun contains 5 tasks × 10 steps.'),
  versionBar('TR Ingestion Duration', '__results_TaskRuns_ingestion_duration', 's', 0, 42, pw, ph,
    description='Total wall-clock time for the Results watcher to ingest all completed TaskRuns.'),
  versionBar('TR Stored Successfully', '__results_TaskRuns_ingestion_count_stored_true', 'none', 0, 50, pw, ph,
    description='Number of TaskRun records successfully persisted to the Results API database per version per day.', agg='SUM'),
  versionBar('TR Store Failures', '__results_TaskRuns_ingestion_count_stored_false', 'none', 0, 58, pw, ph,
    description='Number of TaskRun records that failed to persist. Non-zero values indicate API errors, DB write failures, or resource exhaustion.', agg='SUM'),

  // ── Results API ────────────────────────────────────────────────
  row('Results API', 66),
  versionBar('/record Latency (avg)', '__results_ResultsAPI_record_latency_avg', 'ms', 0, 67, pw, ph,
    description='Average response time of the Results API /record endpoint under Locust load test (100 users, 10 spawn/sec, 15 min). Measures single-record fetch latency.'),
  versionBar('/record RPS', '__results_ResultsAPI_record_rps', 'reqps', 0, 75, pw, ph,
    description='Sustained requests per second to the Results API /record endpoint during Locust load test. Higher is better — indicates the API can handle more concurrent fetch requests.'),
  versionBar('/records Latency (avg)', '__results_ResultsAPI_records_latency_avg', 'ms', 0, 83, pw, ph,
    description='Average response time of the Results API /records (list) endpoint under Locust load test. Typically higher than /record due to pagination and result set construction.'),
  versionBar('/records RPS', '__results_ResultsAPI_records_rps', 'reqps', 0, 91, pw, ph,
    description='Sustained requests per second to the Results API /records (list) endpoint during Locust load test. Measures bulk-fetch throughput.'),

  // ── Results Component Metrics ──────────────────────────────────
  row('Results Watcher & API Server', 99),
  versionBar('Watcher CPU (mean)', '__measurements_tektonResultsWatcher_cpu_mean', 'short', 0, 100, pw, ph,
    description='Mean CPU of the tekton-results-watcher Pod (cores). The watcher watches for completed PipelineRuns/TaskRuns and persists them to the Results API.'),
  versionBar('Watcher Memory (mean)', '__measurements_tektonResultsWatcher_memory_mean', 'bytes', 0, 108, pw, ph,
    description='Mean memory (RSS) of the tekton-results-watcher Pod. High memory may indicate large watch caches or slow GC under high ingestion load.'),
  versionBar('API Server CPU (mean)', '__measurements_tektonResultsApi_cpu_mean', 'short', 0, 116, pw, ph,
    description='Mean CPU of the tekton-results-api Pod (cores). Serves the Results REST API hit by the Locust load test.'),
  versionBar('API Server Memory (mean)', '__measurements_tektonResultsApi_memory_mean', 'bytes', 0, 124, pw, ph,
    description='Mean memory (RSS) of the tekton-results-api Pod. High memory may indicate query result caching or connection pool growth under Locust load.'),

  // ── Pipeline Performance ───────────────────────────────────────
  row('Pipeline Performance', 132),
  versionBar('PipelineRun Duration (avg)', '__results_PipelineRuns_duration_avg', 's', 0, 133, pw, ph,
    description='Average wall-clock time from PipelineRun creation to completion. Each pipeline has 5 tasks × 10 steps × 15 log lines. Includes scheduling, execution, and signing overhead.'),
  versionBar('PipelineRun Succeeded', '__results_PipelineRuns_count_succeeded', 'none', 0, 141, pw, ph,
    description='Total PipelineRuns that completed successfully. The test creates PRs at a constant rate with 30 concurrent; all should succeed.', agg='SUM'),

  // ── Cluster & Infrastructure ───────────────────────────────────
  row('Cluster & Infrastructure', 149),
  versionBar('Cluster CPU', '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'short', 0, 150, pw, ph,
    description='Mean total cluster CPU usage rate (cores) across all nodes. Reflects the combined load of pipeline execution, signing, ingestion, and Locust testing.'),
  versionBar('Cluster Memory', '__measurements_clusterMemoryUsageRssTotal_mean', 'bytes', 0, 158, pw, ph,
    description='Mean total cluster RSS memory across all nodes during the test.'),

  // ── etcd ───────────────────────────────────────────────────────
  row('etcd', 166),
  versionBar('etcd DB Size', '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'bytes', 0, 167, pw, ph,
    description='Mean etcd MVCC database total size. Reflects Kubernetes object storage growth from PipelineRun/TaskRun creation.'),
  versionBar('etcd Request Duration', '__measurements_etcdRequestDurationSecondsAverage_mean', 's', 0, 175, pw, ph,
    description='Mean etcd request latency. High latency indicates etcd is under pressure from the volume of Kubernetes API operations.'),
];

dashboard.new('Results Version Comparison (v2)')
+ dashboard.withUid('Results_Version_Comparison_v2')
+ dashboard.withDescription('Daily side-by-side version comparison of Tekton Results ingestion, API performance, and component resource usage. Test ID 425.')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, versionVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['results', 'version-comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
