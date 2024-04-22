source scenario/common/lib.sh

# timeout between events (pruner start/chains start) [Default: 20 mins]
EVENT_IDLE_TIMEOUT=$(expr ${EVENT_TIMEOUT:-20} \* 60) 

# Total time for running the test = Wait Time + Pruner Start + Chains Start + Event Timeout (buffer)
TOTAL_TIMEOUT=$(expr ${WAIT_TIME:-0} \* 60 + 3 \* ${EVENT_IDLE_TIMEOUT})

chains_setup_tekton_tekton_

chains_stop

pruner_stop

(
    wait_for_timeout $EVENT_IDLE_TIMEOUT "establish baseline performance with PRs/TRs"
    pruner_start
    wait_for_timeout $EVENT_IDLE_TIMEOUT "establish baseline performance with PRs/TRs"
    chains_start
) &

# Stop if all the PRs are signed or until timeout (32 mins)
export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"
