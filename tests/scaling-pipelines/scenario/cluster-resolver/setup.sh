source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-5}"

chains_setup_tekton_tekton_

chains_stop

# Setup ClusterResolver's tasks in utils namespace
create_pipeline_from_j2_template task.yaml.j2 "step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"
oc_apply_manifest task.yaml
