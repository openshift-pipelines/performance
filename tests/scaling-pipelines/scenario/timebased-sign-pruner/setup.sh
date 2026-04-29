source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-10}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-15}"

# Execution mode: either TEST_TOTAL (count-based) or TOTAL_TIMEOUT (time-based)
# If both are provided, error out
if [ -n "${TEST_TOTAL:-}" ] && [ -n "${TOTAL_TIMEOUT:-}" ]; then
    echo "ERROR: Both TEST_TOTAL and TOTAL_TIMEOUT are set. Please use only one:"
    echo "  - TEST_TOTAL: Run for a specific count of PipelineRuns"
    echo "  - TOTAL_TIMEOUT: Run for a specific duration in seconds"
    exit 1
fi

# Default to TOTAL_TIMEOUT if neither is provided
if [ -z "${TEST_TOTAL:-}" ] && [ -z "${TOTAL_TIMEOUT:-}" ]; then
    TOTAL_TIMEOUT=7200  # Default: 2 hours
fi

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

# Configure execution mode
if [ -n "${TEST_TOTAL:-}" ]; then
    # Count-based mode: run for TEST_TOTAL PipelineRuns
    echo "Running in count-based mode: TEST_TOTAL=${TEST_TOTAL}"
    export TEST_PARAMS=""
else
    # Time-based mode: run for TOTAL_TIMEOUT duration
    echo "Running in time-based mode: TOTAL_TIMEOUT=${TOTAL_TIMEOUT}"
    export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"
fi

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"
