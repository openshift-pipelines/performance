#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

function entity_by_selector_exists() {
    local ns
    local entity
    local l
    local count

    ns="$1"
    entity="$2"
    l="$3"
    count=$( kubectl -n "$ns" get "$entity" -l "$l" -o name 2>/dev/null | wc -l )

    debug "Number of $entity entities in $ns with label $l: $count"
    [ "$count" -gt 0 ]
}

function wait_for_entity_by_selector() {
    local timeout
    local ns
    local entity
    local l
    local before
    local now

    timeout="$1"
    ns="$2"
    entity="$3"
    l="$4"
    before=$(date --utc +%s)

    while ! entity_by_selector_exists "$ns" "$entity" "$l"; do
        now=$(date --utc +%s)
        if [[ $(( now - before )) -ge "$timeout" ]]; then
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( now - before ))/$timeout), waiting and trying again"
        sleep 3
    done
}

info "Deploy pipelines $DEPLOYMENT_TYPE/$DEPLOYMENT_VERSION"
if [ "$DEPLOYMENT_TYPE" == "downstream" ]; then

    DEPLOYMENT_CSV_VERSION="$DEPLOYMENT_VERSION.0"
    [ "$DEPLOYMENT_VERSION" == "1.11" ] && DEPLOYMENT_CSV_VERSION="1.11.1"

    cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators: ""
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: pipelines-${DEPLOYMENT_VERSION}
  installPlanApproval: Manual
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: openshift-pipelines-operator-rh.v${DEPLOYMENT_CSV_VERSION}
EOF

    info "Wait for installplan to appear"
    wait_for_entity_by_selector 300 openshift-operators InstallPlan operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators=
    ip_name=$(kubectl -n openshift-operators get installplan -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators= -o name)
    kubectl -n openshift-operators patch -p '{"spec":{"approved":true}}' --type merge "$ip_name"

    if [ "$DEPLOYMENT_VERSION" == "1.11" ]; then
        warning "Configure resources for tekton-pipelines-controller is supported since 1.12"
    else
        info "Configure resources for tekton-pipelines-controller"
        wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
        kubectl patch TektonConfig/config --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":{"requests":{"memory":"2Gi","cpu":"1"},"limits":{"memory":"2Gi","cpu":"1"}}}]}}}}}}}}}' --type merge
    fi

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-webhook
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook

    info "Deployment finished"
    kubectl -n openshift-pipelines get pods

elif [ "$DEPLOYMENT_TYPE" == "upstream" ]; then

    info "Prepare project"
    kubectl create namespace tekton-pipelines

    info "Setup policy"
    oc adm policy add-scc-to-user anyuid -z tekton-pipelines-controller
    oc adm policy add-scc-to-user anyuid -z tekton-pipelines-webhook

    info "Deploy yaml"
    if [ "$DEPLOYMENT_VERSION" == "stable" ]; then
        curl https://storage.googleapis.com/tekton-releases/pipeline/latest/release.notags.yaml \
            | yq 'del(.spec.template.spec.containers[].securityContext.runAsUser, .spec.template.spec.containers[].securityContext.runAsGroup)' \
            | kubectl apply --validate=warn -f - || true
    elif [ "$DEPLOYMENT_VERSION" == "nightly" ]; then
        curl https://storage.googleapis.com/tekton-releases-nightly/pipeline/latest/release.notags.yaml \
            | yq 'del(.spec.template.spec.containers[].securityContext.runAsUser, .spec.template.spec.containers[].securityContext.runAsGroup)' \
            | kubectl apply --validate=warn -f - || true
    else
        fatal "Unknown deployment version '$DEPLOYMENT_VERSION'"
    fi

    info "Configure resources for tekton-pipelines-controller"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-controller
    kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller -c tekton-pipelines-controller --limits=cpu=1,memory=2Gi --requests=cpu=1,memory=2Gi

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller

    info "Deployment finished"
    kubectl -n tekton-pipelines get pods

else

    fatal "Unknown deployment type '$DEPLOYMENT_TYPE'"

fi
