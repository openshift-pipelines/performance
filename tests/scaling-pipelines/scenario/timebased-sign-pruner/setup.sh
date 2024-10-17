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

# Locust test configurations
LOCUST_HOST="https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080"
LOCUST_USERS=${LOCUST_USERS:-100}
LOCUST_SPAWN_RATE=${LOCUST_SPAWN_RATE:-10}
LOCUST_DURATION="$((TOTAL_TIMEOUT * 1 / 8))s" # Run the test for 1/8th duration of the overall test 
LOCUST_WORKERS=${LOCUST_WORKERS:-5}
LOCUST_EXTRA_CMD="${LOCUST_EXTRA_CMD:-}"

chains_setup_tekton_tekton_

chains_stop

pruner_stop

# We will use varying concurrency to set the concurreny to zero before starting locust test
echo $TEST_CONCURRENT > scenario/$TEST_SCENARIO/concurrency.txt

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

# Timeout before setting concurrency to zero
(
    wait_for_timeout $((TOTAL_TIMEOUT * 3 / 4)) "reducing concurrency to 0"
    echo 0 > scenario/$TEST_SCENARIO/concurrency.txt
) &

# Timeout before starting Locust test
(
    wait_for_timeout $((TOTAL_TIMEOUT * 3 / 4)) "starting Locust Test"

    # Run fetch-log loadtest scenario
    run_locust "fetch-log" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

    # Run fetch-records loadtest scenario
    run_locust "fetch-records" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"
) &

# Stop the execution after total timeout duration
export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"
