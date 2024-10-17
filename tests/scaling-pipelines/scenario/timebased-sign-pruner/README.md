# "timebased-sign-pruner" scenario

This scenario is supposed to stress Pipelines, Chains controller and Pruner by creating PR/TR at constant rate. The first part of the scenario evaluates the performances of TektonResults capacity to fetch and stores logs into persistent layer. The second part of the scenario, we run two locust API tests named *fetch-log* and *fetch-records* that stress tests the Tekton Results API.

The following environment variables are available for controlling timeouts:
- **TOTAL_TIMEOUT**: Total time for test execution (Default: 2 hours)
- **CHAINS_WAIT_TIME**: Wait period before enabling chains (Default: 10 mins)
- **PRUNER_WAIT_TIME**: Wait period before enabling pruner (Default: 10 mins)

The following environment variables are available for controlling the PR/TR payload size and log outputs:
- **TEST_BIGBANG_MULTI_STEP__TASK_COUNT**: Total number of tasks per Pipeline (Default: 5 tasks)
- **TEST_BIGBANG_MULTI_STEP__STEP_COUNT**: Total number of steps per Task (Default: 10 steps)
- **TEST_BIGBANG_MULTI_STEP__LINE_COUNT**: Total number of unique output log lines per step (Default: 15 lines)

The following environment variables are available to set Locust Test parameters:
- **LOCUST_USERS**: Total number of users to spawn (Default: 100)
- **LOCUST_SPAWN_RATE**: Number of users to spawn every second (Default: 10)
- **LOCUST_DURATION**: Total duration for locust testing (Default: 15m)
- **LOCUST_WORKERS**: Number of Locust worker pods (Default: 5)
- **LOCUST_EXTRA_CMD**: Additional Locust Command-line parameters.

This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable.
