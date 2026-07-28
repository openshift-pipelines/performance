local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

{
  testId: 425,

  versionExpr: "CASE WHEN label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = true THEN 'nightly' ELSE COALESCE(label_values->>'__deployment_version', 'unknown') END",

  datasourceVar:
    grafonnet.dashboard.variable.datasource.new(
      'datasource',
      'grafana-postgresql-datasource',
    )
    + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
    + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
    + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for Results metrics')
    + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource'),
}
