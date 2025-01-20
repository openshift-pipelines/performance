#!/bin/bash
source scenario/common/lib.sh

DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS=${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-}

# Generate cluster_read_config.yaml to collect resources usages for each pipeline-controller pods.
if [ -n "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS" ] && [ "$DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS" != "1" ]; then
    pipeline_controller_pods=$(oc -n openshift-pipelines get po -l app=tekton-pipelines-controller -o jsonpath="{..metadata.name}")
    create_pipeline_from_j2_template cluster_read_config.yaml.j2 "pod_list=${pipeline_controller_pods}"
fi
