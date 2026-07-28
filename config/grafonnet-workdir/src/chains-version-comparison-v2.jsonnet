local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/chains-common.libsonnet';
local versionBarLib = import 'lib/version-bar-common.libsonnet';

local dashboard = grafonnet.dashboard;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local variantVar = common.variantVar;

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Select versions to compare. Use All to include every version.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT %s AS version FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testIdPredicate],
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 0,
};

local testTotalVar = {
  type: 'query',
  name: 'test_total',
  label: 'Test Total',
  description: 'Select a single test total to compare versions at.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_total')::INTEGER AS test_total FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__parameters_test_total' ORDER BY test_total" % testIdPredicate,
  multi: false,
  includeAll: false,
  current: { text: '500', value: '500' },
  refresh: 2,
  sort: 3,
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
        WHERE %s
          AND $__timeFilter(start)
          AND %s IN ($version)
          AND (label_values->>'__parameters_test_total')::INTEGER = ${test_total}::INTEGER
          AND label_values ? '%s'
      )
      SELECT day, version, %s(val) AS value
      FROM daily
      GROUP BY day, version
      ORDER BY MIN(day_date),
        CASE WHEN version = 'nightly' THEN 0 ELSE 1 END,
        version ASC
    ||| % [versionExpr, fieldName, testIdPredicate, versionExpr, fieldName, agg],
    format: 'table',
    refId: 'A',
  };

local row = versionBarLib.row;

local versionBar(title, fieldName, unit, x, y, w, h, description='', agg='AVG', axisSoftMax=null) =
  versionBarLib.versionBar(createQuery, title, fieldName, unit, x, y, w, h, description, agg, axisSoftMax);

local pw = 24;
local ph = 8;

local allPanels = [
  // ── Signing Results ─────────────────────────────────────────
  row('Signing Results', 0),
  versionBar('PipelineRun Signing Throughput', '__results_PipelineRuns_signing_throughput', 'short', 0, 1, pw, ph,
    description='PipelineRun signing throughput per version per day (signed/sec). Higher is better.'),
  versionBar('TaskRun Signing Throughput', '__results_TaskRuns_signing_throughput', 'short', 0, 9, pw, ph,
    description='TaskRun signing throughput per version per day (signed/sec). Higher is better.'),
  versionBar('PipelineRun Signing Duration', '__results_PipelineRuns_signing_duration', 's', 0, 17, pw, ph,
    description='Total PipelineRun signing window duration per version per day. Lower is better.'),
  versionBar('TaskRun Signing Duration', '__results_TaskRuns_signing_duration', 's', 0, 25, pw, ph,
    description='Total TaskRun signing window duration per version per day. Lower is better.'),
  versionBar('PipelineRun Signed Count', '__results_PipelineRuns_signing_count_signed_true', 'short', 0, 33, pw, ph,
    description='PipelineRuns signed successfully per version per day.', agg='SUM'),
  versionBar('PipelineRun Unsigned', '__results_PipelineRuns_signing_count_unsigned', 'short', 0, 41, pw, ph,
    description='PipelineRuns that remained unsigned per version per day. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('TaskRun Signed Count', '__results_TaskRuns_signing_count_signed_true', 'short', 0, 49, pw, ph,
    description='TaskRuns signed successfully per version per day.', agg='SUM'),
  versionBar('TaskRun Unsigned', '__results_TaskRuns_signing_count_unsigned', 'short', 0, 57, pw, ph,
    description='TaskRuns that remained unsigned per version per day. Should be 0.', agg='SUM', axisSoftMax=5),

  // ── PipelineRun / TaskRun Counts ──────────────────────────────
  row('PipelineRun & TaskRun Counts', 65),
  versionBar('PipelineRun Succeeded', '__results_PipelineRuns_count_succeeded', 'short', 0, 66, pw, ph,
    description='Successful PipelineRuns per version per day.', agg='SUM'),
  versionBar('PipelineRun Failed', '__results_PipelineRuns_count_failed', 'short', 0, 74, pw, ph,
    description='Failed PipelineRuns per version per day. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('TaskRun Succeeded', '__results_TaskRuns_count_succeeded', 'short', 0, 82, pw, ph,
    description='Successful TaskRuns per version per day.', agg='SUM'),
  versionBar('TaskRun Failed', '__results_TaskRuns_count_failed', 'short', 0, 90, pw, ph,
    description='Failed TaskRuns per version per day. Should be 0.', agg='SUM', axisSoftMax=5),

  // ── Chains Controller Metrics ─────────────────────────────────
  row('Chains Controller Metrics', 98),
  versionBar('Chains Controller CPU (mean)', '__measurements_tektonChainsController_cpu_mean', 'short', 0, 99, pw, ph,
    description='Tekton Chains controller mean CPU per version per day.'),
  versionBar('Chains Controller Memory (mean)', '__measurements_tektonChainsController_memory_mean', 'bytes', 0, 107, pw, ph,
    description='Tekton Chains controller mean memory (RSS) per version per day.'),
  versionBar('Chains Controller Workqueue Depth', '__measurements_tektonChainsControllerWorkqueueDepth_mean', 'short', 0, 115, pw, ph,
    description='Chains controller mean workqueue depth per version per day. High values indicate a signing bottleneck.'),
  versionBar('Chains Controller Restarts', '__measurements_tektonChainsController_restarts_range', 'short', 0, 123, pw, ph,
    description='Chains controller restarts per version per day. Should be 0.', agg='SUM', axisSoftMax=5),

  // ── Cluster & API Server Metrics ──────────────────────────────
  row('Cluster & API Server', 131),
  versionBar('Cluster CPU', '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'short', 0, 132, pw, ph,
    description='Mean total cluster CPU usage per version per day.'),
  versionBar('Cluster Memory', '__measurements_clusterMemoryUsageRssTotal_mean', 'bytes', 0, 140, pw, ph,
    description='Mean total cluster RSS memory per version per day.'),
  versionBar('API Server CPU', '__measurements_apiserver_cpu_mean', 'short', 0, 148, pw, ph,
    description='OpenShift API server mean CPU per version per day.'),
  versionBar('API Server Memory', '__measurements_apiserver_memory_mean', 'bytes', 0, 156, pw, ph,
    description='OpenShift API server mean memory per version per day.'),

  // ── etcd ──────────────────────────────────────────────────────
  row('etcd', 164),
  versionBar('etcd DB Size', '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'bytes', 0, 165, pw, ph,
    description='Mean etcd MVCC database total size per version per day.'),
  versionBar('etcd Request Duration', '__measurements_etcdRequestDurationSecondsAverage_mean', 's', 0, 173, pw, ph,
    description='Mean etcd request latency per version per day.'),
  versionBar('etcd Restarts', '__measurements_etcd_restarts_range', 'short', 0, 181, pw, ph,
    description='etcd Pod restarts per version per day. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('Scheduler Pending Pods', '__measurements_schedulerPendingPodsCount_range', 'short', 0, 189, pw, ph,
    description='Pending pods in kube-scheduler queue per version per day.', agg='SUM', axisSoftMax=5),
];

dashboard.new('Chains Version Comparison (v2)')
+ dashboard.withUid('Chains_Version_Comparison_v2')
+ dashboard.withDescription('Daily side-by-side version comparison of Chains signing performance. Includes historical data from legacy test 418 and new per-variant tests (427-430).')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, versionVar, testTotalVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['chains', 'version-comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
