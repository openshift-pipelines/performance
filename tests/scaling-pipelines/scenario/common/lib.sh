function cosign_generate_key_pair_secret() {
    if kubectl -n openshift-pipelines get secret/signing-secrets 2>/dev/null; then
        immutable="$( kubectl -n openshift-pipelines get secret/signing-secrets -o json | jq --raw-output ".immutable" )"
        if [[ $immutable == "true" ]]; then
            debug "Secret signing-secrets already there, immutable, skipping creating it again"
            return
        fi
    fi

    info "Generating signing-secrets secret"
    export COSIGN_PASSWORD=reset
    before=$( date +%s )
    while ! cosign generate-key-pair -d k8s://openshift-pipelines/signing-secrets; do
        now=$( date +%s )
        [ $(( $now - $before )) -gt 300 ] && fatal "Was not able to create signing-secrets secret in time"
        debug "Waiting for next attempt for creation of signing-secrets secret"
        # Few steps to get us to simple state
        oc -n openshift-pipelines get secrets/signing-secrets || true
        oc -n openshift-pipelines delete secrets/signing-secrets || true
        sleep 10
    done
}

function chains_setup_generic() {
    local artifacts_pipelinerun_format="$1"
    local artifacts_taskrun_format="$2"
    local artifacts_oci_storage="$3"

    info "Setting up Chains with $artifacts_pipelinerun_format/$artifacts_taskrun_format/$artifacts_oci_storage"

    # Configure Chains similar to https://tekton.dev/docs/chains/signed-provenance-tutorial/#configuring-tekton-chains
    kubectl patch TektonConfig/config \
        --type='merge' \
        -p='{"spec":{"chain":{"disabled": false}}}'

    if [[ -n "$artifacts_pipelinerun_format" ]]; then
        kubectl patch TektonConfig/config \
            --type merge \
            -p '{"spec":{"chain":{"artifacts.pipelinerun.format": "slsa/v1"}}}'
        kubectl patch TektonConfig/config \
            --type merge \
            -p '{"spec":{"chain":{"artifacts.pipelinerun.storage": "'"$artifacts_pipelinerun_format"'"}}}'
    fi

    if [[ -n "$artifacts_taskrun_format" ]]; then
        kubectl patch TektonConfig/config \
            --type='merge' \
            -p='{"spec":{"chain":{"artifacts.taskrun.format": "slsa/v1"}}}'
        kubectl patch TektonConfig/config \
            --type='merge' \
            -p='{"spec":{"chain":{"artifacts.taskrun.storage": "'"$artifacts_taskrun_format"'"}}}'
    fi

    if [[ -n "$artifacts_oci_storage" ]]; then
        kubectl patch TektonConfig/config \
            --type='merge' \
            -p='{"spec":{"chain":{"artifacts.oci.storage": "'"$artifacts_oci_storage"'"}}}'
    fi

    # Do not push stuff outside of cluster
    kubectl patch TektonConfig/config \
        --type='merge' \
        -p='{"spec":{"chain":{"transparency.enabled": "false"}}}'

    # Create signing-secrets secret
    cosign_generate_key_pair_secret

    # Wait for Chains controller to come up
    wait_for_entity_by_selector 300 openshift-pipelines deployment app.kubernetes.io/name=controller,app.kubernetes.io/part-of=tekton-chains
    wait_for_entity_by_selector 300 openshift-pipelines pod app.kubernetes.io/part-of=tekton-chains
    oc -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/part-of=tekton-chains
}

function chains_setup_tekton_tekton() {
    chains_setup_generic "" tekton tekton
}
function chains_setup_oci_oci() {
    chains_setup_generic "" oci oci
}
function chains_setup_tekton_tekton_() {
    chains_setup_generic "tekton" "tekton" ""
}

function chains_start() {
    info "Enabling Chains"
    cosign_generate_key_pair_secret   # it was removed when we disabled Chains
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": false}}}'
}

function chains_stop() {
    info "Disabling Chains"
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'
}

function pruner_start() {
    info "Enabling Pruner"
    kubectl patch TektonConfig config --type merge --patch "{\"spec\":{\"pruner\":{\"disabled\": false,\"resources\":[\"taskrun\", \"pipelinerun\"],\"schedule\":\"${PRUNER_SCHEDULE:-* * * * *}\",\"keep\":${PRUNER_KEEP:-3},\"prune-per-resource\":${PRUNE_PER_RESOURCE:-true}}}}"
}

function pruner_stop() {
    info "Disabling Pruner"
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"pruner":{"disabled": true}}}'
}

function internal_registry_setup() {
    info "Setting up internal registry"

    # Create ImageStreamTag we will be pushing to
    oc -n benchmark create imagestream test

    # SA to talk to internal registry
    oc -n benchmark create serviceaccount perf-test-registry-sa
    oc policy add-role-to-user registry-viewer system:serviceaccount:benchmark:perf-test-registry-sa   # pull
    oc policy add-role-to-user registry-editor system:serviceaccount:benchmark:perf-test-registry-sa   # push

    # Load SA to be added to PipelineRun
    dockerconfig_secret_name=$( oc -n benchmark get serviceaccount perf-test-registry-sa -o json | jq --raw-output '.imagePullSecrets[0].name' )
}

function standalone_registry_setup() {
    info "Deploy standalone registry"

    # Create secrets
    kubectl -n utils create secret generic registry-certs --from-file=registry.crt=scenario/common/certs/registry.crt --from-file=registry.key=scenario/common/certs/registry.key
    kubectl -n utils create secret generic registry-auth --from-file=scenario/common/certs/htpasswd

    # Deployment
    kubectl -n utils apply -f scenario/common/registry.yaml
    oc -n utils get deployment --show-labels
    wait_for_entity_by_selector 300 utils pod app=registry
    kubectl -n utils wait --for=condition=ready --timeout=300s pod -l app=registry

    # Dockenconfig to access the registry
    kubectl -n benchmark create secret docker-registry test-dockerconfig --docker-server=registry.utils.svc.cluster.local:5000 --docker-username=test --docker-password=test --docker-email=test@example.com
}

function pipeline_and_pipelinerun_setup() {
    local image_name="$1"
    local dockerconfig_secret_name="$2"

    info "Generating Pipeline and PipelineRun"
    cp scenario/common/pipeline.yaml scenario/$TEST_SCENARIO/pipeline.yaml
    cp scenario/common/run.yaml scenario/$TEST_SCENARIO/run.yaml
    sed -i "s|IMAGE_NAME|$image_name|g" scenario/$TEST_SCENARIO/run.yaml
    sed -i "s|DOCKERCONFIG_SECRET_NAME|$dockerconfig_secret_name|g" scenario/$TEST_SCENARIO/run.yaml
}

function imagestreamtags_wait() {
    info "Collecting info about imagestreamtags"
    before=$( date +%s )
    while true; do
        oc -n benchmark get imagestreamtags.image.openshift.io -o json >imagestreamtags.json
        count_all=$( cat imagestreamtags.json | jq --raw-output '.items | length' )
        count_signatures=$( cat imagestreamtags.json | jq --raw-output '.items | map(select(.metadata.name | endswith(".sig"))) | length' )
        count_attestations=$( cat imagestreamtags.json | jq --raw-output '.items | map(select(.metadata.name | endswith(".att"))) | length' )
        count_plain=$( cat imagestreamtags.json | jq --raw-output '.items | map(select((.metadata.name | endswith(".sig") | not) and (.metadata.name | endswith(".att") | not))) | length' )
        if [[ $count_plain -eq $count_signatures ]] && [[ $count_plain -eq $count_attestations ]]; then
            debug "All artifacts present"
            break
        else
            now=$( date +%s )
            if [ $(( $now - $before )) -gt $(( $TEST_TOTAL * 3 + 100 )) ]; then
                warning "Not all artifacts present ($count_plain/$count_signatures/$count_attestations) but we have already waited for $(( $now - $before )) seconds, so giving up."
                break
            fi
            debug "Not all artifacts present yet ($count_plain/$count_signatures/$count_attestations), waiting bit more"
            sleep 10
        fi
    done

    cat "benchmark-tekton.json" | jq '.results.imagestreamtags.sig = '$count_signatures' | .results.imagestreamtags.att = '$count_attestations' | .results.imagestreamtags.plain = '$count_plain' | .results.imagestreamtags.all = '$count_all'' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Got these counts of imagestreamtags: all=${count_all}, plain=${count_plain}, signatures=${count_signatures}, attestations=${count_attestations}"
}

function measure_signed_wait() {
    info "Waiting for benchmark.py to quit PID $( cat ./measure-signed.pid )"
    wait "$( cat ./measure-signed.pid )"
    info "Now benchmark.py finished PID $( cat ./measure-signed.pid )"
}

function measure_signed_start() {
    expecte="${1:-$TEST_TOTAL}"
    info "Starting benchmark.py (with 0 concurrent tasks) to monitor signatures"
    ../../tools/benchmark.py --insecure --namespace $TEST_NAMESPACE --total $TEST_TOTAL --concurrent 0 --wait-for-state signed_true --stats-file benchmark-stats.csv --verbose &
    measure_signed_pid=$!
    echo "$measure_signed_pid" >./measure-signed.pid
    debug "Started benchmark.py with PID $measure_signed_pid"
}

function measure_signed_stop() {
    info "Stopping benchmark.py PID $( cat ./measure-signed.pid )"
    kill "$( cat ./measure-signed.pid )" || true
    rm -f ./measure-signed.pid
}

function internal_registry_cleanup() {
    if ${TEST_DO_CLEANUP:-true}; then
        oc -n benchmark delete serviceaccount/perf-test-registry-sa
        oc -n benchmark delete imagestreamtags/test
    fi
}

function set_started_now() {
    cat "benchmark-tekton.json" | jq '.results.started = "'"$( date -Iseconds --utc )"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Set test started time"
}

function set_ended_now() {
    cat "benchmark-tekton.json" | jq '.results.ended = "'"$(  date -Iseconds --utc )"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Set test ended time"
}

function set_ended_last_imagestreamtag() {
    last_pushed=$( cat imagestreamtags.json | jq --raw-output '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.creationTimestamp' )
    cat "benchmark-tekton.json" | jq '.results.ended = "'"$last_pushed"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Set test ended time to be when last imagestreamtag was created"
}

function generate_more_start() {
    local total="$1"
    local concurrent="$2"
    local run="$3"
    local timeout="$4"
    local namespace="$5"
    local wait_for_state="${6:-total}"
    info "Generate more ${total} | ${concurrent} | ${run} | ${timeout}"
    time ../../tools/benchmark.py --insecure --namespace "${namespace}" --total "${total}" --concurrent "${concurrent}" --run "${run}" --wait-for-state "${wait_for_state}" --stats-file benchmark-stats.csv --verbose &
    generate_more_pid=$!
    echo "$generate_more_pid" >./generate-more.pid
    debug "Started generating PRs with PID $generate_more_pid"
}

function generate_more_wait() {
    info "Waiting for generating PRs to quit PID $( cat ./generate-more.pid )"
    wait "$( cat ./generate-more.pid )"
    info "Now generating PRs finished PID $( cat ./generate-more.pid )"
}

function wait_for_prs_finished() {
    # Wait until there is given number of finished PRs in
    # tests/scaling-pipelines/benchmark-stats.csv
    local target="$1"
    local last_row=""
    local prs_finished=""
    local namespace="${TEST_NAMESPACE}"
    info "Waiting for $target finished PipelineRuns"
    while true; do
        if [ -r benchmark-stats.csv ]; then
            last_row="$( tail -n $namespace benchmark-stats.csv )"
            prs_finished_per_namespace="$( echo "$last_row" | cut -d ',' -f 8 )"
            total_prs_finished="$(echo $prs_finished_per_namespace | tr ' ' '+' | bc)"
            prs_finished=$((total_prs_finished / namespace))
            if echo "$prs_finished" | grep '[^0-9]'; then
                debug "Waiting for PRs: Parsed '$prs_finished' as a number of finished PipelineRuns, but that does not look like a number"
            else
                if [[ prs_finished -ge target ]]; then
                    info "Waiting for PRs: Reached $target with $prs_finished, wait is over"
                    break
                else
                    debug "Waiting for PRs: Have not reached $target with $prs_finished, waiting"
                fi
            fi
        else
            debug "Waiting for PRs: File benchmark-stats.csv does not exist yet, waiting"
        fi
        sleep 10
    done
}

function wait_for_timeout() {
    # Wait until a certain timeout
    local timeout="$1"
    local message="$2"

    info "Waiting for $timeout seconds timeout to '$message'"
    sleep $timeout
    info "Timeout completed."
}

function create_pipeline_from_j2_template() {
    local template="$1"
    local extra_data_string="${2:-}"
    info "Populating Jinja2 Template: ${template}"
    time ../../tools/create-pipeline-yaml.py -f "scenario/$TEST_SCENARIO/${template}" -d --extra-data="${extra_data_string}"
}
