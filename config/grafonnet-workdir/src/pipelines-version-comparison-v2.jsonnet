local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local common = import 'lib/pipelines-common.libsonnet';
local versionBarLib = import 'lib/version-bar-common.libsonnet';

local dashboard = grafonnet.dashboard;

local versionExpr = common.versionExpr;
local testIdPredicate = common.testIdPredicate;
local datasourceVar = common.datasourceVar;
local variantVar = common.variantVar;

local versionVar = {
  type: 'query',
  name: 'version',
  label: 'Version',
  description: 'Select versions to compare. Use All to include every version.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT %s AS version FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__deployment_version' ORDER BY version DESC" % [versionExpr, testIdPredicate],
  multi: true,
  includeAll: true,
  current: { text: 'All', value: '$__all' },
  refresh: 2,
  sort: 0,
};

local concurrencyVar = {
  type: 'query',
  name: 'concurrency',
  label: 'Concurrency',
  description: 'Select a single concurrency level to compare versions at.',
  datasource: { type: 'grafana-postgresql-datasource', uid: '${datasource}' },
  query: "SELECT DISTINCT (label_values->>'__parameters_test_concurrent')::INTEGER AS concurrency FROM data WHERE %s AND $__timeFilter(start) AND label_values ? '__parameters_test_concurrent' ORDER BY concurrency" % testIdPredicate,
  multi: false,
  includeAll: false,
  current: { text: '1', value: '1' },
  refresh: 2,
  sort: 3,
};

local createQuery(fieldName, agg='AVG') =
  {
    rawSql: |||
      WITH daily AS (
        SELECT
          TO_CHAR(DATE_TRUNC('day', start), 'MM/DD') AS day,
          DATE_TRUNC('day', start) AS day_date,
          %s AS version,
          (label_values->>'%s')::DOUBLE PRECISION AS val
        FROM data
        WHERE %s
          AND $__timeFilter(start)
          AND %s IN ($version)
          AND (label_values->>'__parameters_test_concurrent')::INTEGER = ${concurrency}::INTEGER
          AND label_values ? '%s'
      )
      SELECT day, version, %s(val) AS value
      FROM daily
      GROUP BY day, version
      ORDER BY MIN(day_date),
        CASE WHEN version = 'nightly' THEN 0 ELSE 1 END,
        version ASC
    ||| % [versionExpr, fieldName, testIdPredicate, versionExpr, fieldName, agg],
    format: 'table',
    refId: 'A',
  };

local row = versionBarLib.row;

local versionBar(title, fieldName, unit, x, y, w, h, description='', agg='AVG', axisSoftMax=null) =
  versionBarLib.versionBar(createQuery, title, fieldName, unit, x, y, w, h, description, agg, axisSoftMax);

local pw = 24;
local ph = 8;

local allPanels = [

  row('Pipeline Performance', 0),
  versionBar('PipelineRun Duration (avg)', '__results_PipelineRuns_duration_avg', 's', 0, 1, pw, ph,
    description='Average PipelineRun wall-clock duration per version per day. Lower is better.'),
  versionBar('PipelineRun Succeeded', '__results_PipelineRuns_count_succeeded', 'short', 0, 9, pw, ph,
    description='Total successful PipelineRuns per version per day.', agg='SUM'),
  versionBar('PipelineRun Failed', '__results_PipelineRuns_count_failed', 'short', 0, 17, pw, ph,
    description='Total failed PipelineRuns per version per day. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('PR Pending Time (avg)', '__results_PipelineRuns_Success_pending_avg', 's', 0, 25, pw, ph,
    description='Average time a successful PipelineRun waited to be scheduled.'),
  versionBar('PR Running Time (avg)', '__results_PipelineRuns_Success_running_avg', 's', 0, 33, pw, ph,
    description='Average time a successful PipelineRun spent executing.'),

  row('TaskRun Performance', 41),
  versionBar('TaskRun Duration (avg)', '__results_TaskRuns_duration_avg', 's', 0, 42, pw, ph,
    description='Average successful TaskRun duration per version per day. Lower is better.'),
  versionBar('TaskRun Succeeded', '__results_TaskRuns_count_succeeded', 'short', 0, 50, pw, ph,
    description='Total successful TaskRuns per version per day.', agg='SUM'),
  versionBar('TaskRun Failed', '__results_TaskRuns_count_failed', 'short', 0, 58, pw, ph,
    description='Total failed TaskRuns per version per day. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('TR Pending Time (avg)', '__results_TaskRuns_Success_pending_avg', 's', 0, 66, pw, ph,
    description='Average Pod scheduling wait for successful TaskRuns.'),
  versionBar('TR Running Time (avg)', '__results_TaskRuns_Success_running_avg', 's', 0, 74, pw, ph,
    description='Average container execution time for successful TaskRuns.'),

  row('Controller Health', 82),
  versionBar('TaskRun → Pod Creation Lag', '__results_TaskRunsToPods_creationTimestampDiff_mean', 's', 0, 83, pw, ph,
    description='Mean time from TaskRun creation to Pod creation.'),
  versionBar('Controller CPU', '__measurements_tektonPipelinesController_cpu_mean', 'short', 0, 91, pw, ph,
    description='Tekton Pipelines controller mean CPU (cores).'),
  versionBar('Controller Memory', '__measurements_tektonPipelinesController_memory_mean', 'bytes', 0, 99, pw, ph,
    description='Tekton Pipelines controller mean memory (RSS).'),
  versionBar('Workqueue Depth', '__measurements_tektonTektonPipelinesControllerWorkqueueDepth_mean', 'short', 0, 107, pw, ph,
    description='Controller workqueue depth. High = bottleneck.'),
  versionBar('Webhook CPU', '__measurements_tektonPipelinesWebhook_cpu_mean', 'short', 0, 115, pw, ph,
    description='Admission webhook CPU.'),
  versionBar('Webhook Memory', '__measurements_tektonPipelinesWebhook_memory_mean', 'bytes', 0, 123, pw, ph,
    description='Admission webhook memory.'),
  versionBar('Controller Client Latency', '__measurements_tektonPipelinesControllerClientLatencyAverage_mean', 's', 0, 131, pw, ph,
    description='Controller → API server HTTP latency.'),

  row('Cluster & Infrastructure', 139),
  versionBar('Cluster CPU', '__measurements_clusterCpuUsageSecondsTotalRate_mean', 'short', 0, 140, pw, ph,
    description='Mean total cluster CPU usage rate (cores).'),
  versionBar('Cluster Memory', '__measurements_clusterMemoryUsageRssTotal_mean', 'bytes', 0, 148, pw, ph,
    description='Mean total cluster RSS memory.'),
  versionBar('API Server CPU', '__measurements_apiserver_cpu_mean', 'short', 0, 156, pw, ph,
    description='OpenShift API server mean CPU.'),
  versionBar('Kube API Server CPU', '__measurements_kubeApiserver_cpu_mean', 'short', 0, 164, pw, ph,
    description='Kubernetes API server mean CPU.'),
  versionBar('API Server Memory', '__measurements_apiserver_memory_mean', 'bytes', 0, 172, pw, ph,
    description='OpenShift API server mean memory.'),

  row('etcd', 180),
  versionBar('etcd DB Size', '__measurements_etcdMvccDbTotalSizeInBytesAverage_mean', 'bytes', 0, 181, pw, ph,
    description='Mean etcd MVCC database total size.'),
  versionBar('etcd DB In Use', '__measurements_etcdMvccDbTotalSizeInUseInBytesAverage_mean', 'bytes', 0, 189, pw, ph,
    description='Mean etcd live data size.'),
  versionBar('etcd Request Duration', '__measurements_etcdRequestDurationSecondsAverage_mean', 's', 0, 197, pw, ph,
    description='Mean etcd request latency.'),
  versionBar('etcd Restarts', '__measurements_etcd_restarts_range', 'short', 0, 205, pw, ph,
    description='etcd Pod restarts. Should be 0.', agg='SUM', axisSoftMax=5),
  versionBar('Scheduler Pending Pods', '__measurements_schedulerPendingPodsCount_range', 'short', 0, 213, pw, ph,
    description='Pending pods in kube-scheduler queue.', agg='SUM', axisSoftMax=5),
];

dashboard.new('Pipelines Version Comparison (v2)')
+ dashboard.withUid('Pipelines_Version_Comparison_v2')
+ dashboard.withDescription('Daily side-by-side version comparison of OpenShift Pipelines performance.')
+ dashboard.time.withFrom('now-14d')
+ dashboard.time.withTo('now')
+ dashboard.withTimezone('utc')
+ dashboard.withRefresh('5m')
+ dashboard.withVariables([datasourceVar, variantVar, versionVar, concurrencyVar])
+ dashboard.withPanels(allPanels)
+ dashboard.withEditable(true)
+ dashboard.withTags(['pipelines', 'version-comparison', 'performance'])
+ dashboard.graphTooltip.withSharedTooltip()
