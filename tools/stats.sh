#!/bin/bash

started="$1"
ended="$2"
type="$3"

input="benchmark-output.json"
output="benchmark-tekton.json"

if [[ ! ${type} == "PipelineRuns" && ! ${type} == "TaskRuns" ]]
then
    echo 'ERROR: Given type is invlaid. Possible Values: PipelineRuns, TaskRuns'
    exit 1
fi

TEST_NAMESPACE="${TEST_NAMESPACE:-1}"

horreum_test_name() {
    if [[ "${TEST_SCENARIO:-}" == *signing* ]]; then
        echo "OpenShift Pipelines Chains signing test"
        return
    fi

    local ha_replicas="${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-0}"
    local ha_enabled=false
    if [[ -n "${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-}" && "${ha_replicas}" != "0" ]]; then
        ha_enabled=true
    fi

    local qbt_enabled=false
    if [[ -n "${DEPLOYMENT_PIPELINES_KUBE_API_QPS:-}" || -n "${DEPLOYMENT_PIPELINES_KUBE_API_BURST:-}" || -n "${DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER:-}" ]]; then
        qbt_enabled=true
    fi

    local controller_type="${DEPLOYMENT_PIPELINES_CONTROLLER_TYPE:-deployments}"

    if [[ "$ha_enabled" == false && "$qbt_enabled" == false ]]; then
        echo "Scaling Pipelines test-standard"
    elif [[ "$ha_enabled" == false && "$qbt_enabled" == true ]]; then
        echo "Scaling Pipelines test-qbt_deployement"
    elif [[ "$ha_enabled" == true && "$qbt_enabled" == false && "$controller_type" == "statefulSets" ]]; then
        echo "Scaling Pipelines test-ha_statefulsets"
    elif [[ "$ha_enabled" == true && "$qbt_enabled" == false ]]; then
        echo "Scaling Pipelines test-ha_deployement"
    elif [[ "$ha_enabled" == true && "$qbt_enabled" == true ]]; then
        echo "Scaling Pipelines test-ha_qbt"
    fi
}

echo "$(date -Ins --utc) dumping basic results to data files"

# Update if file already exists 
if [ ! -f $output ]; then

cat <<EOF >$output
{
    "name": "$(horreum_test_name)",
    "results": {
        "started": "$started",
        "ended": "$ended"
    },
    "parameters": {
        "test": {
            "total": "$TEST_TOTAL",
            "concurrent": "$TEST_CONCURRENT",
            "run": "$TEST_RUN"
        }
    }
}
EOF

fi

# Gather PipelineRun and TaskRun information from benchmark-output.json
if [[ ${type} == "PipelineRuns" ]]; then
    data=$(jq .pipelineruns "$input")
else
    data=$(jq .taskruns "$input")
fi


# Get information on latest objects in the cluster after test execution (deleted PR/TR will not be considered)
# Loop through each namespace and get the JSON outputs
object_jsons=()
for namespace_idx in $(seq 1 ${TEST_NAMESPACE});
do
    namespace_tag=$([ "$TEST_NAMESPACE" -eq 1 ] && echo "" || echo "$namespace_idx")
    namespace="benchmark${namespace_tag}"

    object_jsons+=("$(kubectl get $type -o json -n "${namespace}")")
done

# Generate Object Listing for PR/TR
items=$(printf '%s\n' "${object_jsons[@]}" | jq -s '{items: map(.items) | add}')
object_lists=$(echo "$items" | jq '. += {"apiVersion":"v1", "kind": "List", "metadata": {}}')

if [[ ${type} == "PipelineRuns" ]]; then
    echo "$object_lists" > pipelineruns.json
else
    echo "$object_lists" > taskruns.json
fi


# Filter run details based on outcome  
data_overall=$(echo $data | jq '. | to_entries | .[].value')
data_successful=$(echo $data | jq '. | to_entries | .[].value | select (.outcome == "succeeded")')
data_failed=$(echo $data | jq '. | to_entries | .[].value | select (.outcome == "failed")')

# succeeded and failed count
prs_succeeded=$(echo "$data_successful" | jq -s ' length')
prs_failed=$(echo "$data_failed" | jq -s ' length')
prs_remaining=$remaining
prs_pending=$pending
prs_running=$running
echo 'DEBUG: .results.$type.count.succeeded = "'$prs_succeeded'" | .results.$type.count.failed = "'$prs_failed'" | .results.$type.count.remaining = "'$prs_remaining'" | .results.$type.count.pending = "'$prs_pending'" | .results.$type.count.running = "'$prs_running'"'
cat $output | jq --arg type "$type" '.results.[$type].count.succeeded = "'$prs_succeeded'" | .results.[$type].count.failed = "'$prs_failed'" | .results.[$type].count.remaining = "'$prs_remaining'" | .results.[$type].count.pending = "'$prs_pending'" | .results.[$type].count.running = "'$prs_running'"' >"$$.json" && mv -f "$$.json" "$output"

###############################################################################################
# [Overall] total duration (.status.completionTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].duration.min = '$prs_min' | .results.[$type].duration.avg = '$prs_avg' | .results.[$type].duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Overall] pending duration (.status.startTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].pending.min = '$prs_min' | .results.[$type].pending.avg = '$prs_avg' | .results.[$type].pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Overall] running duration (.status.completionTime - .status.startTime)
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].running.min = '$prs_min' | .results.[$type].running.avg = '$prs_avg' | .results.[$type].running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

###############################################################################################
if [ "$prs_succeeded" != "0" ]; then

    # [Success] total duration (.status.completionTime - .metadata.creationTimestamp)
    prs_avg=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | add / length')
    prs_min=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | min')
    prs_max=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Success.duration.min = '$prs_min' | .results.[$type].Success.duration.avg = '$prs_avg' | .results.[$type].Success.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

    # [Success] pending duration (.status.startTime - .metadata.creationTimestamp)
    prs_avg=$(echo "$data_successful" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
    prs_min=$(echo "$data_successful" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
    prs_max=$(echo "$data_successful" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Success.pending.min = '$prs_min' | .results.[$type].Success.pending.avg = '$prs_avg' | .results.[$type].Success.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

    # [Success] running duration (.status.completionTime - .status.startTime)
    prs_avg=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | add / length')
    prs_min=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | min')
    prs_max=$(echo "$data_successful" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Success.running.min = '$prs_min' | .results.[$type].Success.running.avg = '$prs_avg' | .results.[$type].Success.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"
else 
    echo "DEBUG: No successful runs found. Skipping successful run duration calculation..."
fi 

###############################################################################################
if [ "$prs_failed" != "0" ]; then

    # [Failed] total duration (.status.completionTime - .metadata.creationTimestamp)
    prs_avg=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | add / length')
    prs_min=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | min')
    prs_max=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.creationTimestamp | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Failed.duration.min = '$prs_min' | .results.[$type].Failed.duration.avg = '$prs_avg' | .results.[$type].Failed.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

    # [Failed] pending duration (.status.startTime - .metadata.creationTimestamp)
    prs_avg=$(echo "$data_failed" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
    prs_min=$(echo "$data_failed" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
    prs_max=$(echo "$data_failed" | jq -s  '[.[] | select(has("startTime")) | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Failed.pending.min = '$prs_min' | .results.[$type].Failed.pending.avg = '$prs_avg' | .results.[$type].Failed.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

    # [Failed] running duration (.status.completionTime - .status.startTime)
    prs_avg=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | add / length')
    prs_min=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | min')
    prs_max=$(echo "$data_failed" | jq -s  '[.[] | select(has("finished_at")) | (( (.completionTime // (.finished_at | .[0:19] + "Z")) | fromdate) - (.startTime | fromdate))] | max')
    cat $output | jq --arg type "$type" '.results.[$type].Failed.running.min = '$prs_min' | .results.[$type].Failed.running.avg = '$prs_avg' | .results.[$type].Failed.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

else 
    echo "DEBUG: No failed runs found. Skipping failed run duration calculation..."
fi 

# .metadata.creationTimestamp first and last
pr_creationTimestamp_first=$(echo $data | jq  '[.[] | select(has("creationTimestamp")) | .creationTimestamp] | sort | first')
pr_creationTimestamp_last=$(echo $data | jq  '[.[] | select(has("creationTimestamp")) | .creationTimestamp] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].creationTimestamp.first = '$pr_creationTimestamp_first' | .results.[$type].creationTimestamp.last = '$pr_creationTimestamp_last'' >"$$.json" && mv -f "$$.json" "$output"

# .status.startTime first and last
pr_startTime_first=$(echo $data | jq  '[.[] | select(has("startTime")) | .startTime] | sort | first')
pr_startTime_last=$(echo $data | jq  '[.[] | select(has("startTime")) | .startTime] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].startTime.first = '$pr_startTime_first' | .results.[$type].startTime.last = '$pr_startTime_last'' >"$$.json" && mv -f "$$.json" "$output"

# ${type} .status.completionTime first and last
pr_completionTime_first=$(echo $data | jq  '[.[] | select(has("finished_at")) | (.completionTime // (.finished_at | .[0:19] + "Z") ) ] | sort | first')
pr_completionTime_last=$(echo $data | jq  '[.[] | select(has("finished_at")) | (.completionTime // (.finished_at | .[0:19] + "Z") ) ] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].completionTime.first = '$pr_completionTime_first' | .results.[$type].completionTime.last = '$pr_completionTime_last'' >"$$.json" && mv -f "$$.json" "$output"

###############################################################################################
# Signing metrics
signing_json=$(echo "$data_overall" | jq -s --arg type "$type" '
    [.[] | select(.signed == "true" and .signed_at != null)] as $signed |
    ($signed | length) as $count |
    if $count > 0 then
        ([.[] | select(.signed == "false")] | length) as $false_count |
        ([.[] | select(.signed == "unknown" or (.signed == null))] | length) as $unsigned_count |
        ($signed | map(.signed_at | .[0:19] + "Z") | sort) as $times |
        ($times | first) as $first |
        ($times | last) as $last |
        ($first | fromdate) as $first_epoch |
        ($last | fromdate) as $last_epoch |
        ($last_epoch - $first_epoch) as $duration |
        {
            count: {
                signed_true: $count,
                signed_false: $false_count,
                unsigned: $unsigned_count
            },
            signed_at: {
                first: $first,
                last: $last
            },
            duration: $duration,
            throughput: (if $duration > 0 then ($count / $duration | . * 10000 | round / 10000) else null end)
        }
    else
        null
    end
')

if [[ "$signing_json" != "null" ]]; then
    signing_count=$(echo "$signing_json" | jq '.count.signed_true')
    echo "DEBUG: Computing signing metrics for ${signing_count} signed ${type}..."
    jq --argjson metrics "$signing_json" --arg type "$type" \
        '.results.[$type].signing = $metrics' "$output" > "$$.json" && mv -f "$$.json" "$output"

    signing_duration=$(echo "$signing_json" | jq '.duration')
    signing_throughput=$(echo "$signing_json" | jq '.throughput')
    echo "DEBUG: Signing count=${signing_count}, duration=${signing_duration}s, throughput=${signing_throughput}/s"
else
    echo "DEBUG: No signed ${type} found. Skipping signing metrics..."
fi

###############################################################################################
# Results ingestion metrics
ingestion_json=$(echo "$data_overall" | jq -s --arg type "$type" '
    [.[] | select(.result_at != null and .completionTime != null)] as $ingested |
    ($ingested | length) as $count |
    if $count > 0 then
        ($ingested | map(
            ((.result_at | .[0:19] + "Z" | fromdate) - (.completionTime | fromdate))
        )) as $latencies |
        ($ingested | map(.result_at | .[0:19] + "Z") | sort) as $times |
        ($times | first) as $first |
        ($times | last) as $last |
        ($first | fromdate) as $first_epoch |
        ($last | fromdate) as $last_epoch |
        ($last_epoch - $first_epoch) as $duration |
        ([.[] | select(.result_stored == "true")] | length) as $stored_count |
        ([.[] | select(.result_stored == "false")] | length) as $not_stored_count |
        {
            count: {
                ingested: $count,
                stored_true: $stored_count,
                stored_false: $not_stored_count
            },
            latency: {
                min: ($latencies | min),
                avg: (($latencies | add / length) * 10000 | round / 10000),
                max: ($latencies | max)
            },
            result_at: {
                first: $first,
                last: $last
            },
            duration: $duration,
            throughput: (if $duration > 0 then ($count / $duration | . * 10000 | round / 10000) else null end)
        }
    else
        null
    end
')

if [[ "$ingestion_json" != "null" ]]; then
    ingestion_count=$(echo "$ingestion_json" | jq '.count.ingested')
    echo "DEBUG: Computing ingestion metrics for ${ingestion_count} ingested ${type}..."
    jq --argjson metrics "$ingestion_json" --arg type "$type" \
        '.results.[$type].results_ingestion = $metrics' "$output" > "$$.json" && mv -f "$$.json" "$output"

    ingestion_latency_avg=$(echo "$ingestion_json" | jq '.latency.avg')
    ingestion_throughput=$(echo "$ingestion_json" | jq '.throughput')
    echo "DEBUG: Ingestion count=${ingestion_count}, avg_latency=${ingestion_latency_avg}s, throughput=${ingestion_throughput}/s"
else
    echo "DEBUG: No ingested ${type} found. Skipping ingestion metrics..."
fi
