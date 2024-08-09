source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_NAMESPACE="${TEST_NAMESPACE:-1}"

# Possible Types: git/task
TEST_RESOLVER_TYPE="${TEST_RESOLVER_TYPE:-git}"

if [ "$TEST_RESOLVER_TYPE" != "git" ] && [ "$TEST_RESOLVER_TYPE" != "task" ]; then
    fatal "Invalid TEST_CLUSTER_RESOLVER__TYPE parameter (value: $TEST_RESOLVER_TYPE) set. Possible values: git/task"
fi

chains_setup_tekton_tekton_

chains_stop

# Create GitResolver's pipeline definition from template based on resolver type (refer to cluster scoped tasks in utils or per namespace tasks using default definition)
# This will be applied by load-test.sh,  post to the setup script execution
create_pipeline_from_j2_template pipeline.yaml.j2 "namespace_count=${TEST_NAMESPACE}, resolver_type=${TEST_RESOLVER_TYPE}"

