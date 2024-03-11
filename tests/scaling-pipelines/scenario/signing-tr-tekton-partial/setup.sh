source scenario/common/lib.sh

chains_setup_tekton_tekton_

chains_stop

# Benchmark script will create "TEST_TOTAL / 2"
export TEST_TOTAL_ORIG="$TEST_TOTAL"
export TEST_TOTAL="$(( TEST_TOTAL / 2 ))"
