#!/bin/bash
source scenario/common/lib.sh

# Generate cluster_read_config.yaml to collect resources usages for each pipeline-controller pods
pipeline_controller_pods=$(oc -n openshift-pipelines get po -l app=tekton-pipelines-controller -o jsonpath="{..metadata.name}")
create_pipeline_from_j2_template cluster_read_config.yaml.j2 "pod_list=${pipeline_controller_pods}"
