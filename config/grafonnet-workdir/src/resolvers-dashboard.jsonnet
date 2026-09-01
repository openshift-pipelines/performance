local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/resolvers-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local resolverVar = common.resolverVar;

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
  description: 'Filter by test concurrency level.',
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

local resolverPredicate = |||
        AND label_values->>'__metadata_env_TEST_SCENARIO' = '${resolver}'
|||;

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
|||;

local createQuery(fieldName, metricLabel) =
  {
    rawSql: |||
      WITH daily_agg AS (
        SELECT
          DATE_TRUNC('day', start) AS day,
          (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency,
          AVG((label_values->>'%s')::DOUBLE PRECISION) AS val
        FROM data
        WHERE %s
          AND $__timeFilter(start)
          %s
          %s
          %s
          AND label_values ? '%s'
        GROUP BY day, concurrency
      )

      SELECT
        EXTRACT(EPOCH FROM day) AS time,
        'C=' || concurrency AS metric,
        val AS value
      FROM daily_agg

      ORDER BY time, metric;
    ||| % [fieldName, testIdPredicate, concurrencyPredicate, resolverPredicate, versionPredicate, fieldName],
    format: 'time_series',
    refId: 'A',
  };

local trendPanel(title, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, description='', axisSoftMax=null, thresholds=[]) =
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
  + (if std.length(thresholds) > 0 then {
       fieldConfig+: { defaults+: { custom+: { thresholdsStyle: { mode: 'line' } }, thresholds: {
         mode: 'absolute',
         steps: [{ color: 'green', value: null }] + thresholds,
       } } },
     } else {})
  + timeSeries.queryOptions.withTargets([
    createQuery(fieldName, metricLabel),
  ]);

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  // ── Resolution Times ───────────────────────────────────────
  row('Resolution Times', 0),
  trendPanel(
    'Resolution Time — Average',
    '__results_ResolutionRequests_ResolverLog_Overall_avg',
    'avg', 's',
    0, 1, 12, 8,
    description='Average resolution time from resolver controller logs. Lower is better.'
  ),
  trendPanel(
    'Resolution Time — P95',
    '__results_ResolutionRequests_ResolverLog_Overall_p95',
    'p95', 's',
    12, 1, 12, 8,
    description='P95 resolution time. 95% of resolutions complete within this time.'
  ),
  trendPanel(
    'Resolution Time — P99',
    '__results_ResolutionRequests_ResolverLog_Overall_p99',
    'p99', 's',
    0, 9, 12, 8,
    description='P99 resolution time. Captures tail latency — spikes indicate contention or upstream slowness.'
  ),
  trendPanel(
    'Resolution Time — Max',
    '__results_ResolutionRequests_ResolverLog_Overall_max',
    'max', 's',
    12, 9, 12, 8,
    description='Worst-case single resolution time. Useful for investigating outliers.'
  ),

  // ── Resolver Pod Resources ─────────────────────────────────
  row('Resolver Pod Resources', 17),
  trendPanel(
    'Resolver CPU (mean)',
    '__measurements_tektonPipelinesRemoteResolvers_cpu_mean',
    'cpu_mean', 'short',
    0, 18, 12, 8,
    description='Remote resolvers pod mean CPU usage (cores).',
    axisSoftMax=1.0
  ),
  trendPanel(
    'Resolver CPU (max)',
    '__measurements_tektonPipelinesRemoteResolvers_cpu_max',
    'cpu_max', 'short',
    12, 18, 12, 8,
    description='Remote resolvers pod peak CPU usage (cores).',
    axisSoftMax=1.0
  ),
  trendPanel(
    'Resolver Memory (mean)',
    '__measurements_tektonPipelinesRemoteResolvers_memory_mean',
    'mem_mean', 'bytes',
    0, 26, 12, 8,
    description='Remote resolvers pod mean memory usage.'
  ),
  trendPanel(
    'Resolver Memory (max)',
    '__measurements_tektonPipelinesRemoteResolvers_memory_max',
    'mem_max', 'bytes',
    12, 26, 12, 8,
    description='Remote resolvers pod peak memory usage.'
  ),
  trendPanel(
    'Resolver Workqueue Depth (mean)',
    '__measurements_resolverWorkqueueDepth_mean',
    'depth_mean', 'short',
    0, 34, 12, 8,
    description='Resolver workqueue depth. High values indicate the resolver cannot keep up with incoming ResolutionRequests.'
  ),
  trendPanel(
    'Resolver Workqueue Depth (max)',
    '__measurements_resolverWorkqueueDepth_max',
    'depth_max', 'short',
    12, 34, 12, 8,
    description='Peak resolver workqueue depth.'
  ),
  trendPanel(
    'Resolver Queue Duration P95 (mean)',
    '__measurements_resolverQueueDurationP95_mean',
    'queue_p95_mean', 's',
    0, 42, 12, 8,
    description='Mean time items spend waiting in the resolver workqueue before processing (P95).'
  ),
  trendPanel(
    'Resolver Queue Duration P95 (max)',
    '__measurements_resolverQueueDurationP95_max',
    'queue_p95_max', 's',
    12, 42, 12, 8,
    description='Peak resolver queue wait time (P95).'
  ),
  trendPanel(
    'Resolver Reconcile Count',
    '__results_ResolutionRequests_ResolverLog_Overall_count',
    'count', 'short',
    0, 50, 12, 8,
    description='Total resolver reconcile invocations from controller logs. Each ResolutionRequest triggers multiple reconcile passes.'
  ),

  // ── Pipeline Performance ───────────────────────────────────
  row('Pipeline Performance', 58),
  trendPanel(
    'PipelineRun Duration (avg)',
    '__results_PipelineRuns_Success_duration_avg',
    'pr_duration', 's',
    0, 59, 12, 8,
    description='Average total duration for successful PipelineRuns.'
  ),
  trendPanel(
    'PipelineRun Pending (avg)',
    '__results_PipelineRuns_Success_pending_avg',
    'pr_pending', 's',
    12, 59, 12, 8,
    description='Average time successful PipelineRuns spent in pending state (waiting for resolution + scheduling).'
  ),
  trendPanel(
    'PipelineRun Running (avg)',
    '__results_PipelineRuns_Success_running_avg',
    'pr_running', 's',
    0, 67, 12, 8,
    description='Average time successful PipelineRuns spent actively running.'
  ),
  trendPanel(
    'PipelineRun Succeeded',
    '__results_PipelineRuns_count_succeeded',
    'pr_succeeded', 'short',
    12, 67, 12, 8,
    description='Number of successful PipelineRuns. Should match the configured total.'
  ),
  trendPanel(
    'PipelineRun Failed',
    '__results_PipelineRuns_count_failed',
    'pr_failed', 'short',
    0, 75, 12, 8,
    description='Number of failed PipelineRuns. Should be 0.',
    axisSoftMax=5
  ),

  // ── TaskRun Performance ────────────────────────────────────
  row('TaskRun Performance', 83),
  trendPanel(
    'TaskRun Duration (avg)',
    '__results_TaskRuns_Success_duration_avg',
    'tr_duration', 's',
    0, 84, 12, 8,
    description='Average total duration for successful TaskRuns.'
  ),
  trendPanel(
    'TaskRun Pending (avg)',
    '__results_TaskRuns_Success_pending_avg',
    'tr_pending', 's',
    12, 84, 12, 8,
    description='Average time successful TaskRuns spent waiting for Pod scheduling.'
  ),
  trendPanel(
    'TaskRun-to-Pod Scheduling Lag (mean)',
    '__results_TaskRunsToPods_creationTimestampDiff_mean',
    'tr2pod_mean', 's',
    0, 92, 12, 8,
    description='Mean time between TaskRun creation and Pod creation. High values indicate scheduler pressure.'
  ),
  trendPanel(
    'TaskRun-to-Pod Scheduling Lag (max)',
    '__results_TaskRunsToPods_creationTimestampDiff_max',
    'tr2pod_max', 's',
    12, 92, 12, 8,
    description='Worst-case TaskRun-to-Pod scheduling delay.'
  ),

  // ── Pipelines Controller ───────────────────────────────────
  row('Pipelines Controller', 100),
  trendPanel(
    'Controller CPU (mean)',
    '__measurements_tektonPipelinesController_cpu_mean',
    'ctrl_cpu_mean', 'short',
    0, 101, 12, 8,
    description='Pipelines controller mean CPU usage (cores).',
    axisSoftMax=1.0
  ),
  trendPanel(
    'Controller CPU (max)',
    '__measurements_tektonPipelinesController_cpu_max',
    'ctrl_cpu_max', 'short',
    12, 101, 12, 8,
    description='Pipelines controller peak CPU usage (cores).',
    axisSoftMax=1.0
  ),
  trendPanel(
    'Controller Memory (mean)',
    '__measurements_tektonPipelinesController_memory_mean',
    'ctrl_mem_mean', 'bytes',
    0, 109, 12, 8,
    description='Pipelines controller mean memory usage.'
  ),
  trendPanel(
    'Controller Memory (max)',
    '__measurements_tektonPipelinesController_memory_max',
    'ctrl_mem_max', 'bytes',
    12, 109, 12, 8,
    description='Pipelines controller peak memory usage.'
  ),
  trendPanel(
    'Controller Workqueue Depth',
    '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean',
    'ctrl_wq_depth', 'short',
    0, 117, 12, 8,
    description='Pipelines controller workqueue depth. Shows how many PipelineRun/TaskRun reconciliations are queued.'
  ),
];

dashboard.new('Resolvers Performance')
+ dashboard.withDescription('Remote resolver (git, bundle, cluster) concurrency performance trends. Horreum test ID: 437.')
+ dashboard.withUid('resolvers-performance')
+ dashboard.withTimezone('utc')
+ dashboard.withEditable(true)
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withTags(['openshift-pipelines', 'resolvers', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
+ dashboard.withVariables([
  datasourceVar,
  resolverVar,
  versionVar,
  concurrencyVar,
])
+ dashboard.withPanels(allPanels)
