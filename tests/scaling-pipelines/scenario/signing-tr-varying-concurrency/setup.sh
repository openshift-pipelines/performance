source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-5}"

TOTAL_TIMEOUT="12600"


chains_setup_tekton_tekton_

chains_stop

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"

pruner_start

(

    wait_for_timeout 30m "establish baseline performance with 5PR"
    chains_start
    wait_for_timeout 30m "establish baseline performance with 5PR with chains enabled"

    echo 10 > scenario/$TEST_SCENARIO/concurrency.txt
    wait_for_timeout 60m "establish baseline performance with 10PR"

    echo 5 > scenario/$TEST_SCENARIO/concurrency.txt
    wait_for_timeout 30m "establish baseline performance with 5PR"

    echo 0 > scenario/$TEST_SCENARIO/concurrency.txt
    wait_for_timeout 30m "establish baseline performance with 0PR"
)&


export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"
