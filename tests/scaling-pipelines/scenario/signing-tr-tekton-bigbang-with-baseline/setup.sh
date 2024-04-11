source scenario/common/lib.sh

WAIT_TIME="${WAIT_TIME:-1200}"

chains_setup_tekton_tekton_

chains_stop

(
    wait_for_prs_finished "${TEST_TOTAL}"
    
    # Wait before starting chains to establish baseline with PRs/TRs
    wait_for_timeout $WAIT_TIME "establish baseline performance with PRs/TRs"

    chains_start
) &

export TEST_PARAMS="--wait-for-state signed_true"
