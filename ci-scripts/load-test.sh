#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

TEST_TOTAL="${TEST_TOTAL:-100}"
TEST_CONCURRENT="${TEST_CONCURRENT:-10}"
TEST_SCENARIO="${TEST_SCENARIO:-math}"
TEST_TIMEOUT="${TEST_TIMEOUT:-18000}"   # 5 hours
TEST_PARAMS="${TEST_PARAMS:-}"

measure_signed_pid=""

info "General setup"
cd tests/scaling-pipelines/
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark

info "Setup for $TEST_SCENARIO scenario"
TEST_PIPELINE="scenario/$TEST_SCENARIO/pipeline.yaml"
TEST_RUN="scenario/$TEST_SCENARIO/run.yaml"
[ -f scenario/$TEST_SCENARIO/setup.sh ] && source scenario/$TEST_SCENARIO/setup.sh
kubectl apply -f "$TEST_PIPELINE"

info "Benchmark ${TEST_TOTAL} | ${TEST_CONCURRENT} | ${TEST_RUN}"
before=$(date -Ins --utc)
if [ -n "$WAIT_TIME" ]; then
    info "Waiting to establish a baseline performance before creating PRs/TRs"
    sleep $WAIT_TIME
    info "Wait timeout completed"
fi
time ../../tools/benchmark.py --insecure --total "${TEST_TOTAL}" --concurrent "${TEST_CONCURRENT}" --run "${TEST_RUN}" --stats-file benchmark-stats.csv --output-file benchmark-output.json --verbose $TEST_PARAMS
after=$(date -Ins --utc)
time ../../tools/stats.sh "$before" "$after"

info "Tierdown for $TEST_SCENARIO scenario"
[ -f scenario/$TEST_SCENARIO/tierdown.sh ] && source scenario/$TEST_SCENARIO/tierdown.sh

info "Dump Pods"
kubectl get pods -o=json >pods.json

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"
if ${TEST_DO_CLEANUP:-true}; then
    kubectl delete --all PipelineRuns
fi
