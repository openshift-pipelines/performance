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

echo "$(date -Ins --utc) dumping basic results to data files"

# Update if file already exists 
if [ ! -f $output ]; then

cat <<EOF >$output
{
    "name": "OpenShift Pipelines scalingPipelines test",
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
