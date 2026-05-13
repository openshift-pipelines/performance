# "timebased-sign-pruner" scenario

This scenario is supposed to stress Pipelines, Chains controller and Pruner by creating PR/TR at constant rate. The first part of the scenario evaluates the performances of TektonResults capacity to fetch and stores logs into persistent layer. The second part of the scenario, we run two locust API tests named *fetch-log* and *fetch-records* that stress tests the Tekton Results API.

## Execution Modes

This scenario supports two execution modes:

1. **Count-based mode**: Use `TEST_TOTAL` to run for a specific number of PipelineRuns (no time limit)
2. **Time-based mode**: Use `TOTAL_TIMEOUT` to run for a specific duration (ignores TEST_TOTAL)

**Note**: If both are set, `TOTAL_TIMEOUT` takes precedence (time-based mode). This handles the default `TEST_TOTAL=100` from `load-test.sh` gracefully.

### Examples

**Count-based execution:**
```bash
export TEST_TOTAL="1000"
# Scenario will create 1000 PipelineRuns
```

**Time-based execution:**
```bash
export TOTAL_TIMEOUT="7200"  # 2 hours
# Scenario will run for 2 hours
```

The following environment variables are available for controlling execution:
- **TEST_TOTAL**: Total number of PipelineRuns to execute (count-based mode, Default: 100 from load-test.sh)
- **TOTAL_TIMEOUT**: Total time for test execution in seconds (time-based mode, no default - must be explicitly set)
- **CHAINS_WAIT_TIME**: Wait period before enabling chains (Default: 600 = 10 mins)
- **PRUNER_WAIT_TIME**: Wait period before enabling pruner (Default: 600 = 10 mins)

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
