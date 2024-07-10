source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-5}"
TEST_NAMESPACE="${TEST_NAMESPACE:-1}"

# Possible Types: cluster/task
TEST_CLUSTER_RESOLVER__TYPE="${TEST_CLUSTER_RESOLVER__TYPE:-cluster}"

if [ "$TEST_CLUSTER_RESOLVER__TYPE" != "cluster" ] && [ "$TEST_CLUSTER_RESOLVER__TYPE" != "task" ]; then
    fatal "Invalid TEST_CLUSTER_RESOLVER__TYPE parameter (value: $TEST_CLUSTER_RESOLVER__TYPE) set. Possible values: cluster/task"
fi

chains_setup_tekton_tekton_

chains_stop

# Sets up ClusterResolver's tasks in `utils` namespace or `benchmark` namespaces based on resolver type
create_pipeline_from_j2_template task.yaml.j2 "step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}, namespace_count=${TEST_NAMESPACE}, resolver_type=${TEST_CLUSTER_RESOLVER__TYPE}"
oc_apply_manifest task.yaml

# Create ClusterResolver's pipeline definition from template based on resolver type (refer to cluster scoped tasks in utils or per namespace tasks using default definition)
# This will be applied by load-test.sh,  post to the setup script execution
create_pipeline_from_j2_template pipeline.yaml.j2 "namespace_count=${TEST_NAMESPACE}, resolver_type=${TEST_CLUSTER_RESOLVER__TYPE}"
