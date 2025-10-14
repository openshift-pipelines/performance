local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

// Shortcuts
local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;

// Define datasource variable
local datasourceVar =
  grafonnet.dashboard.variable.datasource.new(
    'datasource',
    'grafana-postgresql-datasource',
  )
  + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
  + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
  + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for pipeline metrics')
  + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource');

// Simple query function for basic metrics (counts, durations) - multiple queries per panel
local createSimpleQuery(testId, concurrency, fieldName, metricLabel) = {
  rawSql: |||
    SELECT
        EXTRACT(EPOCH FROM start) AS "time",
        (label_values->>'%s')::DOUBLE PRECISION AS "value",
        '%s concurrency %g' as "metric"
    FROM
        data
    WHERE
        horreum_testid = %g
        AND (label_values->>'__parameters_test_concurrent')::DOUBLE PRECISION = %g
    ORDER BY
        start;
  ||| % [fieldName, metricLabel, concurrency, testId, concurrency],
  format: 'time_series',
  refId: std.char(65 + concurrency - 12),  // A, B, C, D, E for concurrency 12,14,16,18,20
};

// Creates multiple simple query targets for different concurrency levels
local createSimpleQueryTargets(testId, fieldName, metricLabel) = timeSeries.queryOptions.withTargets([
  createSimpleQuery(testId, 12, fieldName, metricLabel),
  createSimpleQuery(testId, 14, fieldName, metricLabel),
  createSimpleQuery(testId, 16, fieldName, metricLabel),
  createSimpleQuery(testId, 18, fieldName, metricLabel),
  createSimpleQuery(testId, 20, fieldName, metricLabel)
]);

// Complex query function for aggregated metrics with daily aggregation
local createComplexQuery(testId, fieldName, metricLabel, additionalFields={}, divideBy=1) = 
  local baseFields = {
    [metricLabel]: fieldName
  };
  local allFields = baseFields + additionalFields;
  local fieldSelections = std.join(',\n    ', [
    'AVG((label_values->>\'%s\')::DOUBLE PRECISION)%s AS %s' % [
      allFields[key], 
      if divideBy != 1 then (' / %d' % divideBy) else '',
      key
    ]
    for key in std.objectFields(allFields)
  ]);
  local fieldConditions = std.join('\n    AND ', [
    'label_values ? \'%s\'' % allFields[key]
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
          AND label_values ? '__parameters_test_concurrent'
          AND %s
        GROUP BY day, concurrency
      )

      %s

      ORDER BY time, metric;
    ||| % [fieldSelections, testId, fieldConditions, selectStatements],
    format: 'time_series',
    refId: 'A',
  };

// Creates complex query target
local createComplexQueryTargets(testId, fieldName, metricLabel, additionalFields={}, divideBy=1) = 
  timeSeries.queryOptions.withTargets([
    createComplexQuery(testId, fieldName, metricLabel, additionalFields, divideBy)
  ]);

// Base panel function for simple queries
local createSimplePanel(title, testId, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8) =
  timeSeries.new(title)
  + timeSeries.queryOptions.withDatasource(
    type='grafana-postgresql-datasource',
    uid='${datasource}',
  )
  + timeSeries.gridPos.withX(gridX)
  + timeSeries.gridPos.withY(gridY)
  + timeSeries.gridPos.withW(gridW)
  + timeSeries.gridPos.withH(gridH)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(0)
  + timeSeries.standardOptions.withUnit(unit)
  + timeSeries.standardOptions.withMin(0)
  + createSimpleQueryTargets(testId, fieldName, metricLabel);

// Base panel function for complex queries  
local createComplexPanel(title, testId, fieldName, metricLabel, unit='short', gridX=0, gridY=0, gridW=12, gridH=8, additionalFields={}, divideBy=1) =
  timeSeries.new(title)
  + timeSeries.queryOptions.withDatasource(
    type='grafana-postgresql-datasource',
    uid='${datasource}',
  )
  + timeSeries.gridPos.withX(gridX)
  + timeSeries.gridPos.withY(gridY)
  + timeSeries.gridPos.withW(gridW)
  + timeSeries.gridPos.withH(gridH)
  + timeSeries.fieldConfig.defaults.custom.withDrawStyle('line')
  + timeSeries.fieldConfig.defaults.custom.withFillOpacity(0)
  + timeSeries.standardOptions.withUnit(unit)
  + timeSeries.standardOptions.withMin(0)
  + createComplexQueryTargets(testId, fieldName, metricLabel, additionalFields, divideBy);

// Dashboard panels
local panels = [
  // Row 1 - Simple queries
  createSimplePanel(
    'PipelineRun Succeeded', 
    391, 
    '__results_PipelineRuns_count_succeeded', 
    '__results_PipelineRuns_count_succeeded',
    'short',
    0, 0, 12, 8
  ),
  createSimplePanel(
    'PipelineRun Failed', 
    391, 
    ' __results_PipelineRuns_count_failed',  // Note: original has space prefix
    '__results_PipelineRuns_count_failed',
    'short',
    12, 0, 12, 8
  ),

  // Row 2 - Simple + Complex
  createSimplePanel(
    'PR Mean duration', 
    391, 
    '__results_PipelineRuns_duration_avg', 
    '__results_PipelineRuns_duration_avg',
    's',
    0, 8, 12, 8
  ),
  createComplexPanel(
    'Succeeded PR  Metrics', 
    391, 
    '__results_PipelineRuns_Success_pending_avg',
    'pending',
    's',
    12, 8, 12, 8,
    { 'running': '__results_PipelineRuns_Success_running_avg' }
  ),

  // Row 3 - Simple queries
  createSimplePanel(
    'TaskRun Succeeded', 
    391, 
    '__results_TaskRuns_count_succeeded', 
    '__results_TaskRuns_count_succeeded',
    'short',
    0, 16, 12, 8
  ),
  createSimplePanel(
    'TaskRun Failed', 
    391, 
    '__results_TaskRuns_count_failed', 
    '__results_TaskRuns_count_failed',
    'short',
    12, 16, 12, 8
  ),

  // Row 4 - Simple + Complex
  createSimplePanel(
    'TR Mean Success duration', 
    391, 
    '__results_TaskRuns_duration_avg', 
    '__results_TaskRuns_duration_avg',
    's',
    0, 24, 12, 8
  ),
  createSimplePanel(
    'Succeeded TR  Metrics', 
    391, 
    '__results_TaskRuns_duration_avg', 
    '__results_TaskRuns_duration_avg',
    's',
    12, 24, 12, 8
  ),

  // Row 5 - Complex queries
  createComplexPanel(
    'TaskRun to Pod Creation Duration', 
    391, 
    '__results_TaskRunsToPods_creationTimestampDiff_mean',
    'PodCreationTimeStamp',
    's',
    0, 32, 12, 8
  ),
  createComplexPanel(
    'Controllers CPU usage (Mean)', 
    391, 
    '__measurements_tektonPipelinesController_cpu_mean',
    'pipeline_controller_cpu',
    'percent',
    12, 32, 12, 8,
    { 
      'pipeline_webhook_cpu': '__measurements_tektonPipelinesWebhook_cpu_mean',
      'pipeline_proxy_webhook_cpu': '__measurements_tektonOperatorProxyWebhook_cpu_mean'
    }
  ),

  // Row 6 - Complex queries  
  createComplexPanel(
    'Controllers Memory usage (Mean)', 
    391, 
    '__measurements_tektonPipelinesController_memory_mean',
    'pipeline_controller_mem',
    'bytes',
    0, 40, 12, 8,
    { 
      'pipeline_webhook_mem': '__measurements_tektonPipelinesWebhook_memory_mean',
      'pipeline_proxy_webhook_mem': '__measurements_tektonOperatorProxyWebhook_memory_mean'
    },
    1048576  // Divide by 1048576 for MB
  ),
  createComplexPanel(
    'Pipelines Controller Workqueue Depth', 
    391, 
    '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean',
    'WorkqueueDepth_mean',
    'short',
    12, 40, 12, 8
  ),

  // Row 7 - Complex queries
  createComplexPanel(
    'Pipelines Controller Client Latency', 
    391, 
    '__measurements_tektonPipelinesControllerClientLatencyAverage_mean',
    'ClientLatencyAverage',
    's',
    0, 48, 12, 8
  ),
  createComplexPanel(
    'Cluster CPU Usage', 
    391, 
    '__measurements_clusterCpuUsageSecondsTotalRate_mean',
    'ClusterCpuUsage',
    'percent',
    12, 48, 12, 8
  ),

  // Row 8 - Complex queries
  createComplexPanel(
    'Cluster Memory Usage', 
    391, 
    '__measurements_clusterMemoryUsageRssTotal_mean',
    'ClusterMemUsage',
    'bytes',
    0, 56, 12, 8,
    {},
    1073741824  // Divide by 1073741824 for GB
  ),
  createComplexPanel(
    'OpenShift and Kube apiserver CPU Usage (Mean)', 
    391, 
    '__measurements_apiserver_cpu_mean',
    'api_server_cpu',
    'percent',
    12, 56, 12, 8,
    { 'kube_api_server_cpu': '__measurements_kubeApiserver_cpu_mean' },
    1073741824  // Note: Original had this divide - might be wrong, check data
  ),

  // Row 9 - Complex query
  createComplexPanel(
    'OpenShift and Kube apiserver Memory Usage (Mean)', 
    391, 
    '__measurements_apiserver_memory_mean',
    'api_server_mem',
    'bytes',
    0, 64, 24, 8,
    { 'kube_api_server_mem': '__measurements_kubeApiserver_memory_mean' },
    1073741824  // Divide by 1073741824 for GB
  ),
];

// Final dashboard
dashboard.new('Pipelines Performance Dashboard')
+ dashboard.withUid('Pipelines_Performance')
+ dashboard.withDescription('Dashboard visualizes OpenShift Pipelines performance metrics including PipelineRuns, TaskRuns, controller performance, and cluster resource usage')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar])
+ dashboard.withPanels(panels)
+ dashboard.withEditable(true)
+ dashboard.graphTooltip.withSharedCrosshair()
