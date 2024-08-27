source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_NAMESPACE="${TEST_NAMESPACE:-1}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-1}"
# Possible Types: git/task
TEST_RESOLVER_TYPE="${TEST_RESOLVER_TYPE:-git}"

if [ "$TEST_RESOLVER_TYPE" != "git" ] && [ "$TEST_RESOLVER_TYPE" != "task" ]; then
    fatal "Invalid TEST_RESOLVER_TYPE parameter (value: $TEST_RESOLVER_TYPE) set. Possible values: git/task"
fi

chains_setup_tekton_tekton_

chains_stop

if [ "$TEST_RESOLVER_TYPE" == "task" ]; then
    # Sets up Git Resolver's tasks `benchmark` namespaces
    create_pipeline_from_j2_template task.yaml.j2  "namespace_count=${TEST_NAMESPACE}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}"
    oc_apply_manifest task.yaml
fi



# Create GitResolver's pipeline definition from template based on resolver type
# This will be applied by load-test.sh,  post to the setup script execution
create_pipeline_from_j2_template pipeline.yaml.j2 "namespace_count=${TEST_NAMESPACE}, resolver_type=${TEST_RESOLVER_TYPE}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}"

