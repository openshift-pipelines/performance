source scenario/common/lib.sh

# Locust test configurations
LOCUST_HOST="https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080"
LOCUST_USERS=${LOCUST_USERS:-100}
LOCUST_SPAWN_RATE=${LOCUST_SPAWN_RATE:-10}
LOCUST_DURATION="${LOCUST_DURATION:-15m}"
LOCUST_WORKERS=${LOCUST_WORKERS:-5}
LOCUST_EXTRA_CMD="${LOCUST_EXTRA_CMD:-}"
LOCUST_WAIT_TIME=${LOCUST_WAIT_TIME:-600} # [Default: 10 mins]

# Wait before starting locust test
# This is implemented to give enough time for openshift-logging to do log sync ups
wait_for_timeout $LOCUST_WAIT_TIME "start Locust test"

# Run fetch-log loadtest scenario
run_locust "fetch-log" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

# Run fetch-record loadtest scenario
run_locust "fetch-record" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

# Run fetch-all-records loadtest scenario
run_locust "fetch-all-records" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

# Update test end time
set_ended_now
