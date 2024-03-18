#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

ARTIFACT_DIR=${ARTIFACT_DIR:-artifacts}
monitoring_collection_data=$ARTIFACT_DIR/benchmark-tekton.json
monitoring_collection_log=$ARTIFACT_DIR/monitoring-collection.log
monitoring_collection_dir=$ARTIFACT_DIR/monitoring-collection-raw-data-dir
tekton_pipelines_controller_log=$ARTIFACT_DIR/tekton-pipelines-controller.log
tekton_chains_controller_log=$ARTIFACT_DIR/tekton-chains-controller.log
creationtimestamp_collection_log=$ARTIFACT_DIR/creationtimestamp-collection.log

info "Collecting artifacts..."
mkdir -p "${ARTIFACT_DIR}"
mkdir -p "${monitoring_collection_dir}"
[ -f tests/scaling-pipelines/benchmark-tekton.json ] && cp tests/scaling-pipelines/benchmark-tekton.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/benchmark-stats.csv ] && cp tests/scaling-pipelines/benchmark-stats.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/pipelineruns.json ] && cp tests/scaling-pipelines/pipelineruns.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/taskruns.json ] && cp tests/scaling-pipelines/taskruns.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/pods.json ] && cp tests/scaling-pipelines/pods.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/imagestreamtags.json ] && cp tests/scaling-pipelines/imagestreamtags.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/measure-signed.csv ] && cp tests/scaling-pipelines/measure-signed.csv "${ARTIFACT_DIR}/"

info "Collecting logs..."
oc -n openshift-pipelines logs --tail=-1 --all-containers=true --max-log-requests=10 -l app.kubernetes.io/name=controller,app.kubernetes.io/part-of=tekton-pipelines,app=tekton-pipelines-controller >"$tekton_pipelines_controller_log" || true
oc -n openshift-pipelines logs --tail=-1 --all-containers=true --max-log-requests=10 -l app.kubernetes.io/name=controller,app.kubernetes.io/part-of=tekton-chains,app=tekton-chains-controller >"$tekton_chains_controller_log" || true

info "Setting up tool to collect monitoring data..."
python3 -m venv venv
set +u
source venv/bin/activate
set -u
python3 -m pip install --quiet -U pip
python3 -m pip install --quiet -e "git+https://github.com/redhat-performance/opl.git#egg=opl-rhcloud-perf-team-core&subdirectory=core"
set +u
deactivate
set -u

info "Collecting monitoring data..."
if [ -f "$monitoring_collection_data" ]; then
    set +u
    source venv/bin/activate
    set -u
    mstart=$(date --utc --date "$(status_data.py --status-data-file "$monitoring_collection_data" --get results.started)" --iso-8601=seconds)
    mend=$(date --utc --date "$(status_data.py --status-data-file "$monitoring_collection_data" --get results.ended)" --iso-8601=seconds)
    mhost=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o json | jq --raw-output '.items[0].spec.host')
    status_data.py \
        --status-data-file "$monitoring_collection_data" \
        --additional ./config/cluster_read_config.yaml \
        --monitoring-start "$mstart" \
        --monitoring-end "$mend" \
        --monitoring-raw-data-dir "$monitoring_collection_dir" \
        --prometheus-host "https://$mhost" \
        --prometheus-port 443 \
        --prometheus-token "$(oc whoami -t)" \
        -d &>"$monitoring_collection_log"
    set +u
    deactivate
    set -u
else
    warning "File $monitoring_collection_data not found!"
fi

info "Collecting TaskRun creationTimestamp -> Pod creationTimestamp difference..."
if [ -f "$monitoring_collection_data" ] && [ -f "${ARTIFACT_DIR}/taskruns.json" ] && [ -f "${ARTIFACT_DIR}/pods.json" ]; then
    set +u
    source venv/bin/activate
    set -u
    tools/compare-TaskRun-Pod-creationTimestamp.py \
        --status-data-file "$monitoring_collection_data" \
        --taskruns-list "${ARTIFACT_DIR}/taskruns.json" \
        --pods-list "${ARTIFACT_DIR}/pods.json" \
        -d &>"$creationtimestamp_collection_log"
    set +u
    deactivate
    set -u
else
    warning "Required files not found!"
fi
