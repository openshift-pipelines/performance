local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

// ─── Constants ───────────────────────────────────────────────────────────────
local testId = 391;
local versionQuery = "SELECT DISTINCT (label_values->>'__deployment_version') AS __text FROM data WHERE horreum_testid = %g AND label_values ? '__deployment_version' AND (label_values->>'__deployment_version') IS NOT NULL AND (label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = false) ORDER BY __text" % testId;

// ─── Template variables ─────────────────────────────────────────────────────
local datasourceVar =
  grafonnet.dashboard.variable.datasource.new(
    'datasource',
    'grafana-postgresql-datasource',
  )
  + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
  + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
  + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for pipeline metrics')
  + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource');

local version1Var = {
  type: 'query',
  name: 'version1',
  label: 'Version 1',
  description: 'First version for comparison',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: versionQuery,
  multi: false,
  includeAll: false,
  current: { text: '1.19', value: '1.19' },
  refresh: 2,
  sort: 3,
};

local version2Var = {
  type: 'query',
  name: 'version2',
  label: 'Version 2',
  description: 'Second version for comparison',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: versionQuery,
  multi: false,
  includeAll: false,
  current: { text: '1.20', value: '1.20' },
  refresh: 2,
  sort: 3,
};

local deployConfigVar = {
  type: 'custom',
  name: 'deploy_config',
  label: 'Deployment Configuration',
  description: 'Filter by deployment configuration: Standard, HA, QBT, or HA+QBT.',
  query: 'Standard : standard,HA - Deployments : ha-deployments,HA - StatefulSets : ha-statefulsets,QBT (non-HA) : qbt,HA + QBT - Deployments : ha-qbt-deployments',
  multi: false,
  includeAll: false,
  current: { text: 'Standard', value: 'standard' },
  options: [
    { text: 'Standard', value: 'standard', selected: true },
    { text: 'HA - Deployments', value: 'ha-deployments', selected: false },
    { text: 'HA - StatefulSets', value: 'ha-statefulsets', selected: false },
    { text: 'QBT (non-HA)', value: 'qbt', selected: false },
    { text: 'HA + QBT - Deployments', value: 'ha-qbt-deployments', selected: false },
  ],
};

local concurrencyVar = {
  type: 'query',
  name: 'concurrency',
  label: 'Concurrency',
  description: 'Filter by concurrency level. Select one or more, or All.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency FROM data WHERE horreum_testid = %g AND label_values ? '__parameters_test_concurrent' ORDER BY concurrency" % testId,
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
          OR ('$deploy_config' = 'ha-deployments' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments' AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('$deploy_config' = 'ha-statefulsets' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'statefulSets' AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('$deploy_config' = 'qbt' AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false) AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
          OR ('$deploy_config' = 'ha-qbt-deployments' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments' AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
        )
|||;

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
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
        '%s @ ' || concurrency AS metric,
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
          (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency,
          %s
        FROM data
        WHERE horreum_testid = %g
          AND $__timeFilter(start)
          %s
          %s
          %s
          AND %s
        GROUP BY day, concurrency
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testId, concurrencyPredicate, deployConfigPredicate, versionPredicate(versionVar), fieldConditions, selectStatements],
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
  // ── Pipeline Results ─────────────────────────────────────────
  createRow('Pipeline Results', 0),
] + createPanelPair(
  'PipelineRun Succeeded',
  '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 1,
  description='Total number of PipelineRuns that completed successfully, averaged per day per concurrency level.'
) + createPanelPair(
  'PipelineRun Failed',
  '__results_PipelineRuns_count_failed', 'pr_failed', 'short', 9,
  description='Total number of PipelineRuns that failed, averaged per day per concurrency level.'
) + createPanelPair(
  'PR Mean Duration',
  '__results_PipelineRuns_duration_avg', 'pr_duration', 's', 17,
  description='Average wall-clock duration of all PipelineRuns, per day per concurrency level.'
) + createPanelPair(
  'Succeeded PR Metrics (pending / running)',
  '__results_PipelineRuns_Success_pending_avg', 'pending', 's', 25,
  additionalFields={ running: '__results_PipelineRuns_Success_running_avg' },
  description='Breakdown of successful PipelineRun duration into pending and running phases.'
) + [

  // ── TaskRun Results ──────────────────────────────────────────
  createRow('TaskRun Results', 33),
] + createPanelPair(
  'TaskRun Succeeded',
  '__results_TaskRuns_count_succeeded', 'tr_succeeded', 'short', 34,
  description='Total number of TaskRuns that completed successfully, averaged per day per concurrency level.'
) + createPanelPair(
  'TaskRun Failed',
  '__results_TaskRuns_count_failed', 'tr_failed', 'short', 42,
  description='Total number of TaskRuns that failed, averaged per day per concurrency level.'
) + createPanelPair(
  'TR Mean Success Duration',
  '__results_TaskRuns_duration_avg', 'tr_duration', 's', 50,
  description='Average wall-clock duration of successful TaskRuns, per day per concurrency level.'
) + createPanelPair(
  'Succeeded TR Metrics (pending / running)',
  '__results_TaskRuns_Success_pending_avg', 'pending', 's', 58,
  additionalFields={ running: '__results_TaskRuns_Success_running_avg' },
  description='Breakdown of successful TaskRun duration into pending and running phases.'
) + [

  // ── Controller Metrics ───────────────────────────────────────
  createRow('Controller Metrics', 66),
] + createPanelPair(
  'TaskRun to Pod Creation Duration',
  '__results_TaskRunsToPods_creationTimestampDiff_mean', 'pod_creation_lag', 's', 67,
  description='Mean time between TaskRun creation and its Pod creation. High values indicate controller backlog.'
) + createPanelPair(
  'Controllers CPU Usage (Mean)',
  '__measurements_tektonPipelinesController_cpu_mean', 'controller_cpu', 'short', 75,
  additionalFields={
    webhook_cpu: '__measurements_tektonPipelinesWebhook_cpu_mean',
    proxy_webhook_cpu: '__measurements_tektonOperatorProxyWebhook_cpu_mean',
  },
  description='Mean CPU usage of Tekton Pipelines controller, webhook, and proxy webhook.'
) + createPanelPair(
  'Controllers Memory Usage (Mean)',
  '__measurements_tektonPipelinesController_memory_mean', 'controller_mem', 'bytes', 83,
  additionalFields={
    webhook_mem: '__measurements_tektonPipelinesWebhook_memory_mean',
    proxy_webhook_mem: '__measurements_tektonOperatorProxyWebhook_memory_mean',
  },
  description='Mean memory (RSS) usage of Tekton Pipelines controller, webhook, and proxy webhook.'
) + createPanelPair(
  'Pipelines Controller Workqueue Depth',
  '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean', 'workqueue_depth', 'short', 91,
  description='Mean depth of the Tekton Pipelines controller workqueue. High values suggest the controller is a bottleneck.'
) + createPanelPair(
  'Pipelines Controller Client Latency',
  '__measurements_tektonPipelinesControllerClientLatencyAverage_mean', 'client_latency', 's', 99,
  description='Mean HTTP client latency of the Tekton Pipelines controller when communicating with the Kubernetes API server.'
) + [

  // ── Cluster & API Server Metrics ─────────────────────────────
  createRow('Cluster & API Server Metrics', 107),
] + createPanelPair(
  'Cluster CPU Usage',
  '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short', 108,
  description='Mean total CPU usage rate across all cluster nodes during the test run.'
) + createPanelPair(
  'Cluster Memory Usage',
  '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes', 116,
  description='Mean total RSS memory usage across all cluster nodes during the test run.'
) + createPanelPair(
  'OpenShift and Kube API Server CPU Usage (Mean)',
  '__measurements_apiserver_cpu_mean', 'apiserver_cpu', 'short', 124,
  additionalFields={ kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
  description='Mean CPU usage of the OpenShift API server and Kubernetes API server.'
) + createPanelPair(
  'OpenShift and Kube API Server Memory Usage (Mean)',
  '__measurements_apiserver_memory_mean', 'apiserver_mem', 'bytes', 132,
  additionalFields={ kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
  description='Mean memory usage of the OpenShift API server and Kubernetes API server.'
) + [

  // ── etcd Metrics ──────────────────────────────────────────────
  createRow('etcd Metrics', 140),
] + createPanelPair(
  'etcd MVCC DB Size (Mean)',
  '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes', 141,
  additionalFields={ db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
  description='Mean etcd MVCC database size. A large gap between total and in-use indicates fragmentation.'
) + createPanelPair(
  'etcd Request Duration (Mean)',
  '__measurements_etcdRequestDurationSecondsAverage_mean', 'req_duration_mean', 's', 149,
  additionalFields={ req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
  description='Average and peak etcd request duration. High values indicate etcd pressure.'
) + createPanelPair(
  'etcd Restarts',
  '__measurements_etcd_restarts_range', 'etcd_restarts', 'short', 157,
  description='Number of etcd Pod restarts during the test run. Should be 0 under normal conditions.'
) + createPanelPair(
  'Scheduler Pending Pods',
  '__measurements_schedulerPendingPodsCount_range', 'pending_pods', 'short', 165,
  description='Range of pending pods count in the scheduler. High values indicate scheduling pressure.'
);

// ─── Dashboard ──────────────────────────────────────────────────────────────

dashboard.new('Pipelines Performance Comparison Dashboard')
+ dashboard.withUid('Pipelines_Performance_Comparison')
+ dashboard.withDescription('Side-by-side comparison of OpenShift Pipelines performance metrics across different released versions. Select two versions to compare.')
+ dashboard.time.withFrom('now-90d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('browser')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, deployConfigVar, version1Var, version2Var, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.graphTooltip.withSharedCrosshair()
