local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/chains-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local variantVar = common.variantVar;

local versionQuery = "SELECT DISTINCT %s AS version FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testIdPredicate];

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
local version2Var = createVersionVar('version2', 'Version 2', '1.23');

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

local versionPredicate(varName) = |||
        AND %s = '${%s}'
||| % [versionExpr, varName];

local testTotalPredicate = |||
        AND (label_values->>'__parameters_test_total')::INTEGER IN ($test_total)
|||;

local createComparisonQuery(fieldName, metricLabel, versionVar, additionalFields={}) =
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
    ||| % [fieldSelections, testIdPredicate, testTotalPredicate, versionPredicate(versionVar), fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

local comparisonPanel(title, fieldName, metricLabel, unit, gridX, gridY, gridW=12, gridH=8, versionVar='version1', additionalFields={}, description='', axisSoftMax=null) =
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
  + (if axisSoftMax != null then { fieldConfig+: { defaults+: { custom+: { axisSoftMax: axisSoftMax } } } } else {})
  + timeSeries.queryOptions.withTargets([
    createComparisonQuery(fieldName, metricLabel, versionVar, additionalFields),
  ]);

local panelPair(title, fieldName, metricLabel, unit, y, additionalFields={}, description='', axisSoftMax=null) = [
  comparisonPanel(title, fieldName, metricLabel, unit, 0, y, versionVar='version1', additionalFields=additionalFields, description=description, axisSoftMax=axisSoftMax),
  comparisonPanel(title, fieldName, metricLabel, unit, 12, y, versionVar='version2', additionalFields=additionalFields, description=description, axisSoftMax=axisSoftMax),
];

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  row('Signing Results', 0),
] + panelPair(
  'PipelineRun Signing Throughput',
  '__results_PipelineRuns_signing_throughput', 'pr_throughput', 'short', 1,
  description='PipelineRun signing throughput (signed runs per second). Higher is better.'
) + panelPair(
  'TaskRun Signing Throughput',
  '__results_TaskRuns_signing_throughput', 'tr_throughput', 'short', 9,
  description='TaskRun signing throughput (signed runs per second). Higher is better.'
) + panelPair(
  'PipelineRun Signing Duration',
  '__results_PipelineRuns_signing_duration', 'pr_sign_duration', 's', 17,
  description='Total wall-clock time of the PipelineRun signing window. Lower is better.'
) + panelPair(
  'TaskRun Signing Duration',
  '__results_TaskRuns_signing_duration', 'tr_sign_duration', 's', 25,
  description='Total wall-clock time of the TaskRun signing window. Lower is better.'
) + panelPair(
  'PipelineRun Signed Count',
  '__results_PipelineRuns_signing_count_signed_true', 'pr_signed', 'short', 33,
  additionalFields={
    pr_unsigned: '__results_PipelineRuns_signing_count_unsigned',
    pr_sign_failed: '__results_PipelineRuns_signing_count_signed_false',
  },
  description='PipelineRun signing outcome breakdown:\n- **pr_signed**: successfully signed\n- **pr_unsigned**: never signed\n- **pr_sign_failed**: signing failed'
) + panelPair(
  'TaskRun Signed Count',
  '__results_TaskRuns_signing_count_signed_true', 'tr_signed', 'short', 41,
  additionalFields={
    tr_unsigned: '__results_TaskRuns_signing_count_unsigned',
    tr_sign_failed: '__results_TaskRuns_signing_count_signed_false',
  },
  description='TaskRun signing outcome breakdown:\n- **tr_signed**: successfully signed\n- **tr_unsigned**: never signed\n- **tr_sign_failed**: signing failed'
) + [

  row('PipelineRun & TaskRun Counts', 49),
] + panelPair(
  'PipelineRun Succeeded',
  '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 50,
  description='Total PipelineRuns that completed successfully.'
) + panelPair(
  'PipelineRun Failed',
  '__results_PipelineRuns_count_failed', 'pr_failed', 'short', 58,
  description='Failed PipelineRuns. Should be 0.',
  axisSoftMax=5,
) + panelPair(
  'TaskRun Succeeded',
  '__results_TaskRuns_count_succeeded', 'tr_succeeded', 'short', 66,
  description='Total TaskRuns that completed successfully.'
) + panelPair(
  'TaskRun Failed',
  '__results_TaskRuns_count_failed', 'tr_failed', 'short', 74,
  description='Failed TaskRuns. Should be 0.',
  axisSoftMax=5,
) + [

  row('Chains Controller Metrics', 82),
] + panelPair(
  'Chains Controller CPU Usage',
  '__measurements_tektonChainsController_cpu_mean', 'cpu_mean', 'short', 83,
  additionalFields={ cpu_max: '__measurements_tektonChainsController_cpu_max' },
  description='Tekton Chains controller CPU usage.\n- **cpu_mean**: average\n- **cpu_max**: peak'
) + panelPair(
  'Chains Controller Memory Usage',
  '__measurements_tektonChainsController_memory_mean', 'mem_mean', 'bytes', 91,
  additionalFields={ mem_max: '__measurements_tektonChainsController_memory_max' },
  description='Tekton Chains controller memory (RSS) usage.\n- **mem_mean**: average\n- **mem_max**: peak'
) + panelPair(
  'Chains Controller Workqueue Depth',
  '__measurements_tektonChainsControllerWorkqueueDepth_mean', 'wq_mean', 'short', 99,
  additionalFields={ wq_max: '__measurements_tektonChainsControllerWorkqueueDepth_max' },
  description='Chains controller workqueue depth.\n- **wq_mean**: average\n- **wq_max**: peak\n\nSustained high values indicate a signing bottleneck.'
) + panelPair(
  'Chains Controller Restarts',
  '__measurements_tektonChainsController_restarts_range', 'chains_restarts', 'short', 107,
  description='Chains controller Pod restarts. Should be 0.',
  axisSoftMax=5,
) + [

  row('Cluster & API Server Metrics', 115),
] + panelPair(
  'Cluster CPU Usage',
  '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short', 116,
  description='Mean total CPU usage rate across all cluster nodes.'
) + panelPair(
  'Cluster Memory Usage',
  '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes', 124,
  description='Mean total RSS memory usage across all cluster nodes.'
) + panelPair(
  'API Server CPU (OpenShift / Kube)',
  '__measurements_apiserver_cpu_mean', 'ocp_apiserver_cpu', 'short', 132,
  additionalFields={ kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
  description='Mean CPU usage of API servers.'
) + panelPair(
  'API Server Memory (OpenShift / Kube)',
  '__measurements_apiserver_memory_mean', 'ocp_apiserver_mem', 'bytes', 140,
  additionalFields={ kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
  description='Mean memory usage of API servers.'
) + [

  row('etcd Metrics', 148),
] + panelPair(
  'etcd DB Size (total / in-use)',
  '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes', 149,
  additionalFields={ db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
  description='Mean etcd MVCC database size.\n- **db_total**: total allocated\n- **db_in_use**: live data'
) + panelPair(
  'etcd Request Duration (mean / max)',
  '__measurements_etcdRequestDurationSecondsAverage_mean', 'req_duration_mean', 's', 157,
  additionalFields={ req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
  description='etcd request latency.\n- **req_duration_mean**: average\n- **req_duration_max**: worst-case peak'
) + [

  row('Component Restarts', 165),
] + panelPair(
  'Infrastructure Restarts',
  '__measurements_etcd_restarts_range', 'etcd', 'short', 166,
  additionalFields={
    apiserver: '__measurements_apiserver_restarts_range',
    kube_apiserver: '__measurements_kubeApiserver_restarts_range',
  },
  description='Restart counts for infrastructure components. All should be 0.',
  axisSoftMax=5,
) + panelPair(
  'Tekton Component Restarts',
  '__measurements_tektonPipelinesController_restarts_range', 'pipelines_ctrl', 'short', 174,
  additionalFields={
    pipelines_webhook: '__measurements_tektonPipelinesWebhook_restarts_range',
    proxy_webhook: '__measurements_tektonOperatorProxyWebhook_restarts_range',
  },
  description='Restart counts for Tekton Pipelines components. All should be 0.',
  axisSoftMax=5,
) + panelPair(
  'Scheduler Pending Pods',
  '__measurements_schedulerPendingPodsCount_range', 'pending_pods', 'short', 182,
  description='Range of pending pods in the kube-scheduler queue.',
  axisSoftMax=5,
);

dashboard.new('Chains Signing Performance Comparison')
+ dashboard.withUid('Chains_Signing_Performance_Comparison')
+ dashboard.withDescription('Side-by-side comparison of two versions for the same variant. Select a variant, pick two versions, and see their Chains signing metrics mirrored left/right. Includes historical data from legacy test 418.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, version1Var, version2Var, testTotalVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['chains', 'comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
