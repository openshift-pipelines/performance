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

function cosign_generate_key_pair_secret() {
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
elif [ "$TEST_RUN" == "./run-image-signing.yaml" ] || [ "$TEST_RUN" == "./run-image-signing-bigbang.yaml" ]; then
    [ -d push-fake-image ] || git clone https://github.com/jhutar/push-fake-image.git
    kubectl apply -f push-fake-image/pipeline.yaml
    # Configure Chains as per https://tekton.dev/docs/chains/signed-provenance-tutorial/#configuring-tekton-chains
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.taskrun.format": "slsa/v1"}}}'
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.taskrun.storage": "oci"}}}'
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.oci.storage": "oci"}}}'
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"transparency.enabled": "false"}}}'   # this is the only difference from the docs

    # Create signing-secrets secret
    cosign_generate_key_pair_secret

    # Wait for Chains controller to come up
    wait_for_entity_by_selector 300 openshift-pipelines deployment app.kubernetes.io/name=controller,app.kubernetes.io/part-of=tekton-chains
    oc -n openshift-pipelines rollout restart deployment/tekton-chains-controller
    oc -n openshift-pipelines rollout status deployment/tekton-chains-controller
    oc -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/part-of=tekton-chains

    # ImageStreamTag to push to
    oc -n benchmark create imagestream test

    # SA to talk to internal registry
    oc -n benchmark create serviceaccount perf-test-registry-sa
    oc policy add-role-to-user registry-viewer system:serviceaccount:benchmark:perf-test-registry-sa   # pull
    oc policy add-role-to-user registry-editor system:serviceaccount:benchmark:perf-test-registry-sa   # push

    # Customized PipelineRun
    dockerconfig_secret_name=$( oc -n benchmark get serviceaccount perf-test-registry-sa -o json | jq --raw-output '.imagePullSecrets[0].name' )
    cat ./push-fake-image/run.yaml | sed "s/DOCKERCONFIG_SECRET_NAME/$dockerconfig_secret_name/g" >$TEST_RUN
else
    fatal "Unknown TEST_RUN"
fi

if [ "$TEST_RUN" == "./run-image-signing.yaml" ]; then
    info "Starting to monitor signatures"
    ./push-fake-image/measure-signed.py --server "$( oc whoami --show-server )" --namespace benchmark --token "$( oc whoami -t )" --insecure --save ./measure-signed.csv &
    measure_signed_pid=$!
fi

if [ "$TEST_RUN" == "./run-image-signing-bigbang.yaml" ]; then
    info "Disabling Chains"   # note this removes signing-secrets secret
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'
    sleep 5
fi

info "Benchmark ${TEST_TOTAL}/${TEST_CONCURRENT}/${TEST_RUN}/${TEST_TIMEOUT}"
time ./benchmark-tekton.sh --total "${TEST_TOTAL}" --concurrent "${TEST_CONCURRENT}" --run "${TEST_RUN}" --timeout "${TEST_TIMEOUT}" --debug

if [ "$TEST_RUN" == "./run-image-signing-bigbang.yaml" ]; then
    info "Starting to monitor signatures"
    ./push-fake-image/measure-signed.py --server "$( oc whoami --show-server )" --namespace benchmark --token "$( oc whoami -t )" --insecure --save ./measure-signed.csv --verbose &
    measure_signed_pid=$!
    info "Enabling Chains"
    cosign_generate_key_pair_secret   # it was removed when we disabled Chains
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": false}}}'
fi

if [ -n "$measure_signed_pid" ]; then
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

    # Only now, when all imagestreamtags are in, we can consider the test done
    last_pushed=$( cat imagestreamtags.json | jq --raw-output '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.creationTimestamp' )
    cat "benchmark-tekton.json" | jq '.results.ended = "'"$last_pushed"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Configured test end time to match when last imagestreamtag was created: $last_pushed"

    info "Stopping ./push-fake-image/measure-signed.py PID $measure_signed_pid"
    kill "$measure_signed_pid" || true
fi

info "Dump Pods"
kubectl get pods -o=json >pods.json

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"
if ${TEST_DO_CLEANUP:-true}; then
    kubectl delete --all PipelineRuns
fi
