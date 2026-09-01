local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/resolvers-common.libsonnet';

local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local resolverVar = common.resolverVar;

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

local resolverPredicate = |||
        AND label_values->>'__metadata_env_TEST_SCENARIO' = '${resolver}'
|||;

local concurrencyPredicate = |||
        AND (label_values->>'__parameters_test_concurrent')::INTEGER IN ($concurrency)
|||;

local createComparisonQuery(fieldName, metricLabel, versionVar) =
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
    ||| % [fieldName, testIdPredicate, concurrencyPredicate, resolverPredicate, versionPredicate(versionVar), fieldName],
    format: 'time_series',
    refId: 'A',
  };

local comparisonPanel(title, fieldName, metricLabel, unit, gridX, gridY, gridW=12, gridH=8, versionVar='version1', description='', axisSoftMax=null) =
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
    createComparisonQuery(fieldName, metricLabel, versionVar),
  ]);

local panelPair(title, fieldName, metricLabel, unit, y, description='', axisSoftMax=null) = [
  comparisonPanel(title, fieldName, metricLabel, unit, 0, y, versionVar='version1', description=description, axisSoftMax=axisSoftMax),
  comparisonPanel(title, fieldName, metricLabel, unit, 12, y, versionVar='version2', description=description, axisSoftMax=axisSoftMax),
];

local row(title, y) = {
  type: 'row',
  title: title,
  gridPos: { h: 1, w: 24, x: 0, y: y },
};

local allPanels = [
  // ── Resolution Times ───────────────────────────────────────
  row('Resolution Times', 0),
] + panelPair(
  'Resolution Time (avg)', '__results_ResolutionRequests_ResolverLog_Overall_avg', 'avg', 's', 1,
  description='Average resolution time from resolver controller logs.'
) + panelPair(
  'Resolution Time (P95)', '__results_ResolutionRequests_ResolverLog_Overall_p95', 'p95', 's', 9,
  description='P95 resolution time.'
) + panelPair(
  'Resolution Time (P99)', '__results_ResolutionRequests_ResolverLog_Overall_p99', 'p99', 's', 17,
  description='P99 resolution time.'
) + panelPair(
  'Resolution Time (max)', '__results_ResolutionRequests_ResolverLog_Overall_max', 'max', 's', 25,
  description='Worst-case single resolution time.'
) + [

  // ── Resolver Pod Resources ─────────────────────────────────
  row('Resolver Pod Resources', 33),
] + panelPair(
  'Resolver CPU (mean)', '__measurements_tektonPipelinesRemoteResolvers_cpu_mean', 'cpu_mean', 'short', 34,
  description='Remote resolvers pod mean CPU usage (cores).', axisSoftMax=1.0
) + panelPair(
  'Resolver CPU (max)', '__measurements_tektonPipelinesRemoteResolvers_cpu_max', 'cpu_max', 'short', 42,
  description='Remote resolvers pod peak CPU usage (cores).', axisSoftMax=1.0
) + panelPair(
  'Resolver Memory (mean)', '__measurements_tektonPipelinesRemoteResolvers_memory_mean', 'mem_mean', 'bytes', 50,
  description='Remote resolvers pod mean memory usage.'
) + panelPair(
  'Resolver Workqueue Depth (mean)', '__measurements_resolverWorkqueueDepth_mean', 'depth_mean', 'short', 58,
  description='Resolver workqueue depth.'
) + panelPair(
  'Resolver Queue Duration P95', '__measurements_resolverQueueDurationP95_mean', 'queue_p95', 's', 66,
  description='Time items spend waiting in the resolver workqueue (P95).'
) + [

  // ── Pipeline Performance ───────────────────────────────────
  row('Pipeline Performance', 74),
] + panelPair(
  'PipelineRun Duration (avg)', '__results_PipelineRuns_Success_duration_avg', 'pr_duration', 's', 75,
  description='Average successful PipelineRun duration.'
) + panelPair(
  'PipelineRun Pending (avg)', '__results_PipelineRuns_Success_pending_avg', 'pr_pending', 's', 83,
  description='Average time successful PipelineRuns spent in pending state.'
) + panelPair(
  'PipelineRun Succeeded', '__results_PipelineRuns_count_succeeded', 'pr_succeeded', 'short', 91,
  description='Number of successful PipelineRuns.'
) + panelPair(
  'PipelineRun Failed', '__results_PipelineRuns_count_failed', 'pr_failed', 'short', 99,
  description='Number of failed PipelineRuns. Should be 0.', axisSoftMax=5
) + [

  // ── TaskRun Performance ────────────────────────────────────
  row('TaskRun Performance', 107),
] + panelPair(
  'TaskRun Duration (avg)', '__results_TaskRuns_Success_duration_avg', 'tr_duration', 's', 108,
  description='Average successful TaskRun duration.'
) + panelPair(
  'TaskRun-to-Pod Lag (mean)', '__results_TaskRunsToPods_creationTimestampDiff_mean', 'tr2pod', 's', 116,
  description='Mean time from TaskRun creation to Pod creation.'
) + [

  // ── Pipelines Controller ───────────────────────────────────
  row('Pipelines Controller', 124),
] + panelPair(
  'Controller CPU (mean)', '__measurements_tektonPipelinesController_cpu_mean', 'ctrl_cpu', 'short', 125,
  description='Pipelines controller mean CPU usage (cores).', axisSoftMax=1.0
) + panelPair(
  'Controller Memory (mean)', '__measurements_tektonPipelinesController_memory_mean', 'ctrl_mem', 'bytes', 133,
  description='Pipelines controller mean memory usage.'
) + panelPair(
  'Controller Workqueue Depth', '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean', 'ctrl_wq', 'short', 141,
  description='Pipelines controller workqueue depth.'
);

dashboard.new('Resolvers Performance Comparison')
+ dashboard.withUid('Resolvers_Performance_Comparison')
+ dashboard.withDescription('Side-by-side comparison of two versions for the same resolver type. Pick a resolver, two versions, and see their metrics mirrored left/right. Horreum test ID: 437.')
+ dashboard.time.withFrom('now-30d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, resolverVar, version1Var, version2Var, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['resolvers', 'comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
