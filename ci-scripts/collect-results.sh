#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $(dirname $0)/lib.sh

ARTIFACT_DIR=${ARTIFACT_DIR:-artifacts}
monitoring_collection_data=$ARTIFACT_DIR/benchmark-tekton.json
monitoring_collection_log=$ARTIFACT_DIR/monitoring-collection.log

info "Collecting artifacts..."
mkdir -p "${ARTIFACT_DIR}"
[ -f tests/scaling-pipelines/benchmark-tekton.json ] && cp tests/scaling-pipelines/benchmark-tekton.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/benchmark-tekton-runs.json ] && cp tests/scaling-pipelines/benchmark-tekton-runs.json "${ARTIFACT_DIR}/"

info "Setting up tool to collect monitoring data..."
python3 -m venv venv
set +u
source venv/bin/activate
set -u
python3 -m pip install -U pip
python3 -m pip install -e "git+https://github.com/redhat-performance/opl.git#egg=opl-rhcloud-perf-team-core&subdirectory=core"
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
        --prometheus-host "https://$mhost" \
        --prometheus-port 443 \
        --prometheus-token "$(oc whoami -t)" \
        -d &>$monitoring_collection_log
    set +u
    deactivate
    set -u
else
    warning "File $monitoring_collection_data not found!"
fi

