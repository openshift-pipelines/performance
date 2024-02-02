source scenario/common/lib.sh

chains_setup_oci_oci

internal_registry_setup

image_name='image-registry.openshift-image-registry.svc.cluster.local:5000/benchmark/test:$(context.pipelineRun.name)'
dockerconfig_secret_name="$( oc -n benchmark get serviceaccount perf-test-registry-sa -o json | jq --raw-output '.imagePullSecrets[0].name' )"
pipeline_and_pipelinerun_setup "$image_name" "$dockerconfig_secret_name"

measure_signed_start

chains_stop
