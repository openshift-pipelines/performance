source scenario/common/lib.sh

chains_setup_tekton_tekton_

chains_stop

(
    wait_for_prs_finished "${TEST_TOTAL}"
    chains_start
    set_started_now
) &

export TEST_PARAMS="--wait-for-state signed_true"
