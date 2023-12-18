#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

TEST_RUN="${TEST_RUN:-./run.yaml}"

info "Setup"
cd tests/scaling-pipelines/
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark

info "Preparing for test with $TEST_RUN"
if [ "$TEST_RUN" == "./run.yaml" ]; then
    kubectl apply -f pipeline.yaml
elif [ "$TEST_RUN" == "./run-build-image.yaml" ]; then
    kubectl apply -f pipeline-build-image.yaml
    if kubectl create ns utils; then
        kubectl -n utils create deployment build-image-nginx --image=quay.io/rhcloudperfscale/git-http-smart-hosting --replicas=1 --port=8000
        kubectl -n utils expose deployment/build-image-nginx --port=80 --target-port=8080 --name=build-image-nginx
        kubectl -n utils rollout status --watch --timeout=300s deployment/build-image-nginx
        kubectl -n utils wait --for=condition=ready --timeout=300s pod -l app=build-image-nginx
    else
        debug "Skipping initial config as namespace utils already exists"
    fi
fi

info "Benchmark"
time ./benchmark-tekton.sh --total "${TEST_TOTAL:-100}" --concurrent "${TEST_CONCURRENT:-10}" --run "${TEST_RUN:-./run.yaml}" --debug

info "Dump Pods"
kubectl get pods -o=json >pods.json

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"
if ${TEST_DO_CLEANUP:-true}; then
    kubectl delete --all PipelineRuns
fi
