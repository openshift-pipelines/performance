#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

DEPLOYMENT_PIPELINES_CONTROLLER_TYPE="${DEPLOYMENT_PIPELINES_CONTROLLER_TYPE:-deployments}" # Types available: deployments / statefulSets 
DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="${DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES:-1/2Gi/1/2Gi}"   # In form of "requests.cpu/requests.memory/limits.cpu/limits.memory", use "///" to skip this
pipelines_controller_resources_requests_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 1 )"
pipelines_controller_resources_requests_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 2 )"
pipelines_controller_resources_limits_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 3 )"
pipelines_controller_resources_limits_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 4 )"

# Tekton Results parameters
INSTALL_RESULTS="${INSTALL_RESULTS:-false}"
STORE_LOGS_IN_S3="${STORE_LOGS_IN_S3:-false}"
DEPLOYMENT_TYPE_RESULTS="${DEPLOYMENT_TYPE_RESULTS:-downstream}"
DEPLOYMENT_RESULTS_UPSTREAM_VERSION="${DEPLOYMENT_RESULTS_UPSTREAM_VERSION:-latest}"

# Loki stack configuration: https://access.redhat.com/solutions/7006859
LOKI_STACK_SIZE="1x.demo" # Other options: 1x.demo, 1x.small, 1x.extra-small

# Locust setup config
RUN_LOCUST="${RUN_LOCUST:-false}"
LOCUST_NAMESPACE=locust-operator
LOCUST_OPERATOR_REPO=locust-k8s-operator
LOCUST_OPERATOR=locust-operator
LOCUST_HELM_CONFIG=./config/locust-k8s-operator.values.yaml

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

pipelines_kube_api_qps="${DEPLOYMENT_PIPELINES_KUBE_API_QPS:-}"
pipelines_kube_api_burst="${DEPLOYMENT_PIPELINES_KUBE_API_BURST:-}"
pipelines_threads_per_controller="${DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER:-}"

chains_kube_api_qps="${DEPLOYMENT_CHAINS_KUBE_API_QPS:-}"
chains_kube_api_burst="${DEPLOYMENT_CHAINS_KUBE_API_BURST:-}"
chains_threads_per_controller="${DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER:-}"

info "Deploy pipelines $DEPLOYMENT_TYPE/$DEPLOYMENT_VERSION"
if [ "$DEPLOYMENT_TYPE" == "downstream" ]; then

    DEPLOYMENT_CSV_VERSION="$DEPLOYMENT_VERSION.0"
    [ "$DEPLOYMENT_VERSION" == "1.11" ] && DEPLOYMENT_CSV_VERSION="1.11.1"
    [ "$DEPLOYMENT_VERSION" == "1.14" ] && DEPLOYMENT_CSV_VERSION="1.14.3"

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
        
        if [ "$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE" == "statefulSets" ]; then
          kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"performance":{"statefulset-ordinals":true,"buckets":1,"replicas":1}}}}'
        fi

        kubectl patch TektonConfig/config --type merge --patch '{"spec":{"result":{"disabled":true},"pipeline":{"options":{"'$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE'":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":'"$resources_json"'}]}}}}}}}}}'

        info "Configure Pipelines HA: ${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-no}"
        if [ -n "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS" ]; then
            # Wait for TektonConfig to exist
            wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true

            # Patch TektonConfig with replicas and buckets
            if [ "$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE" == "deployments" ]; then
                kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"performance":{"disable-ha":false,"buckets":'"$pipelines_controller_ha_buckets"'}}}}'

            elif [ "$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE" == "statefulSets" ]; then
                # bucket and replicas should match while using statefulSets
                # https://github.com/tektoncd/operator/commit/efd8c40d9eea49c34db056fc879227727ac0da78#diff-de4b17aab821a4c35f6fe299fb87c2532cb7858590e6b514c4b6ab79b26148abR124
                kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"performance":{"replicas":'"$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"',"buckets":'"$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"'}}}}'
            fi

            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"'$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE'":{"tekton-pipelines-controller":{"spec":{"replicas":'"$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"'}}}}}}}'

            # Wait for pods to come up
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready pod -l app=tekton-pipelines-controller
            
            if [ "$DEPLOYMENT_PIPELINES_CONTROLLER_TYPE" == "deployments" ]; then
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
        fi

        info "Configure Chains HA: ${DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS:-no}"
        if [ -n "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS" ]; then
            # Wait for TektonConfig to exist
            wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
            # Patch TektonConfig with replicas and buckets for ha
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"chain":{"options":{"deployments":{"tekton-chains-controller":{"spec":{"replicas":'"$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS"'}}},"configMaps":{"tekton-chains-config-leader-election":{"data":{"buckets":"'$chains_controller_ha_buckets'"}}}}}}}'
            # Wait for pods to come up
            sleep 60
            wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-chains-controller "$DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS"
            kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-chains-controller
            # Delete leases
            kubectl delete -n openshift-pipelines $(kubectl get leases -n openshift-pipelines -o name | grep tektoncd.chains)
            # Wait for pods to come up
            sleep 60
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

    info "Enable Pipeline performance options"
    pipelines_perf_options=""
    if [ -n "$pipelines_kube_api_qps" ]; then
        pipelines_perf_options+="\"kube-api-qps\":$pipelines_kube_api_qps,"
    fi
    if [ -n "$pipelines_kube_api_burst" ]; then
        pipelines_perf_options+="\"kube-api-burst\":$pipelines_kube_api_burst,"
    fi
    if [ -n "$pipelines_threads_per_controller" ]; then
        pipelines_perf_options+="\"threads-per-controller\":$pipelines_threads_per_controller,"
    fi

    if [[ -n "$pipelines_perf_options" ]]; then
        pipelines_perf_options="${pipelines_perf_options%,}"
        kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"performance":{'$pipelines_perf_options'}}}}'
    fi

    info "Enable Chains performance options"
    chains_perf_options=""
    if [ -n "$chains_kube_api_qps" ]; then
        chains_perf_options+="\"--kube-api-qps=$chains_kube_api_qps\","
    fi
    if [ -n "$chains_kube_api_burst" ]; then
        chains_perf_options+="\"--kube-api-burst=$chains_kube_api_burst\","
    fi
    if [ -n "$chains_threads_per_controller" ]; then
        chains_perf_options+="\"--threads-per-controller=$chains_threads_per_controller\","
    fi
    if [[ -n "$chains_perf_options" ]]; then
        chains_perf_options="${chains_perf_options%,}"
        kubectl patch TektonConfig/config --type merge --patch '{"spec":{"chain":{"options":{"deployments":{"tekton-chains-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-chains-controller","args":['$chains_perf_options']}]}}}}}}}}}'
    fi

    info "Disable Chains"
    kubectl patch TektonConfig/config --type merge --patch '{"spec":{"chain":{"disabled":true}}}'

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
    # TODO: (upstream setup) Support statefulSets based deployment of pipelines-controller using DEPLOYMENT_PIPELINES_CONTROLLER_TYPE
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

# Install Tekton results from downstream/upstream
if [ "$INSTALL_RESULTS" == "true" ]; then
    # Store temp artifacts for the setup
    TEMP_DIR_PATH=$(mktemp -d)

    if [ "$DEPLOYMENT_TYPE_RESULTS" == "downstream" ]; then
        # Read More on Installation: https://docs.openshift.com/pipelines/1.15/records/using-tekton-results-for-openshift-pipelines-observability.html
        TEKTON_RESULTS_NS="openshift-pipelines"
        export TEKTON_RESULTS_FQDN="tekton-results-api-service.$TEKTON_RESULTS_NS.svc.cluster.local"

        info "Configure resources for tekton-results ($DEPLOYMENT_TYPE_RESULTS)"

        # Setup creds for DB
        kubectl get ns $TEKTON_RESULTS_NS || kubectl create ns $TEKTON_RESULTS_NS

        kubectl get secret tekton-results-postgres -n $TEKTON_RESULTS_NS || kubectl create secret generic tekton-results-postgres -n "$TEKTON_RESULTS_NS" \
            --from-literal=POSTGRES_USER=result --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)

        if [ "$DEPLOYMENT_VERSION" == "1.15" ]; then

          # Setup SSL certs for Results API
          openssl req -x509 \
                -newkey rsa:4096 \
                -keyout "$TEMP_DIR_PATH/key.pem" \
                -out "$TEMP_DIR_PATH/cert.pem" \
                -days 365 \
                -nodes \
                -subj "/CN=$TEKTON_RESULTS_FQDN" \
                -config <(envsubst < config/openssl.cnf)

          kubectl get secret tekton-results-tls -n $TEKTON_RESULTS_NS || kubectl create secret tls -n $TEKTON_RESULTS_NS tekton-results-tls \
                --cert="$TEMP_DIR_PATH/cert.pem" \
                --key="$TEMP_DIR_PATH/key.pem"

          if [ "$STORE_LOGS_IN_S3" == "true" ]; then
            CONDITIONAL_FIELDS="
    logs_type: S3
    secret_name: s3-credentials"
            echo "STORE_LOGS_IN_S3 is set to true. Creating S3 credentials secret."

            oc create secret generic s3-credentials -n $TEKTON_RESULTS_NS \
  --from-literal=S3_BUCKET_NAME="${AWS_BUCKET_NAME}" \
  --from-literal=S3_ENDPOINT="${AWS_ENDPOINT}" \
  --from-literal=S3_HOSTNAME_IMMUTABLE="false" \
  --from-literal=S3_REGION="${AWS_REGION}" \
  --from-literal=S3_ACCESS_KEY_ID="${AWS_ACCESS_ID}" \
  --from-literal=S3_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
  --from-literal=S3_MULTI_PART_SIZE="5242880"

          else
            CONDITIONAL_FIELDS="
    logging_pvc_name: tekton-logs
    logs_type: File"
          # Apply the PersistentVolumeClaim using kubectl
            cat <<EOF | kubectl apply -n $TEKTON_RESULTS_NS -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
    name: tekton-logs
spec:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 4Gi
EOF
          fi

        cat <<EOF | oc apply -n $TEKTON_RESULTS_NS -f -
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonResult
metadata:
    name: result
spec:
    targetNamespace: $TEKTON_RESULTS_NS
    logs_api: true
    log_level: debug
    db_port: 5432
    db_host: tekton-results-postgres-service.$TEKTON_RESULTS_NS.svc.cluster.local
$CONDITIONAL_FIELDS
    logs_path: /logs
    logs_buffer_size: 2097152
    auth_disable: true
    tls_hostname_override: tekton-results-api-service.$TEKTON_RESULTS_NS.svc.cluster.local
    db_enable_auto_migration: true
    server_port: 8080
    prometheus_port: 9090
EOF

      else
        # Create Namespace for installing openshift-logging
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-logging: "true"
    openshift.io/cluster-monitoring: "true"
EOF

        oc get secret logging-loki-s3 -n openshift-logging || oc -n openshift-logging create secret generic logging-loki-s3 \
  --from-literal=bucketnames="${AWS_BUCKET_NAME}" \
  --from-literal=endpoint="${AWS_ENDPOINT}" \
  --from-literal=region="${AWS_REGION}" \
  --from-literal=access_key_id="${AWS_ACCESS_ID}" \
  --from-literal=access_key_secret="${AWS_SECRET_KEY}"

        oc get ns openshift-operators-redhat || oc create namespace openshift-operators-redhat

        # Create OperatorGroup for installing loki-operator
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-operators-redhat
EOF


        # Create Subscription for installing Loki Operator
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.0
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace

EOF

        echo "Checking for InstallPlan..."
        INSTALL_PLAN=$(oc get installplan -n openshift-operators -o json | jq -r '.items[] | select(.spec.approved == false) | .metadata.name')

        if [[ -n "$INSTALL_PLAN" ]]; then
          echo "Approving InstallPlan: $INSTALL_PLAN"
          oc patch installplan $INSTALL_PLAN -n openshift-operators --type='merge' -p '{"spec":{"approved":true}}'
        fi

        wait_for_entity_by_selector 300 openshift-operators-redhat pod name=loki-operator-controller-manager

        # Create OperatorGroup for installing openshift-logging
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
  - openshift-logging
EOF

        # Create Subscription for installing openshift-logging
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.0
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

        wait_for_entity_by_selector 300 openshift-logging pod name=cluster-logging-operator

        default_storage_class=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

        # Installing Loki
        cat <<EOF | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  managementState: Managed
  replicationFactor: 1
  size: $LOKI_STACK_SIZE
  storage:
    schemas:
    - effectiveDate: "2023-10-15"
      version: v13
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: $default_storage_class
  tenants:
    mode: openshift-logging
EOF

        # Installing OpenShift Logging
        # Create Service Account and give it permission required.
        oc get sa collector -n openshift-logging || oc create sa collector -n openshift-logging
        oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:collector
        oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector
        oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector
        oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector

        cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
  - application:
      selector:
        matchLabels:
          app.kubernetes.io/managed-by: tekton-pipelines
    name: only-tekton
    type: application
  managementState: Managed
  outputs:
  - lokiStack:
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
      authentication:
        token:
          from: serviceAccount
      target:
        name: logging-loki
        namespace: openshift-logging
    name: default-lokistack
    tls:
      ca:
        configMapName: openshift-service-ca.crt
        key: service-ca.crt
    type: lokiStack
  pipelines:
  - inputRefs:
    - only-tekton
    name: default-logstore
    outputRefs:
    - default-lokistack
  serviceAccount:
    name: collector
EOF

      if version_gte "$DEPLOYMENT_VERSION" "1.18"; then
        # Starting 1.18, Results is installed as part of Operator
        # https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.18/html/release_notes/op-release-notes#tekton-results-new-features-1-18_op-release-notes
        info "Enabling Tekton-Result in Tekton Operator"
        kubectl patch TektonConfig/config --type merge --patch '{"spec":{"result":{"disabled":false,"auth_disable":true,"targetNamespace":"openshift-pipelines","loki_stack_name":"logging-loki","loki_stack_namespace":"openshift-logging"}}}'
      else
        info "Installing Tekton-Result Operator"
        cat <<EOF | oc apply -n $TEKTON_RESULTS_NS -f -
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonResult
metadata:
    name: result
spec:
  auth_disable: true
  targetNamespace: openshift-pipelines
  loki_stack_name: logging-loki
  loki_stack_namespace: openshift-logging
EOF
      fi

        fi

        # Wait for tekton-results resources to start
        wait_for_entity_by_selector 300 $TEKTON_RESULTS_NS pod app.kubernetes.io/name=tekton-results-api
        wait_for_entity_by_selector 300 $TEKTON_RESULTS_NS pod app.kubernetes.io/name=tekton-results-watcher

        # Setup route to access Results-API endpoint
        # TODO: Should test this with CI setup and also should evaluate how encryption works
        oc get route -n $TEKTON_RESULTS_NS tekton-results-api-service || oc create route -n $TEKTON_RESULTS_NS passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080

    elif [ "$DEPLOYMENT_TYPE_RESULTS" == "upstream" ]; then
        # Read More on Installation: https://github.com/tektoncd/results/blob/main/docs/install.md
        TEKTON_RESULTS_NS="tekton-pipelines"
        export TEKTON_RESULTS_FQDN="tekton-results-api-service.$TEKTON_RESULTS_NS.svc.cluster.local"

        info "Configure resources for tekton-results ($DEPLOYMENT_TYPE_RESULTS:$DEPLOYMENT_RESULTS_UPSTREAM_VERSION)"

        # Setup creds for DB
        kubectl get ns $TEKTON_RESULTS_NS || kubectl create ns $TEKTON_RESULTS_NS

        kubectl get secret tekton-results-postgres -n $TEKTON_RESULTS_NS || kubectl create secret generic tekton-results-postgres -n "$TEKTON_RESULTS_NS" \
            --from-literal=POSTGRES_USER=postgres --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)

        # Setup SSL certs for Results API
        openssl req -x509 \
            -newkey rsa:4096 \
            -keyout "$TEMP_DIR_PATH/key.pem" \
            -out "$TEMP_DIR_PATH/cert.pem" \
            -days 365 \
            -nodes \
            -subj "/CN=$TEKTON_RESULTS_FQDN" \
            -config <(envsubst < config/openssl.cnf)

        kubectl get secret tekton-results-tls -n $TEKTON_RESULTS_NS || kubectl create secret tls -n $TEKTON_RESULTS_NS tekton-results-tls \
            --cert="$TEMP_DIR_PATH/cert.pem" \
            --key="$TEMP_DIR_PATH/key.pem"

        # Install tekton results manifest
        if [ "$DEPLOYMENT_RESULTS_UPSTREAM_VERSION" == "latest" ]; then
            kubectl apply -f https://storage.googleapis.com/tekton-releases/results/latest/release.yaml
        else
            kubectl apply -f https://storage.googleapis.com/tekton-releases/results/previous/${DEPLOYMENT_RESULTS_UPSTREAM_VERSION}/release.yaml
        fi

        # Wait for tekton-results resources to start
        wait_for_entity_by_selector 300 $TEKTON_RESULTS_NS pod app.kubernetes.io/name=tekton-results-api
        wait_for_entity_by_selector 300 $TEKTON_RESULTS_NS pod app.kubernetes.io/name=tekton-results-watcher

        # Setup route to access Results-API endpoint
        # TODO: Should test this with CI setup and also should evaluate how encryption works
        oc get route -n $TEKTON_RESULTS_NS tekton-results-api-service || oc create route -n $TEKTON_RESULTS_NS passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080

    else
        fatal "Unknown deployment type '$DEPLOYMENT_TYPE_RESULTS'"
    fi

    info "Tekton-Results Deployment finished"
fi


if [ "$RUN_LOCUST" == "true" ]; then
    # Create namespace if not exists
    oc get ns "${LOCUST_NAMESPACE}" || oc create ns "${LOCUST_NAMESPACE}"

    # Check if the Helm repo already exists, and add it if it doesn't
    if ! helm repo list --namespace "${LOCUST_NAMESPACE}" | grep -q "${LOCUST_OPERATOR_REPO}"; then
        helm repo add "${LOCUST_OPERATOR_REPO}" https://abdelrhmanhamouda.github.io/locust-k8s-operator/ --namespace "${LOCUST_NAMESPACE}"
    else
        info "Helm repo \"${LOCUST_OPERATOR_REPO}\" already exists"
    fi

    # Check if the Helm release already exists, and install it if it doesn't
    if ! helm list --namespace "${LOCUST_NAMESPACE}" | grep -q "${LOCUST_OPERATOR}"; then
        helm install "${LOCUST_OPERATOR}" locust-k8s-operator/locust-k8s-operator --namespace "${LOCUST_NAMESPACE}" -f "$LOCUST_HELM_CONFIG"
    else
        info "Helm release \"${LOCUST_OPERATOR}\" already exists"
    fi

    # Wait for all pods in the namespace to be ready
    wait_for_entity_by_selector 180 "${LOCUST_NAMESPACE}" pod app.kubernetes.io/name=locust-k8s-operator

    info "Enabling user workload monitoring"
    config_dir=$(mktemp -d)
    if oc -n openshift-monitoring get cm cluster-monitoring-config; then
        oc -n openshift-monitoring extract configmap/cluster-monitoring-config --to=$config_dir --keys=config.yaml
        sed -i '/^enableUserWorkload:/d' $config_dir/config.yaml
        echo -e "\nenableUserWorkload: true" >> $config_dir/config.yaml
        oc -n openshift-monitoring set data configmap/cluster-monitoring-config --from-file=$config_dir/config.yaml
    else
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
  fi

    wait_for_entity_by_selector 600 "openshift-user-workload-monitoring" StatefulSet operator.prometheus.io/name=user-workload
    kubectl -n openshift-user-workload-monitoring rollout status --watch --timeout=600s StatefulSet/prometheus-user-workload
    kubectl -n openshift-user-workload-monitoring wait --for=condition=ready pod -l app.kubernetes.io/component=prometheus
    kubectl -n openshift-user-workload-monitoring get pod

    # Enable monitoring prometheus metrics
    info "Setup Service Monitoring"
    cat <<EOF | kubectl -n "${LOCUST_NAMESPACE}" apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    app: locust-operator
  annotations:
    networkoperator.openshift.io/ignore-errors: ""
  name: locust-operator-monitor
spec:
  endpoints:
    - interval: 10s
      port: prometheus-metrics
      honorLabels: true
  jobLabel: app
  namespaceSelector:
    matchNames:
      - locust-operator
  selector: {}
EOF

    info "Locust-Operator deployment finished"

else
    info "Skipping Locust setup"
fi


info "Create namespace 'utils' some scenarios use"
kubectl get ns utils || kubectl create ns utils
