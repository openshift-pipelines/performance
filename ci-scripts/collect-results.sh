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
results_api_logs="$ARTIFACT_DIR/results-api-logs.txt"
results_api_json="$ARTIFACT_DIR/results-api-logs.json"
results_api_error_logs="$ARTIFACT_DIR/results-api-logs-parse-errors.txt"
results_api_db_sql="$ARTIFACT_DIR/tekton-results-postgres-pgdump.sql"

info "Collecting artifacts..."
mkdir -p "${ARTIFACT_DIR}"
mkdir -p "${monitoring_collection_dir}"
[ -f tests/scaling-pipelines/benchmark-tekton.json ] && mv tests/scaling-pipelines/benchmark-tekton.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/benchmark-stats.csv ] && mv tests/scaling-pipelines/benchmark-stats.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/cluster-benchmark-stats.csv ] && mv tests/scaling-pipelines/cluster-benchmark-stats.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/pipelineruns-stats.csv ] && mv tests/scaling-pipelines/pipelineruns-stats.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/taskruns-stats.csv ] && mv tests/scaling-pipelines/taskruns-stats.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/benchmark-output.json ] && mv tests/scaling-pipelines/benchmark-output.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/pipelineruns.json ] && mv tests/scaling-pipelines/pipelineruns.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/taskruns.json ] && mv tests/scaling-pipelines/taskruns.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/pods.json ] && mv tests/scaling-pipelines/pods.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/resolutionrequests.json ] && mv tests/scaling-pipelines/resolutionrequests.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/imagestreamtags.json ] && mv tests/scaling-pipelines/imagestreamtags.json "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/measure-signed.csv ] && mv tests/scaling-pipelines/measure-signed.csv "${ARTIFACT_DIR}/"
[ -f tests/scaling-pipelines/locust-test.log ] && mv tests/scaling-pipelines/locust-test.log "${ARTIFACT_DIR}/"

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

# track monitoring start time
mstart=$(date --utc  --iso-8601=seconds)

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


if [ "$INSTALL_RESULTS" == "true" ]; then
    info "Collecting Results-API DB Dump"
    
    # Fetch Postgres User & Password 
    pg_user=$(oc -n openshift-pipelines get secret tekton-results-postgres -o json | jq -r '.data.POSTGRES_USER' | base64 -d)
    pg_pwd=$(oc -n openshift-pipelines get secret tekton-results-postgres -o json | jq -r '.data.POSTGRES_PASSWORD' | base64 -d)

    # Dump Postgres Database into SQL file
    oc -n openshift-pipelines exec -it tekton-results-postgres-0 -- bash -c "PGPASSWORD=$pg_pwd pg_dump tekton-results -U $pg_user" > $results_api_db_sql


    info "Collecting Results-API log data"

    # JSON fields from log lines
    JQ_FIELDS_TO_EXTRACT='{timestamp: .ts, "grpc.start_time": .["grpc.start_time"], "grpc.request.deadline": .["grpc.request.deadline"], "grpc.method": .["grpc.method"], "grpc.code": .["grpc.code"], "grpc.time_duration_in_ms": .["grpc.time_duration_in_ms"]}'

    # Fetch logs from results-api pods
    oc -n openshift-pipelines logs --tail=-1 -l app.kubernetes.io/name=tekton-results-api >> "$results_api_logs"
    oc -n tekton-pipelines logs --tail=-1 -l app.kubernetes.io/name=tekton-results-api >> "$results_api_logs"

    # Parse and store JSON log lines 
    echo "[" > "$results_api_json"
    grep -oP '\{.*?\}' "$results_api_logs" \
        | jq -e -c "$JQ_FIELDS_TO_EXTRACT" 2>"$results_api_error_logs" \
        | sed '$!s/$/,/' >> "$results_api_json"
    echo "]" >> "$results_api_json"
else
    info "Skipping Results-API log data"
fi
