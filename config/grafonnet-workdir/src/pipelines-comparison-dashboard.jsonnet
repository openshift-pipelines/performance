local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/pipelines-common.libsonnet';

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

local versionPredicate(varName) = |||
        AND %s = '${%s}'
||| % [versionExpr, varName];

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
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
    ||| % [fieldSelections, testIdPredicate, concurrencyPredicate, versionPredicate(versionVar), fieldConditions, selectStatements],
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
  row('Pipeline Results', 0),
] + panelPair(
  'PipelineRun Duration (avg)',
  '__results_PipelineRuns_duration_avg', 'pr_duration', 's', 1,
  description='Average PipelineRun wall-clock duration. Rising trend indicates a regression.'
) + panelPair(
  'PipelineRun Phases (pending / running)',
  '__results_PipelineRuns_Success_pending_avg', 'pending', 's', 9,
  additionalFields={ running: '__results_PipelineRuns_Success_running_avg' },
  description='Successful PipelineRun phase breakdown:\n- **pending**: scheduling wait\n- **running**: execution time'
) + panelPair(
  'PipelineRun Succeeded',
  '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 17,
  description='Total successful PipelineRuns per day per concurrency level.'
) + panelPair(
  'PipelineRun Failed',
  '__results_PipelineRuns_count_failed', 'pr_failed', 'short', 25,
  description='Failed PipelineRuns. Should be 0.',
  axisSoftMax=5,
) + [

  row('TaskRun Results', 33),
] + panelPair(
  'TaskRun Duration (avg)',
  '__results_TaskRuns_duration_avg', 'tr_duration', 's', 34,
  description='Average successful TaskRun duration.'
) + panelPair(
  'TaskRun Phases (pending / running)',
  '__results_TaskRuns_Success_pending_avg', 'pending', 's', 42,
  additionalFields={ running: '__results_TaskRuns_Success_running_avg' },
  description='Successful TaskRun phase breakdown:\n- **pending**: Pod scheduling wait\n- **running**: container execution time'
) + panelPair(
  'TaskRun Succeeded',
  '__results_TaskRuns_count_succeeded', 'tr_succeeded', 'short', 50,
  description='Total successful TaskRuns per day per concurrency level.'
) + panelPair(
  'TaskRun Failed',
  '__results_TaskRuns_count_failed', 'tr_failed', 'short', 58,
  description='Failed TaskRuns. Should be 0.',
  axisSoftMax=5,
) + [

  row('Controller Health', 66),
] + panelPair(
  'TaskRun → Pod Creation Lag',
  '__results_TaskRunsToPods_creationTimestampDiff_mean', 'pod_creation_lag', 's', 67,
  description='Mean time from TaskRun creation to Pod creation. High values indicate controller backlog.'
) + panelPair(
  'Controller Workqueue Depth',
  '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean', 'workqueue_depth', 'short', 75,
  description='Controller work queue depth. High = bottleneck.'
) + panelPair(
  'Controller Client Latency',
  '__measurements_tektonPipelinesControllerClientLatencyAverage_mean', 'client_latency', 's', 83,
  description='Controller → API server HTTP latency.'
) + [

  row('Component Resources', 91),
] + panelPair(
  'Tekton CPU (controller / webhook / proxy)',
  '__measurements_tektonPipelinesController_cpu_mean', 'controller_cpu', 'short', 92,
  additionalFields={
    webhook_cpu: '__measurements_tektonPipelinesWebhook_cpu_mean',
    proxy_cpu: '__measurements_tektonOperatorProxyWebhook_cpu_mean',
  },
  description='Mean CPU of Tekton Pipelines components (cores).\n- **controller_cpu**: reconciliation loop\n- **webhook_cpu**: admission webhook\n- **proxy_cpu**: operator proxy webhook'
) + panelPair(
  'Tekton Memory (controller / webhook / proxy)',
  '__measurements_tektonPipelinesController_memory_mean', 'controller_mem', 'bytes', 100,
  additionalFields={
    webhook_mem: '__measurements_tektonPipelinesWebhook_memory_mean',
    proxy_mem: '__measurements_tektonOperatorProxyWebhook_memory_mean',
  },
  description='Mean memory (RSS) of Tekton Pipelines components.\n- **controller_mem**: reconciliation loop\n- **webhook_mem**: admission webhook\n- **proxy_mem**: operator proxy webhook'
) + [

  row('Cluster & API Server', 108),
] + panelPair(
  'Cluster CPU',
  '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'cluster_cpu', 'short', 109,
  description='Mean total cluster CPU usage rate (cores).'
) + panelPair(
  'Cluster Memory',
  '__measurements_clusterMemoryUsageRssTotal_mean', 'cluster_mem', 'bytes', 117,
  description='Mean total cluster RSS memory.'
) + panelPair(
  'API Server CPU (OpenShift / Kube)',
  '__measurements_apiserver_cpu_mean', 'ocp_apiserver_cpu', 'short', 125,
  additionalFields={ kube_apiserver_cpu: '__measurements_kubeApiserver_cpu_mean' },
  description='Mean API server CPU (cores).'
) + panelPair(
  'API Server Memory (OpenShift / Kube)',
  '__measurements_apiserver_memory_mean', 'ocp_apiserver_mem', 'bytes', 133,
  additionalFields={ kube_apiserver_mem: '__measurements_kubeApiserver_memory_mean' },
  description='Mean API server memory.'
) + [

  row('etcd', 141),
] + panelPair(
  'etcd DB Size (total / in-use)',
  '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'db_total', 'bytes', 142,
  additionalFields={ db_in_use: '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean' },
  description='etcd MVCC DB size.\n- **db_total**: allocated on disk\n- **db_in_use**: live data'
) + panelPair(
  'etcd Request Duration (mean / max)',
  '__measurements_etcdRequestDurationSecondsAverage_mean', 'mean', 's', 150,
  additionalFields={ max: '__measurements_etcdRequestDurationSecondsAverage_max' },
  description='etcd request latency.\n- **mean**: average\n- **max**: worst-case peak'
) + panelPair(
  'etcd Restarts',
  '__measurements_etcd_restarts_range', 'etcd_restarts', 'short', 158,
  description='etcd Pod restarts. Should be 0.',
  axisSoftMax=5,
) + panelPair(
  'Scheduler Pending Pods',
  '__measurements_schedulerPendingPodsCount_range', 'pending_pods', 'short', 166,
  description='Pending pods in kube-scheduler queue.',
  axisSoftMax=5,
);

dashboard.new('Pipelines Performance Comparison')
+ dashboard.withUid('Pipelines_Performance_Comparison')
+ dashboard.withDescription('Side-by-side comparison of two versions for the same variant. Select a variant, pick two versions, and see their metrics mirrored left/right. Includes historical data from legacy test 391.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, version1Var, version2Var, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['pipelines', 'comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
