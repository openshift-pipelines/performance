#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

TEST_TOTAL="${TEST_TOTAL:-100}"
TEST_CONCURRENT="${TEST_CONCURRENT:-10}"
TEST_NAMESPACE="${TEST_NAMESPACE:-1}"
TEST_SCENARIO="${TEST_SCENARIO:-math}"
TEST_TIMEOUT="${TEST_TIMEOUT:-18000}"   # 5 hours
TEST_PARAMS="${TEST_PARAMS:-}"

measure_signed_pid=""

info "General setup"
cd tests/scaling-pipelines/

info "Setup for $TEST_SCENARIO scenario"
TEST_PIPELINE="scenario/$TEST_SCENARIO/pipeline.yaml"
TEST_RUN="scenario/$TEST_SCENARIO/run.yaml"
[ -f scenario/$TEST_SCENARIO/setup.sh ] && source scenario/$TEST_SCENARIO/setup.sh

for namespace_idx in $(seq 1 ${TEST_NAMESPACE});
do
    # Generate namespace as "benchmark" by default for TEST_NAMESPACE set to 1
    # Otherwise generate based on index count
    namespace_tag=$([ "$TEST_NAMESPACE" -eq 1 ] && echo "" || echo "$namespace_idx")
    namespace="benchmark${namespace_tag}"

    kubectl create ns "${namespace}"
    # kubectl config set-context --current --namespace=${namespace}

    info "Creating Tasks and Pipeline in namespace: ${namespace}"
    kubectl apply -n "${namespace}" -f "$TEST_PIPELINE"
done

info "Benchmark ${TEST_TOTAL} | ${TEST_CONCURRENT} | ${TEST_RUN} | ${TEST_NAMESPACE}"
before=$(date -Ins --utc)
if [ -n "${WAIT_TIME:-}" ]; then
    info "Waiting to establish a baseline performance before creating PRs/TRs"
    sleep $WAIT_TIME
    info "Wait timeout completed"
fi

time ../../tools/benchmark.py --insecure --namespace "${TEST_NAMESPACE}" --total "${TEST_TOTAL}" --concurrent "${TEST_CONCURRENT}" --run "${TEST_RUN}" --stats-file benchmark-stats.csv --output-file benchmark-output.json --verbose $TEST_PARAMS
after=$(date -Ins --utc)

time ../../tools/stats.sh "$before" "$after"

info "Tierdown for $TEST_SCENARIO scenario"
[ -f scenario/$TEST_SCENARIO/tierdown.sh ] && source scenario/$TEST_SCENARIO/tierdown.sh

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"

# Empty array to store pod.json output from each namespace
pod_jsons=()

for namespace_idx in $(seq 1 ${TEST_NAMESPACE});
do
    namespace_tag=$([ "$TEST_NAMESPACE" -eq 1 ] && echo "" || echo "$namespace_idx")
    namespace="benchmark${namespace_tag}"

    info "Dump Pods from namespace: ${namespace}"
    pod_jsons+=("$(kubectl get po -o json -n "${namespace}")")

    if ${TEST_DO_CLEANUP:-true}; then
        info "Cleanup PipelineRuns in namespace: ${namespace}"
        kubectl delete -n "${namespace}" --all PipelineRuns
    fi
done

# Combine JSON outputs using jq
pod_json_out=$(printf '%s\n' "${pod_jsons[@]}" | jq -s '{items: map(.items) | add}')
combined_json=$(echo "$pod_json_out" | jq '. += {"apiVersion":"v1", "kind": "List", "metadata": {}}')
echo "$combined_json" > pods.json
