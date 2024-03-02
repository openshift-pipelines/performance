source scenario/common/lib.sh

chains_setup_tekton_tekton_

chains_stop

# measure-signed will be waiting for "TEST_TOTAL"
# Also expect 3 * TEST_TOTAL, as each PR have 3 TRs
measure_signed_start "$(( TEST_TOTAL * 3 ))"

# Benchmark script will create "TEST_TOTAL / 2"
export TEST_TOTAL_ORIG="$TEST_TOTAL"
export TEST_TOTAL="$(( TEST_TOTAL / 2 ))"
