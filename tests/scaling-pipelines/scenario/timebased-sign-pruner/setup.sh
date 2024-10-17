source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-10}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-15}"

# Total time for test execution [Default: 2 hours]
TOTAL_TIMEOUT=${TOTAL_TIMEOUT:-7200} 

# Wait period before enabling chains/pruner
# Values should be less than TOTAL_TIMEOUT to enable the components for the test.
CHAINS_WAIT_TIME=${CHAINS_WAIT_TIME:-600} # [Default: 10 mins]
PRUNER_WAIT_TIME=${PRUNER_WAIT_TIME:-600} # [Default: 10 mins]

chains_setup_tekton_tekton_

chains_stop

pruner_stop

#  Timeout before enabling Chains 
(
    wait_for_timeout $CHAINS_WAIT_TIME "enable Chains"
    chains_start
) &


#  Timeout before enabling Pruner
(
    wait_for_timeout $PRUNER_WAIT_TIME "enable Pruner"
    pruner_start
) &

# Stop the execution after total timeout duration
export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"
