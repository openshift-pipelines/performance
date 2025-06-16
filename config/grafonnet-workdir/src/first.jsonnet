local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

// Just some shortcuts
local dashboard = grafonnet.dashboard;
local timeSeries = grafonnet.panel.timeSeries;
local stat = grafonnet.panel.stat;
local table = grafonnet.panel.table;
local pieChart = grafonnet.panel.pieChart;

// Define "datasource" variable
local datasourceVar =
  grafonnet.dashboard.variable.datasource.new(
    'datasource',
    'grafana-postgresql-datasource',
  )
  + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')  // TODO
  + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
  + grafonnet.dashboard.variable.custom.generalOptions.withDescription(
    'Description'
  )
  + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource');

// Panel query
local queryTarget(testId, concurrency, fieldName) = {
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
  ||| % [fieldName, fieldName, concurrency, testId, concurrency],
  format: 'time_series',
};
local queryTargets(testId, fieldNames) = timeSeries.queryOptions.withTargets(
  [queryTarget(testId, 12, fieldName) for fieldName in fieldNames]
  + [queryTarget(testId, 14, fieldName) for fieldName in fieldNames]
  + [queryTarget(testId, 16, fieldName) for fieldName in fieldNames]
  + [queryTarget(testId, 18, fieldName) for fieldName in fieldNames]
  + [queryTarget(testId, 20, fieldName) for fieldName in fieldNames],
);

// Panel finally
local kpiPanel(testId, fieldNames, fieldUnit, panelName) =
  timeSeries.new(panelName)
  + timeSeries.queryOptions.withDatasource(
    type='grafana-postgresql-datasource',
    uid='${datasource}',
  )
  + timeSeries.fieldConfig.defaults.custom.withInsertNulls(129600000)  // 129600000 ms == 36 hours
  + timeSeries.gridPos.withH(8)
  + timeSeries.gridPos.withW(24)
  + timeSeries.standardOptions.withMin(0)
  + timeSeries.standardOptions.withUnit(fieldUnit)
  + queryTargets(testId, fieldNames);


dashboard.new('Pipelines TODO')
+ dashboard.withUid('Pipelines_TODO')
+ dashboard.withDescription('Dashboard visualizes TODO')
+ dashboard.time.withFrom(value='now-14d')
+ dashboard.withVariables([datasourceVar])
+ dashboard.withPanels([
  kpiPanel(391, ['__results_PipelineRuns_duration_avg'], 's', 'Mean duration'),
])
