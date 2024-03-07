#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="${DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES:-1/2Gi/1/2Gi}"   # In form of "requests.cpu/requests.memory/limits.cpu/limits.memory", use "///" to skip this
pipelines_controller_resources_requests_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 1 )"
pipelines_controller_resources_requests_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 2 )"
pipelines_controller_resources_limits_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 3 )"
pipelines_controller_resources_limits_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 4 )"

DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS="${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-}"
if [ -n "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS" ]; then
    pipelines_controller_ha_buckets=$(( DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS * 2 ))
    pipelines_controller_ha_buckets=$(( pipelines_controller_ha_buckets > 10 ? 10 : pipelines_controller_ha_buckets ))
fi

DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS="${DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS:-}"
if [ -n "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS" ]; then
    chains_controller_ha_buckets=$(( DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS * 2 ))
    chains_controller_ha_buckets=$(( chains_controller_ha_buckets > 10 ? 10 : chains_controller_ha_buckets ))
fi

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
        info "Configure resources for tekton-pipelines-controller: $DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES"
        resources_json="{}"
        if [ -n "$pipelines_controller_resources_requests_cpu" ]; then
            resources_json=$(echo "$resources_json" | jq -c ".requests.cpu=\"$pipelines_controller_resources_requests_cpu\"")
        fi
        if [ -n "$pipelines_controller_resources_requests_memory" ]; then
            resources_json=$(echo "$resources_json" | jq -c ".requests.memory=\"$pipelines_controller_resources_requests_memory\"")
        fi
        if [ -n "$pipelines_controller_resources_limits_cpu" ]; then
            resources_json=$(echo "$resources_json" | jq -c ".limits.cpu=\"$pipelines_controller_resources_limits_cpu\"")
        fi
        if [ -n "$pipelines_controller_resources_limits_memory" ]; then
            resources_json=$(echo "$resources_json" | jq -c ".limits.memory=\"$pipelines_controller_resources_limits_memory\"")
        fi
        wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
        kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":'"$resources_json"'}]}}}}}}}}}'

        info "Configure Pipelines HA: ${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-no}"
        if [ -n "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS" ]; then
            # Wait for TektonConfig to exist
            wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
            # Patch TektonConfig with replicas and buckets
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"performance":{"disable-ha":false,"buckets":'"$pipelines_controller_ha_buckets"'}}}}'
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"replicas":'"$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"'}}}}}}}'
            # Wait for pods to come up
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready pod -l app=tekton-pipelines-controller
            # Delete leases
            kubectl delete -n openshift-pipelines $(kubectl get leases -n openshift-pipelines -o name | grep tekton-pipelines-controller)
            # Wait for pods to come up
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller
            # Check if all replicas were assigned some buckets
            for p in $( kubectl -n openshift-pipelines get pods -l app=tekton-pipelines-controller -o name ); do
                info "Checking if $p successfully acquired leases - not failing if empty as a workaround"
                kubectl -n openshift-pipelines logs --prefix "$p" | grep 'successfully acquired lease' || true
            done
        fi

        info "Configure Chains HA: ${DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS:-no}"
        if [ -n "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS" ]; then
            # Wait for TektonConfig to exist
            wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
            # Patch TektonConfig with replicas and buckets for ha
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"chain":{"options":{"deployments":{"tekton-chains-controller":{"spec":{"replicas":'"$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS"'}}},"configMaps":{"tekton-chains-config-leader-election":{"data":{"buckets":"'$chains_controller_ha_buckets'"}}}}}}}'
            # Wait for pods to come up
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-chains-controller "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-chains-controller
            # Delete leases
            kubectl delete -n openshift-pipelines $(kubectl get leases -n openshift-pipelines -o name | grep tektoncd.chains)
            # Wait for pods to come up
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-chains-controller "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-chains-controller
            # Check if all replicas were assigned some buckets
            for p in $( kubectl -n openshift-pipelines get pods -l app=tekton-chains-controller -o name ); do
                info "Checking if $p successfully acquired leases - not failing if empty as a workaround"
                kubectl -n openshift-pipelines logs --prefix "$p" | grep 'successfully acquired lease' || true
            done
        fi
    fi

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-webhook
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook

    info "Disable pruner"
    kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pruner":{"disabled":true}}}'

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

    info "Enabling user workload monitoring"
    rm -f config.yaml
    oc -n openshift-monitoring extract configmap/cluster-monitoring-config --to=. --keys=config.yaml
    sed -i '/^enableUserWorkload:/d' config.yaml
    echo -e "\nenableUserWorkload: true" >> config.yaml
    cat config.yaml
    oc -n openshift-monitoring set data configmap/cluster-monitoring-config --from-file=config.yaml
    wait_for_entity_by_selector 300 openshift-user-workload-monitoring StatefulSet operator.prometheus.io/name=user-workload
    kubectl -n openshift-user-workload-monitoring rollout status --watch --timeout=600s StatefulSet/prometheus-user-workload
    kubectl -n openshift-user-workload-monitoring wait --for=condition=ready pod -l app.kubernetes.io/component=prometheus
    kubectl -n openshift-user-workload-monitoring get pod

    info "Setup monitoring"
    cat <<EOF | kubectl -n tekton-pipelines apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    app: controller
  annotations:
    networkoperator.openshift.io/ignore-errors: ""
  name: openshift-pipelines-monitor
  namespace: tekton-pipelines
spec:
  endpoints:
    - interval: 10s
      port: http-metrics
      honorLabels: true
  jobLabel: app
  namespaceSelector:
    matchNames:
      - openshift-pipelines
  selector:
    matchLabels:
      app: tekton-pipelines-controller
EOF

    info "Configure resources for tekton-pipelines-controller: $DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-controller
    pipelines_controller_resources_requests_cpu="${pipelines_controller_resources_requests_cpu:-0}"
    pipelines_controller_resources_requests_memory="${pipelines_controller_resources_requests_memory:-0}"
    pipelines_controller_resources_limits_cpu="${pipelines_controller_resources_limits_cpu:-0}"
    pipelines_controller_resources_limits_memory="${pipelines_controller_resources_limits_memory:-0}"
    kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller \
        --requests "cpu=$pipelines_controller_resources_requests_cpu,memory=$pipelines_controller_resources_requests_memory" \
        --limits "cpu=$pipelines_controller_resources_limits_cpu,memory=$pipelines_controller_resources_limits_memory" \
        -c tekton-pipelines-controller

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller

    info "Deployment finished"
    kubectl -n tekton-pipelines get pods

else

    fatal "Unknown deployment type '$DEPLOYMENT_TYPE'"

fi

info "Create namespace 'utils' some scenarios use"
kubectl create ns utils
