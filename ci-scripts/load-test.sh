#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $(dirname $0)/lib.sh

info "Setup"
cd tests/scalingPipelines/
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark
kubectl apply -f pipeline.yaml

info "Benchmark"
time ./benchmark-tekton.sh --total 1000 --concurrent 100 --debug

info "Cleanup"
kubectl delete --all PipelineRuns
