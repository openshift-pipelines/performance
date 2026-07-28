local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

{
  versionExpr: "CASE WHEN label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = true THEN 'nightly' ELSE COALESCE(label_values->>'__deployment_version', 'unknown') END",

  // Variant → Test ID mapping:
  //   423 = Standard, 419 = HA-Deployments, 421 = HA-StatefulSets
  //   422 = QBT, 420 = HA+QBT, 391 = legacy (filtered by HA/QBT config)
  testIdPredicate: |||
    (
      horreum_testid = ${variant}::INTEGER
      OR (
        horreum_testid = 391
        AND (
          (${variant}::INTEGER = 423
            AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false)
            AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR (${variant}::INTEGER = 419
            AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true
            AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments'
            AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR (${variant}::INTEGER = 421
            AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true
            AND (label_values->>'__deployment_haConfig_controllerType') = 'statefulSets'
            AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR (${variant}::INTEGER = 422
            AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false)
            AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
          OR (${variant}::INTEGER = 420
            AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true
            AND (label_values->>'__deployment_haConfig_controllerType') = 'deployments'
            AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
        )
      )
    )
  |||,

  datasourceVar:
    grafonnet.dashboard.variable.datasource.new(
      'datasource',
      'grafana-postgresql-datasource',
    )
    + grafonnet.dashboard.variable.datasource.withRegex('.*grafana-postgresql-datasource.*')
    + grafonnet.dashboard.variable.custom.generalOptions.withLabel('Datasource')
    + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for pipeline metrics')
    + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource'),

  variantVar: {
    type: 'custom',
    name: 'variant',
    label: 'Variant',
    description: 'Pipeline deployment variant (each maps to a separate Horreum test ID).',
    query: 'Standard : 423,HA - Deployments : 419,HA - StatefulSets : 421,QBT (non-HA) : 422,HA + QBT : 420',
    multi: false,
    includeAll: false,
    current: { text: 'Standard', value: '423' },
    options: [
      { text: 'Standard', value: '423', selected: true },
      { text: 'HA - Deployments', value: '419', selected: false },
      { text: 'HA - StatefulSets', value: '421', selected: false },
      { text: 'QBT (non-HA)', value: '422', selected: false },
      { text: 'HA + QBT', value: '420', selected: false },
    ],
  },
}
