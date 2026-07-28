local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local barChart = grafonnet.panel.barChart;

// Column ordering: nightly first, then 1.0-1.50. Unused entries are ignored.
local versionOrder = ['nightly'] + ['1.%d' % i for i in std.range(0, 50)];

local matrixTransform = [
  {
    id: 'groupingToMatrix',
    options: {
      columnField: 'version',
      rowField: 'day',
      valueField: 'value',
    },
  },
  {
    id: 'organize',
    options: {
      indexByName: { ['day\\version']: 0 } + {
        [versionOrder[i]]: i + 1
        for i in std.range(0, std.length(versionOrder) - 1)
      },
    },
  },
];

{
  row(title, y): {
    type: 'row',
    title: title,
    gridPos: { h: 1, w: 24, x: 0, y: y },
  },

  versionBar(buildQuery, title, fieldName, unit, x, y, w, h, description='', agg='AVG', axisSoftMax=null):
    barChart.new(title)
    + barChart.queryOptions.withDatasource(type='grafana-postgresql-datasource', uid='${datasource}')
    + (if description != '' then barChart.panelOptions.withDescription(description) else {})
    + barChart.gridPos.withX(x)
    + barChart.gridPos.withY(y)
    + barChart.gridPos.withW(w)
    + barChart.gridPos.withH(h)
    + barChart.standardOptions.withUnit(unit)
    + barChart.standardOptions.withMin(0)
    + (if agg == 'SUM' then barChart.standardOptions.withDecimals(0) else {})
    + barChart.options.withTooltip({ mode: 'multi', sort: 'none' })
    + barChart.options.withLegend({ displayMode: 'list', placement: 'bottom', calcs: [] })
    + barChart.options.withBarWidth(0.85)
    + barChart.options.withGroupWidth(0.55)
    + barChart.options.withShowValue('never')
    + (if axisSoftMax != null then { fieldConfig+: { defaults+: { custom+: { axisSoftMax: axisSoftMax } } } } else {})
    + barChart.queryOptions.withTargets([buildQuery(fieldName, agg)])
    + barChart.queryOptions.withTransformations(matrixTransform),
}
