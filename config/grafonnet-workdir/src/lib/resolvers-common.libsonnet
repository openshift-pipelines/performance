local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

{
  versionExpr: "CASE WHEN label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = true THEN 'nightly' ELSE COALESCE(label_values->>'__deployment_version', 'unknown') END",

  testIdPredicate: 'horreum_testid = 437',

  datasourceVar:
    grafonnet.dashboard.variable.datasource.new(
      'datasource',
      'grafana-postgresql-datasource',
    )
    + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
    + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
    + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for Resolvers metrics')
    + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource'),

  resolverVar: {
    type: 'custom',
    name: 'resolver',
    label: 'Resolver',
    description: 'Filter by resolver type.',
    query: 'git-resolver,bundle-resolver,cluster-resolver',
    multi: false,
    includeAll: false,
    current: { text: 'git-resolver', value: 'git-resolver' },
    options: [
      { text: 'git-resolver', value: 'git-resolver', selected: true },
      { text: 'bundle-resolver', value: 'bundle-resolver', selected: false },
      { text: 'cluster-resolver', value: 'cluster-resolver', selected: false },
    ],
  },
}
