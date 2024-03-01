#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Just a helper script to output CSV file based on all found benchmark-tekton.json files

find . -name benchmark-tekton.json -print0 | while IFS= read -r -d '' filename; do 
    cat "${filename}" | jq --raw-output '[
        .metadata.env.BUILD_ID,
        .results.started,
        .results.ended,
        .parameters.test.run,
        .parameters.test.total,
        .parameters.test.concurrent,
        .results.signatures.signed_true,
        .results.signatures.latency_created_succeeded,
        .results.signatures.latency_succeeded_signed,
        .results.PipelineRuns.count.succeeded,
        .results.PipelineRuns.count.failed,
        .results.PipelineRuns.pending.avg,
        .results.PipelineRuns.running.avg,
        .results.PipelineRuns.duration.avg,
        .results.TaskRuns.pending.avg,
        .results.TaskRuns.running.avg,
        .results.TaskRuns.duration.avg,
        .results.TaskRuns_to_Pods.creationTimestamp_diff.mean,
        .measurements."tekton-pipelines-controller".count_ready.mean,
        .measurements."tekton-pipelines-controller".cpu.mean,
        .measurements."tekton-pipelines-controller".cpu.max,
        .measurements."tekton-pipelines-controller".memory.mean,
        .measurements."tekton-pipelines-controller".memory.max,
        .measurements."tekton-pipelines-webhook".count_ready.mean,
        .measurements."tekton-pipelines-webhook".cpu.mean,
        .measurements."tekton-pipelines-webhook".cpu.max,
        .measurements."tekton-pipelines-webhook".memory.mean,
        .measurements."tekton-pipelines-webhook".memory.max,
        .measurements."tekton-chains-controller".count_ready.mean,
        .measurements."tekton-chains-controller".cpu.mean,
        .measurements."tekton-chains-controller".cpu.max,
        .measurements."tekton-chains-controller".memory.mean,
        .measurements."tekton-chains-controller".memory.max,
        .measurements."tekton-operator-proxy-webhook".count_ready.mean,
        .measurements."tekton-operator-proxy-webhook".cpu.mean,
        .measurements."tekton-operator-proxy-webhook".cpu.max,
        .measurements."tekton-operator-proxy-webhook".memory.mean,
        .measurements."tekton-operator-proxy-webhook".memory.max,
        .measurements.tekton_tekton_pipelines_controller_workqueue_depth.mean,
        .measurements.tekton_pipelines_controller_running_taskruns_throttled_by_node.mean,
        .measurements.tekton_pipelines_controller_running_taskruns_throttled_by_quota.mean,
        .measurements.tekton_pipelines_controller_client_latency_average.mean,
        .measurements.tekton_pipelines_controller_taskruns_pod_latency_milliseconds.mean,
        .measurements.etcd_request_duration_seconds_average.mean,
        .measurements.etcd_mvcc_db_total_size_in_bytes_average.mean,
        .measurements.apiserver_request_total_rate.mean,
        .measurements.cluster_cpu_usage_seconds_total_rate.mean,
        .measurements.cluster_memory_usage_rss_total.mean,
        .measurements.workers_avg_cpu_usage_percentage.mean,
        .measurements.scheduler_pending_pods_count.mean,
        .measurements.apiserver.cpu.mean,
        .measurements.apiserver.memory.mean,
        .measurements."kube-apiserver".cpu.mean,
        .measurements."kube-apiserver".memory.mean,
        .measurements.event_exporter_event_count_all_sum.range,
        .measurements.event_exporter_event_count_benchmark_sum.range
        ] | @csv' \
        && rc=0 || rc=1
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR failed on ${filename}"
    fi
done
