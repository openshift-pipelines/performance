source scenario/common/lib.sh

chains_setup_oci_oci

standalone_registry_setup

image_name='registry.utils.svc.cluster.local:5000/benchmark/test:$(context.pipelineRun.name)'
dockerconfig_secret_name='test-dockerconfig'
pipeline_and_pipelinerun_setup "$image_name" "$dockerconfig_secret_name"

chains_stop
