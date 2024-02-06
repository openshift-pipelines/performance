#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

TEST_TOTAL="${TEST_TOTAL:-100}"
TEST_CONCURRENT="${TEST_CONCURRENT:-10}"
TEST_SCENARIO="${TEST_SCENARIO:-math}"
TEST_TIMEOUT="${TEST_TIMEOUT:-18000}"   # 5 hours

measure_signed_pid=""

info "General setup"
cd tests/scaling-pipelines/
kubectl create ns utils
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark

info "Setup for $TEST_SCENARIO scenario"
TEST_PIPELINE="scenario/$TEST_SCENARIO/pipeline.yaml"
TEST_RUN="scenario/$TEST_SCENARIO/run.yaml"
[ -f scenario/$TEST_SCENARIO/setup.sh ] && source scenario/$TEST_SCENARIO/setup.sh
kubectl apply -f "$TEST_PIPELINE"

info "Benchmark ${TEST_TOTAL} | ${TEST_CONCURRENT} | ${TEST_RUN} | ${TEST_TIMEOUT}"
time ./benchmark-tekton.sh --total "${TEST_TOTAL}" --concurrent "${TEST_CONCURRENT}" --run "${TEST_RUN}" --timeout "${TEST_TIMEOUT}" --debug

info "Tierdown for $TEST_SCENARIO scenario"
[ -f scenario/$TEST_SCENARIO/tierdown.sh ] && source scenario/$TEST_SCENARIO/tierdown.sh

info "Dump Pods"
kubectl get pods -o=json >pods.json

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"
if ${TEST_DO_CLEANUP:-true}; then
    kubectl delete --all PipelineRuns
fi
