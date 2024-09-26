# "timebased-sign-pruner" scenario

This scenario is supposed to stress Pipelines, Chains controller and Pruner by creating PR/TR at constant rate.

The following environment variables are available for controlling timeouts:
- **TOTAL_TIMEOUT**: Total time for test execution (Default: 2 hours)
- **CHAINS_WAIT_TIME**: Wait period before enabling chains (Default: 10 mins)
- **PRUNER_WAIT_TIME**: Wait period before enabling pruner (Default: 10 mins)

The following environment variables are available for controlling the PR/TR payload size and log outputs:
- **TEST_BIGBANG_MULTI_STEP__TASK_COUNT**: Total number of tasks per Pipeline (Default: 5 tasks)
- **TEST_BIGBANG_MULTI_STEP__STEP_COUNT**: Total number of steps per Task (Default: 10 steps)
- **TEST_BIGBANG_MULTI_STEP__LINE_COUNT**: Total number of unique output log lines per step (Default: 15 lines)


This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable.
