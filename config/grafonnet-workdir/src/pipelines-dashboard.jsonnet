local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/pipelines-common.libsonnet';

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

local concurrencyVar = {
  type: 'query',
  name: 'concurrency',
  label: 'Concurrency',
  description: 'Filter by concurrency level. Select one or more, or All.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__parameters_test_concurrent' ORDER BY concurrency" % testIdPredicate,
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 3,
};

local versionPredicate = |||
        AND %s = '${version}'
||| % versionExpr;

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
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
        '%s @ c' || concurrency AS metric,
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
        WHERE %s
          AND $__timeFilter(start)
          %s
          %s
          AND %s
        GROUP BY day, concurrency
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testIdPredicate, concurrencyPredicate, versionPredicate, fieldConditions, selectStatements],
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
  // ── Pipeline Results ─────────────────────────────────────────
  row('Pipeline Results', 0),
  trendPanel(
    'PipelineRun Duration (avg)',
    '__results_PipelineRuns_duration_avg',
    'pr_duration',
    's',
    0, 1, 12, 8,
    description='Average wall-clock duration of all PipelineRuns (creationTimestamp → completionTime), per day per concurrency level. Rising trend indicates a regression.'
  ),
  trendPanel(
    'PipelineRun Phases (pending / running)',
    '__results_PipelineRuns_Success_pending_avg',
    'pending',
    's',
    12, 1, 12, 8,
    { running: '__results_PipelineRuns_Success_running_avg' },
    description='Breakdown of successful PipelineRun duration into two phases:\n- **pending**: time from creation to start (waiting for scheduling)\n- **running**: time from start to completion (actual execution)\n\nHigh pending → scheduling pressure. High running → slow task execution.'
  ),
  trendPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded',
    'pr_succeeded',
    'short',
    0, 9, 12, 8,
    description='Total number of PipelineRuns that completed successfully, averaged per day per concurrency level.'
  ),
  trendPanel(
    'PipelineRun Failed',
    '__results_PipelineRuns_count_failed',
    'pr_failed',
    'short',
    12, 9, 12, 8,
    description='PipelineRuns that failed. Should be 0. Any non-zero value indicates test failures worth investigating.',
    axisSoftMax=5,
  ),

  // ── TaskRun Results ──────────────────────────────────────────
  row('TaskRun Results', 17),
  trendPanel(
    'TaskRun Duration (avg)',
    '__results_TaskRuns_duration_avg',
    'tr_duration',
    's',
    0, 18, 12, 8,
    description='Average wall-clock duration of successful TaskRuns (creationTimestamp → completionTime), per day per concurrency level.'
  ),
  trendPanel(
    'TaskRun Phases (pending / running)',
    '__results_TaskRuns_Success_pending_avg',
    'pending',
    's',
    12, 18, 12, 8,
    { running: '__results_TaskRuns_Success_running_avg' },
    description='Breakdown of successful TaskRun duration into two phases:\n- **pending**: time from creation to start (waiting for Pod scheduling)\n- **running**: time from start to completion (actual container execution)\n\nHigh pending → Pod scheduling delays or resource pressure.'
  ),
  trendPanel(
    'TaskRun Succeeded',
    '__results_TaskRuns_count_succeeded',
    'tr_succeeded',
    'short',
    0, 26, 12, 8,
    description='Total number of TaskRuns that completed successfully, averaged per day per concurrency level. Each PipelineRun creates multiple TaskRuns.'
  ),
  trendPanel(
    'TaskRun Failed',
    '__results_TaskRuns_count_failed',
    'tr_failed',
    'short',
    12, 26, 12, 8,
    description='TaskRuns that failed. Should be 0.',
    axisSoftMax=5,
  ),

  // ── Controller Health ──────────────────────────────────────────
  row('Controller Health', 34),
  trendPanel(
    'TaskRun → Pod Creation Lag',
    '__results_TaskRunsToPods_creationTimestampDiff_mean',
    'pod_creation_lag',
    's',
    0, 35, 12, 8,
    description='Mean time between TaskRun creation and its corresponding Pod creation. Measures how long the Tekton controller takes to reconcile a TaskRun and create the Pod. High values indicate controller backlog.'
  ),
  trendPanel(
    'Controller Workqueue Depth',
    '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean',
    'workqueue_depth',
    'short',
    12, 35, 12, 8,
    description='Mean depth of the Tekton Pipelines controller work queue. A growing queue means the controller cannot reconcile objects fast enough.\n\nNote: Tekton >= v1.10 reports this as kn_workqueue_depth (OpenTelemetry).'
  ),
  trendPanel(
    'Controller Client Latency',
    '__measurements_tektonPipelinesControllerClientLatencyAverage_mean',
    'client_latency',
    's',
    0, 43, 12, 8,
    description='Mean HTTP client latency of the Tekton Pipelines controller when communicating with the Kubernetes API server. High latency indicates API server pressure or network issues.\n\nNote: Tekton >= v1.10 reports this as http_client_request_duration_seconds (OpenTelemetry).'
  ),

  // ── Component Resources ────────────────────────────────────────
  row('Component Resources', 51),
  trendPanel(
    'Tekton CPU (controller / webhook / proxy)',
    '__measurements_tektonPipelinesController_cpu_mean',
    'controller_cpu',
    'short',
    0, 52, 12, 8,
    {
      webhook_cpu: '__measurements_tektonPipelinesWebhook_cpu_mean',
      proxy_cpu: '__measurements_tektonOperatorProxyWebhook_cpu_mean',
    },
    description='Mean CPU usage of Tekton Pipelines components (in CPU cores, e.g. 0.06 = 60 millicores).\n- **controller_cpu**: main reconciliation loop\n- **webhook_cpu**: admission webhook\n- **proxy_cpu**: operator proxy webhook'
  ),
  trendPanel(
    'Tekton Memory (controller / webhook / proxy)',
    '__measurements_tektonPipelinesController_memory_mean',
    'controller_mem',
    'bytes',
    12, 52, 12, 8,
    {
      webhook_mem: '__measurements_tektonPipelinesWebhook_memory_mean',
      proxy_mem: '__measurements_tektonOperatorProxyWebhook_memory_mean',
    },
    description='Mean memory (RSS) usage of Tekton Pipelines components.\n- **controller_mem**: main reconciliation loop\n- **webhook_mem**: admission webhook\n- **proxy_mem**: operator proxy webhook'
  ),

  // ── Cluster & API Server ───────────────────────────────────────
  row('Cluster & API Server', 60),
  trendPanel(
    'Cluster CPU',
    '__measurements_clusterCpuUsageSecondsTotalRate_mean',
    'cluster_cpu',
    'short',
    0, 61, 12, 8,
    description='Mean total CPU usage rate across all cluster nodes during the test, in CPU cores.'
  ),
  trendPanel(
    'Cluster Memory',
    '__measurements_clusterMemoryUsageRssTotal_mean',
    'cluster_mem',
    'bytes',
    12, 61, 12, 8,
    description='Mean total RSS memory usage across all cluster nodes during the test.'
  ),
  trendPanel(
    'API Server CPU (OpenShift / Kube)',
    '__measurements_apiserver_cpu_mean',
    'ocp_apiserver_cpu',
    'short',
    0, 69, 12, 8,
    { kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
    description='Mean CPU usage of the OpenShift and Kubernetes API servers (in CPU cores). High values may indicate excessive API calls from Tekton or other components.'
  ),
  trendPanel(
    'API Server Memory (OpenShift / Kube)',
    '__measurements_apiserver_memory_mean',
    'ocp_apiserver_mem',
    'bytes',
    12, 69, 12, 8,
    { kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
    description='Mean memory usage of the OpenShift and Kubernetes API servers.'
  ),

  // ── etcd ──────────────────────────────────────────────────────
  row('etcd', 77),
  trendPanel(
    'etcd DB Size (total / in-use)',
    '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean',
    'db_total',
    'bytes',
    0, 78, 12, 8,
    { db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
    description='Mean etcd MVCC database size.\n- **db_total**: total allocated DB size on disk\n- **db_in_use**: portion actively in use\n\nA large gap between the two may indicate fragmentation.'
  ),
  trendPanel(
    'etcd Request Duration (mean / max)',
    '__measurements_etcdRequestDurationSecondsAverage_mean',
    'mean',
    's',
    12, 78, 12, 8,
    { max: '__measurements_etcdRequestDurationSecondsAverage_max' },
    description='etcd request latency.\n- **mean**: average across all requests\n- **max**: worst-case peak latency\n\nHigh values indicate etcd pressure, causing slow reconciliation and API latency.'
  ),
  trendPanel(
    'etcd Restarts',
    '__measurements_etcd_restarts_range',
    'etcd_restarts',
    'short',
    0, 86, 12, 8,
    description='etcd Pod restarts during the test. Should be 0. Any restarts indicate instability that likely affected results.',
    axisSoftMax=5,
  ),
  trendPanel(
    'Scheduler Pending Pods',
    '__measurements_schedulerPendingPodsCount_range',
    'pending_pods',
    'short',
    12, 86, 12, 8,
    description='Range of pending pods in the kube-scheduler queue. High values indicate scheduling pressure — pods waiting for resources or node availability.',
    axisSoftMax=5,
  ),
];

dashboard.new('Pipelines Performance Dashboard')
+ dashboard.withUid('Pipelines_Performance')
+ dashboard.withDescription('OpenShift Pipelines performance trends per variant and version. Includes historical data from legacy test 391 and new per-variant tests (419-423). Select a variant, version, and concurrency level to track regressions over time.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, versionVar, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['pipelines', 'trend', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
