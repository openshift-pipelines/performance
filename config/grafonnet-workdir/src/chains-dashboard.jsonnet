local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

// ─── Constants ───────────────────────────────────────────────────────────────
local testId = 418;

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

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Filter by Pipelines version.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT CASE WHEN (label_values ? '__deployment_nightly') AND (label_values->>'__deployment_nightly')::BOOLEAN = true THEN 'nightly' ELSE (label_values->>'__deployment_version') END AS version FROM data WHERE horreum_testid = %g AND label_values ? '__deployment_version' AND (label_values->>'__deployment_version') IS NOT NULL AND label_values ? '__results_PipelineRuns_signing_throughput' ORDER BY version" % testId,
  multi: false,
  includeAll: false,
  current: { text: 'nightly', value: 'nightly' },
  refresh: 2,
  sort: 3,
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

// ─── SQL predicates (injected into every query) ─────────────────────────────

local versionPredicate = |||
        AND (
          ('$version' = 'nightly' AND (label_values ? '__deployment_nightly') AND (label_values->>'__deployment_nightly')::BOOLEAN = true)
          OR ('$version' != 'nightly' AND (label_values->>'__deployment_version') = '$version')
        )
|||;

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
    ||| % [fieldSelections, testId, testTotalPredicate, deployConfigPredicate, versionPredicate, fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

// ─── Panel builders ─────────────────────────────────────────────────────────

local createPanel(title, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, additionalFields={}, description='') =
  timeSeries.new(title)
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
    createQuery(fieldName, metricLabel, additionalFields),
  ]);

local createRow(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

// ─── Dashboard panels ───────────────────────────────────────────────────────

local allPanels = [
  // ── Signing Results ─────────────────────────────────────────
  createRow('Signing Results', 0),
  createPanel(
    'PipelineRun Signing Throughput',
    '__results_PipelineRuns_signing_throughput',
    'pr_throughput',
    'short',
    0, 1, 12, 8,
    description='PipelineRun signing throughput (signed runs per second). Higher is better. Computed as signed_count / signing_window_duration.'
  ),
  createPanel(
    'TaskRun Signing Throughput',
    '__results_TaskRuns_signing_throughput',
    'tr_throughput',
    'short',
    12, 1, 12, 8,
    description='TaskRun signing throughput (signed runs per second). Higher is better. Computed as signed_count / signing_window_duration.'
  ),
  createPanel(
    'PipelineRun Signing Duration',
    '__results_PipelineRuns_signing_duration',
    'pr_sign_duration',
    's',
    0, 9, 12, 8,
    description='Total wall-clock time of the PipelineRun signing window (last signed_at - first signed_at). Lower is better — indicates how quickly Chains processes the entire batch.'
  ),
  createPanel(
    'TaskRun Signing Duration',
    '__results_TaskRuns_signing_duration',
    'tr_sign_duration',
    's',
    12, 9, 12, 8,
    description='Total wall-clock time of the TaskRun signing window (last signed_at - first signed_at). Lower is better.'
  ),
  createPanel(
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
  createPanel(
    'TaskRun Signed Count',
    '__results_TaskRuns_signing_count_signed_true',
    'tr_signed',
    'short',
    12, 17, 12, 8,
    {
      tr_unsigned: '__results_TaskRuns_signing_count_unsigned',
      tr_sign_failed: '__results_TaskRuns_signing_count_signed_false',
    },
    description='TaskRun signing outcome breakdown:\n- **tr_signed**: successfully signed\n- **tr_unsigned**: never signed (still pending)\n- **tr_sign_failed**: signing attempted but failed'
  ),

  // ── PipelineRun / TaskRun Counts ──────────────────────────────
  createRow('PipelineRun & TaskRun Counts', 25),
  createPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded',
    'pr_succeeded',
    'short',
    0, 26, 12, 8,
    description='Total PipelineRuns that completed successfully, averaged per day per test_total.'
  ),
  createPanel(
    'PipelineRun Failed',
    '__results_PipelineRuns_count_failed',
    'pr_failed',
    'short',
    12, 26, 12, 8,
    description='Total PipelineRuns that failed. Should be 0.'
  ),
  createPanel(
    'TaskRun Succeeded',
    '__results_TaskRuns_count_succeeded',
    'tr_succeeded',
    'short',
    0, 34, 12, 8,
    description='Total TaskRuns that completed successfully.'
  ),
  createPanel(
    'TaskRun Failed',
    '__results_TaskRuns_count_failed',
    'tr_failed',
    'short',
    12, 34, 12, 8,
    description='Total TaskRuns that failed. Should be 0.'
  ),

  // ── Chains Controller Metrics ─────────────────────────────────
  createRow('Chains Controller Metrics', 42),
  createPanel(
    'Chains Controller CPU Usage',
    '__measurements_tektonChainsController_cpu_mean',
    'cpu_mean',
    'short',
    0, 43, 12, 8,
    { cpu_max: '__measurements_tektonChainsController_cpu_max' },
    description='Tekton Chains controller CPU usage in CPU cores (e.g. 0.5 = 500 millicores).\n- **cpu_mean**: average over the test window\n- **cpu_max**: peak usage\n\nHigh CPU indicates signing is compute-bound (e.g. cryptographic operations).'
  ),
  createPanel(
    'Chains Controller Memory Usage',
    '__measurements_tektonChainsController_memory_mean',
    'mem_mean',
    'bytes',
    12, 43, 12, 8,
    { mem_max: '__measurements_tektonChainsController_memory_max' },
    description='Tekton Chains controller memory (RSS) usage.\n- **mem_mean**: average over the test window\n- **mem_max**: peak usage\n\nGrowing memory may indicate leaks or large attestation payloads.'
  ),
  createPanel(
    'Chains Controller Workqueue Depth',
    '__measurements_tektonChainsControllerWorkqueueDepth_mean',
    'wq_mean',
    'short',
    0, 51, 12, 8,
    { wq_max: '__measurements_tektonChainsControllerWorkqueueDepth_max' },
    description='Chains controller workqueue depth.\n- **wq_mean**: average queue depth during the test\n- **wq_max**: peak queue depth\n\nA growing workqueue means the controller cannot sign runs fast enough. Sustained high values indicate a bottleneck.'
  ),
  createPanel(
    'Chains Controller Restarts',
    '__measurements_tektonChainsController_restarts_range',
    'chains_restarts',
    'short',
    12, 51, 12, 8,
    description='Number of Chains controller Pod restarts during the test. Should be 0. Restarts during signing cause missed or delayed signatures.'
  ),

  // ── Cluster & API Server Metrics ──────────────────────────────
  createRow('Cluster & API Server Metrics', 59),
  createPanel(
    'Cluster CPU Usage',
    '__measurements_clusterCpuUsageSecondsTotalRate_mean',
    'cluster_cpu',
    'short',
    0, 60, 12, 8,
    description='Mean total CPU usage rate across all cluster nodes during the test, in CPU cores.'
  ),
  createPanel(
    'Cluster Memory Usage',
    '__measurements_clusterMemoryUsageRssTotal_mean',
    'cluster_mem',
    'bytes',
    12, 60, 12, 8,
    description='Mean total RSS memory usage across all cluster nodes during the test.'
  ),
  createPanel(
    'API Server CPU Usage (Mean)',
    '__measurements_apiserver_cpu_mean',
    'apiserver_cpu',
    'short',
    0, 68, 12, 8,
    { kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
    description='Mean CPU usage of OpenShift and Kubernetes API servers.\n- **apiserver_cpu**: openshift-apiserver\n- **kube_apiserver_cpu**: kube-apiserver'
  ),
  createPanel(
    'API Server Memory Usage (Mean)',
    '__measurements_apiserver_memory_mean',
    'apiserver_mem',
    'bytes',
    12, 68, 12, 8,
    { kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
    description='Mean memory usage of OpenShift and Kubernetes API servers.'
  ),

  // ── etcd Metrics ──────────────────────────────────────────────
  createRow('etcd Metrics', 76),
  createPanel(
    'etcd MVCC DB Size (Mean)',
    '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean',
    'db_total',
    'bytes',
    0, 77, 12, 8,
    { db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
    description='Mean etcd MVCC database size.\n- **db_total**: total allocated size on disk\n- **db_in_use**: logical size of live data\n\nChains stores signing metadata in annotations, which increases etcd load.'
  ),
  createPanel(
    'etcd Request Duration',
    '__measurements_etcdRequestDurationSecondsAverage_mean',
    'req_duration_mean',
    's',
    12, 77, 12, 8,
    { req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
    description='Mean and peak etcd request duration.\n- **req_duration_mean**: average latency\n- **req_duration_max**: worst-case latency\n\nHigh values indicate etcd pressure from Chains annotation writes.'
  ),

  // ── Restarts ──────────────────────────────────────────────────
  createRow('Component Restarts', 85),
  createPanel(
    'Infrastructure Restarts',
    '__measurements_etcd_restarts_range',
    'etcd',
    'short',
    0, 86, 12, 8,
    {
      apiserver: '__measurements_apiserver_restarts_range',
      kube_apiserver: '__measurements_kubeApiserver_restarts_range',
    },
    description='Restart counts for infrastructure components. All should be 0.'
  ),
  createPanel(
    'Tekton Component Restarts',
    '__measurements_tektonPipelinesController_restarts_range',
    'pipelines_ctrl',
    'short',
    12, 86, 12, 8,
    {
      pipelines_webhook: '__measurements_tektonPipelinesWebhook_restarts_range',
      proxy_webhook: '__measurements_tektonOperatorProxyWebhook_restarts_range',
    },
    description='Restart counts for Tekton Pipelines components. All should be 0.\n\nNote: Chains controller restarts are shown separately in the Chains Controller section above.'
  ),
  createPanel(
    'Scheduler Pending Pods',
    '__measurements_schedulerPendingPodsCount_range',
    'pending_pods',
    'short',
    0, 94, 12, 8,
    description='Range of pending pods in the kube-scheduler queue. High values indicate scheduling pressure.'
  ),
];

// ─── Dashboard ──────────────────────────────────────────────────────────────

dashboard.new('Chains Signing Performance Dashboard')
+ dashboard.withUid('Chains_Signing_Performance')
+ dashboard.withDescription('OpenShift Pipelines Chains signing performance. Tracks signing throughput, duration, Chains controller resources, and cluster health across different test_total values (500, 1000, 1500).')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, deployConfigVar, versionVar, testTotalVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.graphTooltip.withSharedCrosshair()
