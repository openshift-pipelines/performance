local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

// ─── Constants ───────────────────────────────────────────────────────────────
local testId = 418;
local versionQuery = "SELECT DISTINCT (label_values->>'__deployment_version') AS __text FROM data WHERE horreum_testid = %g AND label_values ? '__deployment_version' AND (label_values->>'__deployment_version') IS NOT NULL AND (label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = false) AND label_values ? '__results_PipelineRuns_signing_throughput' ORDER BY __text" % testId;

// ─── Template variables ─────────────────────────────────────────────────────
local datasourceVar =
  grafonnet.dashboard.variable.datasource.new(
    'datasource',
    'grafana-postgresql-datasource',
  )
  + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
  + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
  + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for Chains metrics')
  + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource');

local createVersionVar(name, label, defaultVersion) = {
  type: 'query',
  name: name,
  label: label,
  description: '%s for comparison' % label,
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: versionQuery,
  multi: false,
  includeAll: false,
  current: { text: defaultVersion, value: defaultVersion },
  refresh: 1,
  sort: 4,
};

local version1Var = createVersionVar('version1', 'Version 1', '1.22');
local version2Var = createVersionVar('version2', 'Version 2', '1.21');

local deployConfigVar = {
  type: 'custom',
  name: 'deploy_config',
  label: 'Deployment Configuration',
  description: 'Standard, HA, QBT, or HA+QBT.',
  query: 'Standard : standard,HA : ha,QBT (non-HA) : qbt,HA + QBT : ha-qbt',
  multi: false,
  includeAll: false,
  current: { text: 'Standard', value: 'standard' },
  options: [
    { text: 'Standard', value: 'standard', selected: true },
    { text: 'HA', value: 'ha', selected: false },
    { text: 'QBT (non-HA)', value: 'qbt', selected: false },
    { text: 'HA + QBT', value: 'ha-qbt', selected: false },
  ],
};

local testTotalVar = {
  type: 'query',
  name: 'test_total',
  label: 'Test Total',
  description: 'Filter by total PipelineRuns count (500, 1000, 1500).',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_total')::INTEGER AS test_total FROM data WHERE horreum_testid = %g AND label_values ? '__parameters_test_total' ORDER BY test_total" % testId,
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 3,
};

// ─── SQL predicates ─────────────────────────────────────────────────────────

local versionPredicate(varName) = |||
        AND label_values ? '__deployment_version'
        AND (label_values->>'__deployment_version') = '${%s}'
        AND label_values ? '__deployment_nightly'
        AND (label_values->>'__deployment_nightly')::BOOLEAN = false
||| % varName;

local deployConfigPredicate = |||
        AND (
          ('$deploy_config' = 'standard' AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false) AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('$deploy_config' = 'ha' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('$deploy_config' = 'qbt' AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false) AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
          OR ('$deploy_config' = 'ha-qbt' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
        )
|||;

local testTotalPredicate = |||
        AND (label_values->>'__parameters_test_total')::INTEGER IN ($test_total)
|||;

// ─── Query builders ─────────────────────────────────────────────────────────

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
        '%s @ ' || test_total AS metric,
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
        WHERE horreum_testid = %g
          AND $__timeFilter(start)
          %s
          %s
          %s
          AND %s
        GROUP BY day, test_total
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testId, testTotalPredicate, deployConfigPredicate, versionPredicate(versionVar), fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

// ─── Panel builders ─────────────────────────────────────────────────────────

local createComparisonPanel(title, fieldName, metricLabel, unit, gridX, gridY, gridW=12, gridH=8, versionVar='version1', additionalFields={}, description='') =
  timeSeries.new('%s - v${%s}' % [title, versionVar])
  + timeSeries.queryOptions.withDatasource(type='grafana-postgresql-datasource', uid='${datasource}')
  + (if description != '' then timeSeries.panelOptions.withDescription(description) else {})
  + timeSeries.gridPos.withX(gridX)
  + timeSeries.gridPos.withY(gridY)
  + timeSeries.gridPos.withW(gridW)
  + timeSeries.gridPos.withH(gridH)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(0)
  + timeSeries.fieldConfig.defaults.custom.withSpanNulls(false)
  + timeSeries.fieldConfig.defaults.custom.withShowPoints('always')
  + timeSeries.fieldConfig.defaults.custom.withPointSize(7)
  + timeSeries.standardOptions.withUnit(unit)
  + timeSeries.standardOptions.withMin(0)
  + timeSeries.queryOptions.withTargets([
    createComparisonQuery(fieldName, metricLabel, versionVar, additionalFields),
  ]);

local createPanelPair(title, fieldName, metricLabel, unit, y, additionalFields={}, description='') = [
  createComparisonPanel(title, fieldName, metricLabel, unit, 0, y, versionVar='version1', additionalFields=additionalFields, description=description),
  createComparisonPanel(title, fieldName, metricLabel, unit, 12, y, versionVar='version2', additionalFields=additionalFields, description=description),
];

local createRow(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

// ─── Dashboard panels ───────────────────────────────────────────────────────

local allPanels = [
  // ── Signing Results ─────────────────────────────────────────
  createRow('Signing Results', 0),
] + createPanelPair(
  'PipelineRun Signing Throughput',
  '__results_PipelineRuns_signing_throughput', 'pr_throughput', 'short', 1,
  description='PipelineRun signing throughput (signed runs per second). Higher is better.'
) + createPanelPair(
  'TaskRun Signing Throughput',
  '__results_TaskRuns_signing_throughput', 'tr_throughput', 'short', 9,
  description='TaskRun signing throughput (signed runs per second). Higher is better.'
) + createPanelPair(
  'PipelineRun Signing Duration',
  '__results_PipelineRuns_signing_duration', 'pr_sign_duration', 's', 17,
  description='Total wall-clock time of the PipelineRun signing window. Lower is better.'
) + createPanelPair(
  'TaskRun Signing Duration',
  '__results_TaskRuns_signing_duration', 'tr_sign_duration', 's', 25,
  description='Total wall-clock time of the TaskRun signing window. Lower is better.'
) + createPanelPair(
  'PipelineRun Signed Count',
  '__results_PipelineRuns_signing_count_signed_true', 'pr_signed', 'short', 33,
  additionalFields={
    pr_unsigned: '__results_PipelineRuns_signing_count_unsigned',
    pr_sign_failed: '__results_PipelineRuns_signing_count_signed_false',
  },
  description='PipelineRun signing outcome breakdown:\n- **pr_signed**: successfully signed\n- **pr_unsigned**: never signed\n- **pr_sign_failed**: signing failed'
) + createPanelPair(
  'TaskRun Signed Count',
  '__results_TaskRuns_signing_count_signed_true', 'tr_signed', 'short', 41,
  additionalFields={
    tr_unsigned: '__results_TaskRuns_signing_count_unsigned',
    tr_sign_failed: '__results_TaskRuns_signing_count_signed_false',
  },
  description='TaskRun signing outcome breakdown:\n- **tr_signed**: successfully signed\n- **tr_unsigned**: never signed\n- **tr_sign_failed**: signing failed'
) + [

  // ── PipelineRun / TaskRun Counts ──────────────────────────────
  createRow('PipelineRun & TaskRun Counts', 49),
] + createPanelPair(
  'PipelineRun Succeeded',
  '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 50,
  description='Total PipelineRuns that completed successfully.'
) + createPanelPair(
  'PipelineRun Failed',
  '__results_PipelineRuns_count_failed', 'pr_failed', 'short', 58,
  description='Total PipelineRuns that failed. Should be 0.'
) + createPanelPair(
  'TaskRun Succeeded',
  '__results_TaskRuns_count_succeeded', 'tr_succeeded', 'short', 66,
  description='Total TaskRuns that completed successfully.'
) + createPanelPair(
  'TaskRun Failed',
  '__results_TaskRuns_count_failed', 'tr_failed', 'short', 74,
  description='Total TaskRuns that failed. Should be 0.'
) + [

  // ── Chains Controller Metrics ─────────────────────────────────
  createRow('Chains Controller Metrics', 82),
] + createPanelPair(
  'Chains Controller CPU Usage',
  '__measurements_tektonChainsController_cpu_mean', 'cpu_mean', 'short', 83,
  additionalFields={ cpu_max: '__measurements_tektonChainsController_cpu_max' },
  description='Tekton Chains controller CPU usage.\n- **cpu_mean**: average\n- **cpu_max**: peak'
) + createPanelPair(
  'Chains Controller Memory Usage',
  '__measurements_tektonChainsController_memory_mean', 'mem_mean', 'bytes', 91,
  additionalFields={ mem_max: '__measurements_tektonChainsController_memory_max' },
  description='Tekton Chains controller memory (RSS) usage.\n- **mem_mean**: average\n- **mem_max**: peak'
) + createPanelPair(
  'Chains Controller Workqueue Depth',
  '__measurements_tektonChainsControllerWorkqueueDepth_mean', 'wq_mean', 'short', 99,
  additionalFields={ wq_max: '__measurements_tektonChainsControllerWorkqueueDepth_max' },
  description='Chains controller workqueue depth.\n- **wq_mean**: average\n- **wq_max**: peak\n\nSustained high values indicate a signing bottleneck.'
) + createPanelPair(
  'Chains Controller Restarts',
  '__measurements_tektonChainsController_restarts_range', 'chains_restarts', 'short', 107,
  description='Number of Chains controller Pod restarts. Should be 0.'
) + [

  // ── Cluster & API Server Metrics ──────────────────────────────
  createRow('Cluster & API Server Metrics', 115),
] + createPanelPair(
  'Cluster CPU Usage',
  '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short', 116,
  description='Mean total CPU usage rate across all cluster nodes.'
) + createPanelPair(
  'Cluster Memory Usage',
  '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes', 124,
  description='Mean total RSS memory usage across all cluster nodes.'
) + createPanelPair(
  'API Server CPU Usage (Mean)',
  '__measurements_apiserver_cpu_mean', 'apiserver_cpu', 'short', 132,
  additionalFields={ kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
  description='Mean CPU usage of API servers.\n- **apiserver_cpu**: openshift-apiserver\n- **kube_apiserver_cpu**: kube-apiserver'
) + createPanelPair(
  'API Server Memory Usage (Mean)',
  '__measurements_apiserver_memory_mean', 'apiserver_mem', 'bytes', 140,
  additionalFields={ kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
  description='Mean memory usage of API servers.'
) + [

  // ── etcd Metrics ──────────────────────────────────────────────
  createRow('etcd Metrics', 148),
] + createPanelPair(
  'etcd MVCC DB Size (Mean)',
  '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes', 149,
  additionalFields={ db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
  description='Mean etcd MVCC database size.\n- **db_total**: total allocated\n- **db_in_use**: live data'
) + createPanelPair(
  'etcd Request Duration',
  '__measurements_etcdRequestDurationSecondsAverage_mean', 'req_duration_mean', 's', 157,
  additionalFields={ req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
  description='Mean and peak etcd request durations.\n- **req_duration_mean**: average latency\n- **req_duration_max**: worst-case latency'
) + [

  // ── Restarts ──────────────────────────────────────────────────
  createRow('Component Restarts', 165),
] + createPanelPair(
  'Infrastructure Restarts',
  '__measurements_etcd_restarts_range', 'etcd', 'short', 166,
  additionalFields={
    apiserver: '__measurements_apiserver_restarts_range',
    kube_apiserver: '__measurements_kubeApiserver_restarts_range',
  },
  description='Restart counts for infrastructure components. All should be 0.'
) + createPanelPair(
  'Tekton Component Restarts',
  '__measurements_tektonPipelinesController_restarts_range', 'pipelines_ctrl', 'short', 174,
  additionalFields={
    pipelines_webhook: '__measurements_tektonPipelinesWebhook_restarts_range',
    proxy_webhook: '__measurements_tektonOperatorProxyWebhook_restarts_range',
  },
  description='Restart counts for Tekton Pipelines components. All should be 0.'
) + createPanelPair(
  'Scheduler Pending Pods',
  '__measurements_schedulerPendingPodsCount_range', 'pending_pods', 'short', 182,
  description='Range of pending pods in the kube-scheduler queue.'
);

// ─── Dashboard ──────────────────────────────────────────────────────────────

dashboard.new('Chains Signing Performance Comparison Dashboard')
+ dashboard.withUid('Chains_Signing_Performance_Comparison')
+ dashboard.withDescription('Side-by-side comparison of Chains signing performance metrics across different released versions. Select two non-nightly versions to compare.')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, deployConfigVar, version1Var, version2Var, testTotalVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.graphTooltip.withSharedCrosshair()
