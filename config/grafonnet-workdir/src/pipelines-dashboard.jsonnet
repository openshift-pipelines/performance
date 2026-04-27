local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

// ─── Constants ───────────────────────────────────────────────────────────────
local testId = 391;

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

local deployConfigVar = {
  type: 'custom',
  name: 'deploy_config',
  label: 'Deployment Configuration',
  description: 'Standard, HA (no QBT), QBT (non-HA), or HA+QBT (deployments only). Dashboard shows nightly builds only.',
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

// ─── SQL predicates (injected into every query) ─────────────────────────────

// Matches legacy __deployment_nightly or __deployment_isNightlyBuild
local nightlyOnlyPredicate = |||
        AND (
          ((label_values ? '__deployment_nightly') AND (label_values->>'__deployment_nightly')::BOOLEAN = true)
          OR ((label_values ? '__deployment_isNightlyBuild') AND (label_values->>'__deployment_isNightlyBuild')::BOOLEAN = true)
        )
|||;

// Deployment config slice — uses Grafana [[deploy_config]] macro in SQL
local deployConfigPredicate = |||
        AND (
          ('[[deploy_config]]' = 'standard' AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false) AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('[[deploy_config]]' = 'ha-deployments' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments' AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('[[deploy_config]]' = 'ha-statefulsets' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'statefulSets' AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR ('[[deploy_config]]' = 'qbt' AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false) AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
          OR ('[[deploy_config]]' = 'ha-qbt-deployments' AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments' AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
        )
|||;

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
|||;

// ─── Query builders ─────────────────────────────────────────────────────────

// Daily-aggregated query with automatic UNION ALL for multi-field panels
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
    ||| % [fieldSelections, testId, concurrencyPredicate, deployConfigPredicate, nightlyOnlyPredicate, fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

// ─── Panel builders ─────────────────────────────────────────────────────────

local createComplexPanel(title, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, additionalFields={}, description='') =
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
    createComplexQuery(fieldName, metricLabel, additionalFields),
  ]);

local createRow(title, y, collapsed=false) = {
  type: 'row',
  title: title,
  collapsed: collapsed,
  gridPos: { h: 1, w: 24, x: 0, y: y },
  panels: [],
};

// ─── Dashboard panels ───────────────────────────────────────────────────────

local allPanels = [
  // ── Pipeline Results ─────────────────────────────────────────
  createRow('Pipeline Results', 0),
  createComplexPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded',
    'pr_succeeded',
    'short',
    0, 1, 12, 8,
    description='Total number of PipelineRuns that completed successfully, averaged per day per concurrency level.'
  ),
  createComplexPanel(
    'PipelineRun Failed',
    '__results_PipelineRuns_count_failed',
    'pr_failed',
    'short',
    12, 1, 12, 8,
    description='Total number of PipelineRuns that failed, averaged per day per concurrency level. A value of 0 means all runs succeeded.'
  ),
  createComplexPanel(
    'PR Mean Duration',
    '__results_PipelineRuns_duration_avg',
    'pr_duration',
    's',
    0, 9, 12, 8,
    description='Average wall-clock duration of all PipelineRuns (creationTimestamp to completionTime), per day per concurrency level.'
  ),
  createComplexPanel(
    'Succeeded PR Metrics (pending / running)',
    '__results_PipelineRuns_Success_pending_avg',
    'pending',
    's',
    12, 9, 12, 8,
    { running: '__results_PipelineRuns_Success_running_avg' },
    description='Breakdown of successful PipelineRun duration into two phases:\n- **pending**: time from creation to start (waiting for scheduling)\n- **running**: time from start to completion (actual execution)\n\nHigh pending time indicates scheduling pressure; high running time indicates slow task execution.'
  ),

  // ── TaskRun Results ──────────────────────────────────────────
  createRow('TaskRun Results', 17),
  createComplexPanel(
    'TaskRun Succeeded',
    '__results_TaskRuns_count_succeeded',
    'tr_succeeded',
    'short',
    0, 18, 12, 8,
    description='Total number of TaskRuns that completed successfully, averaged per day per concurrency level. Each PipelineRun creates multiple TaskRuns.'
  ),
  createComplexPanel(
    'TaskRun Failed',
    '__results_TaskRuns_count_failed',
    'tr_failed',
    'short',
    12, 18, 12, 8,
    description='Total number of TaskRuns that failed, averaged per day per concurrency level.'
  ),
  createComplexPanel(
    'TR Mean Success Duration',
    '__results_TaskRuns_duration_avg',
    'tr_duration',
    's',
    0, 26, 12, 8,
    description='Average wall-clock duration of successful TaskRuns (creationTimestamp to completionTime), per day per concurrency level.'
  ),
  createComplexPanel(
    'Succeeded TR Metrics (pending / running)',
    '__results_TaskRuns_Success_pending_avg',
    'pending',
    's',
    12, 26, 12, 8,
    { running: '__results_TaskRuns_Success_running_avg' },
    description='Breakdown of successful TaskRun duration into two phases:\n- **pending**: time from creation to start (waiting for Pod scheduling)\n- **running**: time from start to completion (actual container execution)\n\nHigh pending time indicates Pod scheduling delays or resource pressure.'
  ),

  // ── Controller Metrics ───────────────────────────────────────
  createRow('Controller Metrics', 34),
  createComplexPanel(
    'TaskRun to Pod Creation Duration',
    '__results_TaskRunsToPods_creationTimestampDiff_mean',
    'pod_creation_lag',
    's',
    0, 35, 12, 8,
    description='Mean time between TaskRun creation and its corresponding Pod creation. Measures how long the Tekton controller takes to reconcile a TaskRun and create the Pod. High values indicate controller backlog.'
  ),
  createComplexPanel(
    'Controllers CPU Usage (Mean)',
    '__measurements_tektonPipelinesController_cpu_mean',
    'controller_cpu',
    'short',
    12, 35, 12, 8,
    {
      webhook_cpu: '__measurements_tektonPipelinesWebhook_cpu_mean',
      proxy_webhook_cpu: '__measurements_tektonOperatorProxyWebhook_cpu_mean',
    },
    description='Mean CPU usage of Tekton Pipelines components during the test run, in CPU cores (e.g. 0.06 = 60 millicores).\n- **controller_cpu**: main reconciliation controller\n- **webhook_cpu**: admission webhook\n- **proxy_webhook_cpu**: operator proxy webhook'
  ),
  createComplexPanel(
    'Controllers Memory Usage (Mean)',
    '__measurements_tektonPipelinesController_memory_mean',
    'controller_mem',
    'bytes',
    0, 43, 12, 8,
    {
      webhook_mem: '__measurements_tektonPipelinesWebhook_memory_mean',
      proxy_webhook_mem: '__measurements_tektonOperatorProxyWebhook_memory_mean',
    },
    description='Mean memory (RSS) usage of Tekton Pipelines components during the test run.\n- **controller_mem**: main reconciliation controller\n- **webhook_mem**: admission webhook\n- **proxy_webhook_mem**: operator proxy webhook'
  ),
  createComplexPanel(
    'Pipelines Controller Workqueue Depth',
    '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean',
    'workqueue_depth',
    'short',
    12, 43, 12, 8,
    description='Mean depth of the Tekton Pipelines controller workqueue during the test. A growing workqueue indicates the controller cannot reconcile objects fast enough. Consistently high values suggest the controller is a bottleneck.\n\nNote: Nightly builds using Tekton >= v1.10 report this as kn_workqueue_depth (OpenTelemetry).'
  ),
  createComplexPanel(
    'Pipelines Controller Client Latency',
    '__measurements_tektonPipelinesControllerClientLatencyAverage_mean',
    'client_latency',
    's',
    0, 51, 12, 8,
    description='Mean HTTP client latency (p50) of the Tekton Pipelines controller when communicating with the Kubernetes API server. High latency indicates API server pressure or network issues.\n\nNote: Nightly builds using Tekton >= v1.10 report this as http_client_request_duration_seconds (OpenTelemetry).'
  ),

  // ── Cluster & API Server Metrics ─────────────────────────────
  createRow('Cluster & API Server Metrics', 59),
  createComplexPanel(
    'Cluster CPU Usage',
    '__measurements_clusterCpuUsageSecondsTotalRate_mean',
    'cluster_cpu',
    'short',
    0, 60, 12, 8,
    description='Mean total CPU usage rate across all cluster nodes during the test run, in CPU cores (e.g. 6.5 = 6.5 cores used across the cluster).'
  ),
  createComplexPanel(
    'Cluster Memory Usage',
    '__measurements_clusterMemoryUsageRssTotal_mean',
    'cluster_mem',
    'bytes',
    12, 60, 12, 8,
    description='Mean total RSS memory usage across all cluster nodes during the test run.'
  ),
  createComplexPanel(
    'OpenShift and Kube API Server CPU Usage (Mean)',
    '__measurements_apiserver_cpu_mean',
    'apiserver_cpu',
    'short',
    0, 68, 12, 8,
    { kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
    description='Mean CPU usage of the OpenShift API server and Kubernetes API server during the test run, in CPU cores. High values may indicate excessive API calls from the Tekton controller or other components.'
  ),
  createComplexPanel(
    'OpenShift and Kube API Server Memory Usage (Mean)',
    '__measurements_apiserver_memory_mean',
    'apiserver_mem',
    'bytes',
    12, 68, 12, 8,
    { kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
    description='Mean memory usage of the OpenShift API server and Kubernetes API server during the test run.'
  ),

  // ── etcd Metrics ──────────────────────────────────────────────
  createRow('etcd Metrics', 76),
  createComplexPanel(
    'etcd MVCC DB Size (Mean)',
    '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean',
    'db_total',
    'bytes',
    0, 77, 12, 8,
    { db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
    description='Mean etcd MVCC database size during the test run.\n- **db_total**: total allocated DB size on disk\n- **db_in_use**: portion of the DB actively in use\n\nA large gap between total and in-use may indicate fragmentation or the need for defragmentation.'
  ),
  createComplexPanel(
    'etcd Request Duration (Mean)',
    '__measurements_etcdRequestDurationSecondsAverage_mean',
    'req_duration_mean',
    's',
    12, 77, 12, 8,
    { req_duration_max: '__measurements_etcdRequestDurationSecondsAverage_max' },
    description='Average and maximum etcd request duration during the test run.\n- **req_duration_mean**: average latency across all etcd requests\n- **req_duration_max**: worst-case (peak) etcd request latency\n\nHigh values indicate etcd is under pressure, which can cause slow reconciliation and API server latency.'
  ),
  createComplexPanel(
    'etcd Restarts',
    '__measurements_etcd_restarts_range',
    'etcd_restarts',
    'short',
    0, 85, 12, 8,
    description='Number of etcd Pod restarts during the test run. Should be 0 under normal conditions. Any restarts indicate instability that likely affected test results.'
  ),
  createComplexPanel(
    'Scheduler Pending Pods',
    '__measurements_schedulerPendingPodsCount_range',
    'pending_pods',
    'short',
    12, 85, 12, 8,
    description='Range of pending pods count in the Kubernetes scheduler during the test run. High values indicate scheduling pressure — pods are waiting for resources or node availability.'
  ),
];

// ─── Dashboard ──────────────────────────────────────────────────────────────

dashboard.new('Pipelines Performance Dashboard')
+ dashboard.withUid('Pipelines_Performance')
+ dashboard.withDescription('OpenShift Pipelines nightly build performance. Use the Deployment Configuration variable to switch between Standard, HA, QBT, and HA+QBT setups.')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, deployConfigVar, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.graphTooltip.withSharedCrosshair()
