source scenario/common/lib.sh

LOCUST_RUN_PHASE=${LOCUST_RUN_PHASE:-after-load}
case "$LOCUST_RUN_PHASE" in
    after-load) ;;
    concurrent)
        export LOCUST_RUN_PHASE TEST_SCENARIO TEST_NAMESPACE
        python3 "scenario/$TEST_SCENARIO/concurrent-locust.py" --validate
        ;;
    *) fatal "LOCUST_RUN_PHASE must be after-load or concurrent" ;;
esac

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-10}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-15}"

# Execution mode: either TEST_TOTAL (count-based) or TOTAL_TIMEOUT (time-based)
# TOTAL_TIMEOUT takes precedence if both are set (handles load-test.sh's TEST_TOTAL=100 default)
# When only TEST_TOTAL is set: count-based mode (runs until N PRs complete, no time limit)
# When TOTAL_TIMEOUT is set: time-based mode (runs for duration, ignores TEST_TOTAL)

# Wait period before enabling chains/pruner
# Values should be less than TOTAL_TIMEOUT to enable the components for the test.
CHAINS_WAIT_TIME=${CHAINS_WAIT_TIME:-600} # [Default: 10 mins]
PRUNER_WAIT_TIME=${PRUNER_WAIT_TIME:-600} # [Default: 10 mins]
TEST_PRUNER_ENABLED=${TEST_PRUNER_ENABLED:-true}
case "$TEST_PRUNER_ENABLED" in
    true|false) ;;
    *) fatal "TEST_PRUNER_ENABLED must be true or false" ;;
esac

chains_setup_tekton_tekton_

chains_stop

pruner_stop

#  Timeout before enabling Chains
(
    wait_for_timeout $CHAINS_WAIT_TIME "enable Chains"
    chains_start
) &


#  Timeout before enabling Pruner
if [ "$TEST_PRUNER_ENABLED" == true ]; then
    (
        wait_for_timeout $PRUNER_WAIT_TIME "enable Pruner"
        pruner_start
    ) &
else
    info "Pruner remains disabled for this test"
fi

# Configure execution mode
if [ -n "${TOTAL_TIMEOUT:-}" ]; then
    # Time-based mode: run for TOTAL_TIMEOUT duration
    info "Running in time-based mode: TOTAL_TIMEOUT=${TOTAL_TIMEOUT}s (TEST_TOTAL=${TEST_TOTAL} ignored)"
    TEST_TOTAL=1000000
    export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"
else
    # Count-based mode: run for TEST_TOTAL PipelineRuns
    info "Running in count-based mode: TEST_TOTAL=${TEST_TOTAL} (no time limit)"
    export TEST_PARAMS=""
fi

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"

if [ "$LOCUST_RUN_PHASE" == concurrent ]; then
    # Finish background cleanup before the outer CI trap collects artifacts.
    CONCURRENT_LOCUST_PREVIOUS_EXIT_TRAP=$(trap -p EXIT)
    concurrent_locust_cleanup() {
        local status=$?
        if [ -n "${CONCURRENT_LOCUST_PID:-}" ]; then
            if jobs -pr | grep -qx "$CONCURRENT_LOCUST_PID"; then
                kill "$CONCURRENT_LOCUST_PID" 2>/dev/null || true
            fi
            wait "$CONCURRENT_LOCUST_PID" 2>/dev/null || true
        fi
        return "$status"
    }
    trap concurrent_locust_cleanup EXIT
    python3 "scenario/$TEST_SCENARIO/concurrent-locust.py" --parent-pid "$$" &
    CONCURRENT_LOCUST_PID=$!
    info "Concurrent Locust coordinator started (PID $CONCURRENT_LOCUST_PID)"
fi
