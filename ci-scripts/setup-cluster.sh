#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $(dirname $0)/lib.sh

info "Deploy pipelines $DEPLOYMENT_TYPE/$DEPLOYMENT_VERSION"
if [ "$DEPLOYMENT_TYPE" == "downstream" ]
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
  startingCSV: openshift-pipelines-operator-rh.v${DEPLOYMENT_VERSION}.0
EOF
else
    fatal "Unknown deployment type '$DEPLOYMENT_TYPE'"
fi

function entity_by_selector_exists() {
    local ns="$1"
    local entity="$2"
    local l="$3"
    local count=$( kubectl -n "$ns" get "$entity" -l "$l" -o name 2>/dev/null | wc -l )
    debug "Number of $entity entities in $ns with label $l: $count"
    [ "$count" -gt 0 ]
}

function wait_for_entity_by_selector() {
    local timeout="$1"
    local ns="$2"
    local entity="$3"
    local l="$4"
    local before=$(date --utc +%s)
    while ! entity_by_selector_exists "$ns" "$entity" "$l"; do
        local now=$(date --utc +%s)
        if [[ $(( $now - $before )) -ge "$timeout" ]]; then
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( $now - $before ))/$timeout), waiting and trying again"
        sleep 3
    done
}

info "Wait for installplan to appear"
wait_for_entity_by_selector 300 openshift-operators InstallPlan operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators=
ip_name=$(kubectl -n openshift-operators get installplan -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators= -o name)
kubectl -n openshift-operators patch -p '{"spec":{"approved":true}}' --type merge "$ip_name"

info "Wait for deployment to finish"
wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller
kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller

info "Deployment finished"
kubectl -n openshift-pipelines get pods
