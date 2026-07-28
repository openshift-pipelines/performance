local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

{
  versionExpr: "CASE WHEN label_values ? '__deployment_nightly' AND (label_values->>'__deployment_nightly')::BOOLEAN = true THEN 'nightly' ELSE COALESCE(label_values->>'__deployment_version', 'unknown') END",

  // Variant → Test ID mapping:
  //   427 = Standard, 428 = HA, 429 = QBT, 430 = HA+QBT
  //   418 = legacy (filtered by HA/QBT config)
  testIdPredicate: |||
    (
      horreum_testid = ${variant}::INTEGER
      OR (
        horreum_testid = 418
        AND (
          (${variant}::INTEGER = 427
            AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false)
            AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR (${variant}::INTEGER = 428
            AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true
            AND (NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false))
          OR (${variant}::INTEGER = 429
            AND (NOT (label_values ? '__deployment_haConfig_haEnabled') OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false)
            AND (label_values ? '__deployment_qbtConfig_qbtEnabled') AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true)
          OR (${variant}::INTEGER = 430
            AND (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true
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
    + grafonnet.dashboard.variable.custom.generalOptions.withDescription('PostgreSQL datasource for Chains metrics')
    + grafonnet.dashboard.variable.custom.generalOptions.withCurrent('grafana-postgresql-datasource'),

  variantVar: {
    type: 'custom',
    name: 'variant',
    label: 'Variant',
    description: 'Chains deployment variant (each maps to a separate Horreum test ID).',
    query: 'Standard : 427,HA : 428,QBT (non-HA) : 429,HA + QBT : 430',
    multi: false,
    includeAll: false,
    current: { text: 'Standard', value: '427' },
    options: [
      { text: 'Standard', value: '427', selected: true },
      { text: 'HA', value: '428', selected: false },
      { text: 'QBT (non-HA)', value: '429', selected: false },
      { text: 'HA + QBT', value: '430', selected: false },
    ],
  },
}
