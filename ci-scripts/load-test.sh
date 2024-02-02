#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

TEST_TOTAL="${TEST_TOTAL:-100}"
TEST_CONCURRENT="${TEST_CONCURRENT:-10}"
TEST_RUN="${TEST_RUN:-./run.yaml}"
TEST_TIMEOUT="${TEST_TIMEOUT:-18000}"   # 5 hours

measure_signed_pid=""

info "General setup"
cd tests/scaling-pipelines/
kubectl create ns utils
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark

info "Cloning required repo"
[[ -d push-fake-image ]] || git clone https://github.com/jhutar/push-fake-image.git
[[ -d scenario/common ]] || ln -s $( pwd )/push-fake-image/scenario/common scenario/common
[[ -d scenario/signing-ongoing ]] || ln -s $( pwd )/push-fake-image/scenario/signing-ongoing scenario/signing-ongoing
[[ -d scenario/signing-bigbang ]] || ln -s $( pwd )/push-fake-image/scenario/signing-bigbang scenario/signing-bigbang
[[ -d scenario/signing-standoci-bigbang ]] || ln -s $( pwd )/push-fake-image/scenario/signing-standoci-bigbang scenario/signing-standoci-bigbang
[[ -d scenario/signing-tekton-bigbang ]] || ln -s $( pwd )/push-fake-image/scenario/signing-tekton-bigbang scenario/signing-tekton-bigbang

info "Setup for $TEST_SCENARIO scenario"
TEST_PIPELINE="scenario/$TEST_SCENARIO/pipeline.yaml"
TEST_RUN="scenario/$TEST_SCENARIO/run.yaml"
[ -f scenario/$TEST_SCENARIO/setup.sh ] && source scenario/$TEST_SCENARIO/setup.sh
kubectl apply -f "$TEST_PIPELINE"

if [ "$TEST_RUN" == "./run-image-signing-bigbang.yaml" ]; then
    info "Disabling Chains"   # note this removes signing-secrets secret
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'
    sleep 5
fi

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
