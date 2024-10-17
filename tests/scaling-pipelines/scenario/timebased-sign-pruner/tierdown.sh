source scenario/common/lib.sh

# Locust test configurations
LOCUST_HOST="https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080"
LOCUST_USERS=${LOCUST_USERS:-100}
LOCUST_SPAWN_RATE=${LOCUST_SPAWN_RATE:-10}
LOCUST_DURATION="${LOCUST_DURATION:-15m}"
LOCUST_WORKERS=${LOCUST_WORKERS:-5}
LOCUST_EXTRA_CMD="${LOCUST_EXTRA_CMD:-}"

# Run fetch-log loadtest scenario
run_locust "fetch-log" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

# Run fetch-records loadtest scenario
run_locust "fetch-records" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

# Update test end time
set_ended_now
