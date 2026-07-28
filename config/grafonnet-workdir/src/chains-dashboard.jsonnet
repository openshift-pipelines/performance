local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/chains-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local variantVar = common.variantVar;

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Filter to a specific version to track its trend over time.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT %s AS version FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testIdPredicate],
  multi: false,
  includeAll: false,
  current: { text: 'nightly', value: 'nightly' },
  refresh: 2,
  sort: 0,
};

local testTotalVar = {
  type: 'query',
  name: 'test_total',
  label: 'Test Total',
  description: 'Filter by total PipelineRuns count (500, 1000).',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_total')::INTEGER AS test_total FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__parameters_test_total' ORDER BY test_total" % testIdPredicate,
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 3,
};

local versionPredicate = |||
        AND %s = '${version}'
||| % versionExpr;

local testTotalPredicate = |||
        AND (label_values->>'__parameters_test_total')::INTEGER IN ($test_total)
|||;

local createComplexQuery(fieldName, metricLabel, additionalFields={}) =
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
        '%s @ t' || test_total AS metric,
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
          (label_values->>'__parameters_test_total')::INTEGER AS test_total,
          %s
        FROM data
        WHERE %s
          AND $__timeFilter(start)
          %s
          %s
          AND %s
        GROUP BY day, test_total
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testIdPredicate, testTotalPredicate, versionPredicate, fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

local trendPanel(title, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, additionalFields={}, description='', axisSoftMax=null) =
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
    createComplexQuery(fieldName, metricLabel, additionalFields),
  ]);

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  // ── Signing Results ─────────────────────────────────────────
  row('Signing Results', 0),
  trendPanel(
    'PipelineRun Signing Throughput',
    '__results_PipelineRuns_signing_throughput',
    'pr_throughput',
    'short',
    0, 1, 12, 8,
    description='PipelineRun signing throughput (signed runs per second). Higher is better. Computed as signed_count / signing_window_duration.'
  ),
  trendPanel(
    'TaskRun Signing Throughput',
    '__results_TaskRuns_signing_throughput',
    'tr_throughput',
    'short',
    12, 1, 12, 8,
    description='TaskRun signing throughput (signed runs per second). Higher is better.'
  ),
  trendPanel(
    'PipelineRun Signing Duration',
    '__results_PipelineRuns_signing_duration',
    'pr_sign_duration',
    's',
    0, 9, 12, 8,
    description='Total wall-clock time of the PipelineRun signing window (last signed_at - first signed_at). Lower is better.'
  ),
  trendPanel(
    'TaskRun Signing Duration',
    '__results_TaskRuns_signing_duration',
    'tr_sign_duration',
    's',
    12, 9, 12, 8,
    description='Total wall-clock time of the TaskRun signing window. Lower is better.'
  ),
  trendPanel(
    'PipelineRun Signed Count',
    '__results_PipelineRuns_signing_count_signed_true',
    'pr_signed',
    'short',
    0, 17, 12, 8,
    {
      pr_unsigned: '__results_PipelineRuns_signing_count_unsigned',
      pr_sign_failed: '__results_PipelineRuns_signing_count_signed_false',
    },
    description='PipelineRun signing outcome breakdown:\n- **pr_signed**: successfully signed\n- **pr_unsigned**: never signed (still pending)\n- **pr_sign_failed**: signing attempted but failed\n\nAll runs should be signed; any unsigned or failed entries indicate a problem.'
  ),
  trendPanel(
    'TaskRun Signed Count',
    '__results_TaskRuns_signing_count_signed_true',
    'tr_signed',
    'short',
    12, 17, 12, 8,
    {
      tr_unsigned: '__results_TaskRuns_signing_count_unsigned',
      tr_sign_failed: '__results_TaskRuns_signing_count_signed_false',
    },
    description='TaskRun signing outcome breakdown:\n- **tr_signed**: successfully signed\n- **tr_unsigned**: never signed\n- **tr_sign_failed**: signing failed'
  ),

  // ── PipelineRun / TaskRun Counts ──────────────────────────────
  row('PipelineRun & TaskRun Counts', 25),
  trendPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded',
    'pr_succeeded',
    'short',
    0, 26, 12, 8,
    description='Total PipelineRuns that completed successfully, averaged per day per test_total.'
  ),
  trendPanel(
    'PipelineRun Failed',
    '__results_PipelineRuns_count_failed',
    'pr_failed',
    'short',
    12, 26, 12, 8,
    description='Total PipelineRuns that failed. Should be 0.',
    axisSoftMax=5,
  ),
  trendPanel(
    'TaskRun Succeeded',
    '__results_TaskRuns_count_succeeded',
    'tr_succeeded',
    'short',
    0, 34, 12, 8,
    description='Total TaskRuns that completed successfully.'
  ),
  trendPanel(
    'TaskRun Failed',
    '__results_TaskRuns_count_failed',
    'tr_failed',
    'short',
    12, 34, 12, 8,
    description='Total TaskRuns that failed. Should be 0.',
    axisSoftMax=5,
  ),

  // ── Chains Controller Metrics ─────────────────────────────────
  row('Chains Controller Metrics', 42),
  trendPanel(
    'Chains Controller CPU Usage',
    '__measurements_tektonChainsController_cpu_mean',
    'cpu_mean',
    'short',
    0, 43, 12, 8,
    { cpu_max: '__measurements_tektonChainsController_cpu_max' },
    description='Tekton Chains controller CPU usage in CPU cores.\n- **cpu_mean**: average over the test window\n- **cpu_max**: peak usage'
  ),
  trendPanel(
    'Chains Controller Memory Usage',
    '__measurements_tektonChainsController_memory_mean',
    'mem_mean',
    'bytes',
    12, 43, 12, 8,
    { mem_max: '__measurements_tektonChainsController_memory_max' },
    description='Tekton Chains controller memory (RSS) usage.\n- **mem_mean**: average\n- **mem_max**: peak'
  ),
  trendPanel(
    'Chains Controller Workqueue Depth',
    '__measurements_tektonChainsControllerWorkqueueDepth_mean',
    'wq_mean',
    'short',
    0, 51, 12, 8,
    { wq_max: '__measurements_tektonChainsControllerWorkqueueDepth_max' },
    description='Chains controller workqueue depth.\n- **wq_mean**: average queue depth\n- **wq_max**: peak queue depth\n\nSustained high values indicate a signing bottleneck.'
  ),
  trendPanel(
    'Chains Controller Restarts',
    '__measurements_tektonChainsController_restarts_range',
    'chains_restarts',
    'short',
    12, 51, 12, 8,
    description='Chains controller Pod restarts during the test. Should be 0.',
    axisSoftMax=5,
  ),

  // ── Cluster & API Server Metrics ──────────────────────────────
  row('Cluster & API Server Metrics', 59),
  trendPanel(
    'Cluster CPU Usage',
    '__measurements_clusterCpuUsageSecondsTotalRate_mean',
    'cluster_cpu',
    'short',
    0, 60, 12, 8,
    description='Mean total CPU usage rate across all cluster nodes, in CPU cores.'
  ),
  trendPanel(
    'Cluster Memory Usage',
    '__measurements_clusterMemoryUsageRssTotal_mean',
    'cluster_mem',
    'bytes',
    12, 60, 12, 8,
    description='Mean total RSS memory usage across all cluster nodes.'
  ),
  trendPanel(
    'API Server CPU (OpenShift / Kube)',
    '__measurements_apiserver_cpu_mean',
    'ocp_apiserver_cpu',
    'short',
    0, 68, 12, 8,
    { kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
    description='Mean CPU usage of the OpenShift and Kubernetes API servers.'
  ),
  trendPanel(
    'API Server Memory (OpenShift / Kube)',
    '__measurements_apiserver_memory_mean',
    'ocp_apiserver_mem',
    'bytes',
    12, 68, 12, 8,
    { kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
    description='Mean memory usage of the OpenShift and Kubernetes API servers.'
  ),

  // ── etcd Metrics ──────────────────────────────────────────────
  row('etcd Metrics', 76),
  trendPanel(
    'etcd DB Size (total / in-use)',
    '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean',
    'db_total',
    'bytes',
    0, 77, 12, 8,
    { db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
    description='Mean etcd MVCC database size.\n- **db_total**: total allocated size on disk\n- **db_in_use**: live data size\n\nChains stores signing metadata in annotations, which increases etcd load.'
  ),
  trendPanel(
    'etcd Request Duration (mean / max)',
    '__measurements_etcdRequestDurationSecondsAverage_mean',
    'req_duration_mean',
    's',
    12, 77, 12, 8,
    { req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
    description='Mean and peak etcd request duration.\n- **req_duration_mean**: average latency\n- **req_duration_max**: worst-case latency'
  ),

  // ── Restarts ──────────────────────────────────────────────────
  row('Component Restarts', 85),
  trendPanel(
    'Infrastructure Restarts',
    '__measurements_etcd_restarts_range',
    'etcd',
    'short',
    0, 86, 12, 8,
    {
      apiserver: '__measurements_apiserver_restarts_range',
      kube_apiserver: '__measurements_kubeApiserver_restarts_range',
    },
    description='Restart counts for infrastructure components. All should be 0.',
    axisSoftMax=5,
  ),
  trendPanel(
    'Tekton Component Restarts',
    '__measurements_tektonPipelinesController_restarts_range',
    'pipelines_ctrl',
    'short',
    12, 86, 12, 8,
    {
      pipelines_webhook: '__measurements_tektonPipelinesWebhook_restarts_range',
      proxy_webhook: '__measurements_tektonOperatorProxyWebhook_restarts_range',
    },
    description='Restart counts for Tekton Pipelines components. All should be 0.',
    axisSoftMax=5,
  ),
  trendPanel(
    'Scheduler Pending Pods',
    '__measurements_schedulerPendingPodsCount_range',
    'pending_pods',
    'short',
    0, 94, 12, 8,
    description='Range of pending pods in the kube-scheduler queue.',
    axisSoftMax=5,
  ),
];

dashboard.new('Chains Signing Performance Dashboard')
+ dashboard.withUid('Chains_Signing_Performance')
+ dashboard.withDescription('OpenShift Pipelines Chains signing performance trends per variant and version. Includes historical data from legacy test 418 and new per-variant tests (427-430). Select a variant, version, and test total to track regressions over time.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, versionVar, testTotalVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['chains', 'trend', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
