source scenario/common/lib.sh

chains_start

set_started_now

# Now we will create second half PRs
# Unfortunately this overrides stats in JSON file
# Note each PR have 3 TRs
generate_more_start "$(( TEST_TOTAL_ORIG * 3 ))" "${TEST_CONCURRENT}" "${TEST_RUN}" "${TEST_TIMEOUT:-18000}"

generate_more_wait

measure_signed_wait

set_ended_now

measure_signed_stop
