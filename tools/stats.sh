#!/bin/bash

# TODOS:
# 1. Fix error handling when 0 number of failed runs
# 2. Fix issue with TaskRuns stats not working (possibly missing data)

started="$1"
ended="$2"
type="$3"

input="benchmark-output.json"
output="benchmark-tekton.json"

if [[ ! ${type} == "PipelineRuns" && ! ${type} == "TaskRuns" ]] ; then
    echo 'ERROR: Given type is invlaid. Possible Values: PipelineRun, TaskRuns'
    exit 1
fi

TEST_NAMESPACE="${TEST_NAMESPACE:-1}"

echo "$(date -Ins --utc) dumping basic results to data files"
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

# Gather PipelineRun and TaskRun information from benchmark-output.json
if [[ ${type} == "PipelineRuns" ]]; then
    data=$(jq .pipelineruns "$input")
else
    data=$(jq .taskruns "$input")
fi

###############################################################################################
# [Overall] total duration (.status.completionTime - .metadata.creationTimestamp)
data_overall=$(echo $data | jq '. | to_entries | .[].value')
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].duration.min = '$prs_min' | .results.[$type].duration.avg = '$prs_avg' | .results.[$type].duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Overall] pending duration (.status.startTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].pending.min = '$prs_min' | .results.[$type].pending.avg = '$prs_avg' | .results.[$type].pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Overall] running duration (.status.completionTime - .status.startTime)
prs_avg=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | add / length')
prs_min=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | min')
prs_max=$(echo "$data_overall" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].running.min = '$prs_min' | .results.[$type].running.avg = '$prs_avg' | .results.[$type].running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

###############################################################################################
# [Success] total duration (.status.completionTime - .metadata.creationTimestamp)
data_successful=$(echo $data | jq '. | to_entries | .[].value | select (.outcome == "succeeded")')
prs_avg=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Success.duration.min = '$prs_min' | .results.[$type].Success.duration.avg = '$prs_avg' | .results.[$type].Success.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Success] pending duration (.status.startTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_successful" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Success.pending.min = '$prs_min' | .results.[$type].Success.pending.avg = '$prs_avg' | .results.[$type].Success.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Success] running duration (.status.completionTime - .status.startTime)
prs_avg=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Success.running.min = '$prs_min' | .results.[$type].Success.running.avg = '$prs_avg' | .results.[$type].Success.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

###############################################################################################
# [Failed] total duration (.status.completionTime - .metadata.creationTimestamp)
data_failed=$(echo $data | jq '. | to_entries | .[].value | select (.outcome == "failed")')
prs_avg=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Failed.duration.min = '$prs_min' | .results.[$type].Failed.duration.avg = '$prs_avg' | .results.[$type].Failed.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Failed] pending duration (.status.startTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_failed" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_failed" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_failed" | jq -s  '[.[] | ((.startTime | fromdate) - (.creationTimestamp | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Failed.pending.min = '$prs_min' | .results.[$type].Failed.pending.avg = '$prs_avg' | .results.[$type].Failed.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Failed] running duration (.status.completionTime - .status.startTime)
prs_avg=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | add / length')
prs_min=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | min')
prs_max=$(echo "$data_failed" | jq -s  '[.[] | ((.completionTime | fromdate) - (.startTime | fromdate))] | max')
cat $output | jq --arg type "$type" '.results.[$type].Failed.running.min = '$prs_min' | .results.[$type].Failed.running.avg = '$prs_avg' | .results.[$type].Failed.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"


# succeeded and failed count
prs_succeeded=$(echo "$data_successful" | jq -s ' length')
prs_failed=$(echo "$data_failed" | jq -s ' length')
prs_remaining=$remaining
prs_pending=$pending
prs_running=$running
echo 'DEBUG: .results.${type}.count.succeeded = "'$prs_succeeded'" | .results.${type}.count.failed = "'$prs_failed'" | .results.${type}.count.remaining = "'$prs_remaining'" | .results.${type}.count.pending = "'$prs_pending'" | .results.${type}.count.running = "'$prs_running'"'
cat $output | jq --arg type "$type" '.results.[$type].count.succeeded = "'$prs_succeeded'" | .results.[$type].count.failed = "'$prs_failed'" | .results.[$type].count.remaining = "'$prs_remaining'" | .results.[$type].count.pending = "'$prs_pending'" | .results.[$type].count.running = "'$prs_running'"' >"$$.json" && mv -f "$$.json" "$output"

# .metadata.creationTimestamp first and last
pr_creationTimestamp_first=$(echo $data | jq  '[.[] | .creationTimestamp] | sort | first')
pr_creationTimestamp_last=$(echo $data | jq  '[.[] | .creationTimestamp] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].creationTimestamp.first = '$pr_creationTimestamp_first' | .results.[$type].creationTimestamp.last = '$pr_creationTimestamp_last'' >"$$.json" && mv -f "$$.json" "$output"

# .status.startTime first and last
pr_startTime_first=$(echo $data | jq  '[.[] | .startTime] | sort | first')
pr_startTime_last=$(echo $data | jq  '[.[] | .startTime] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].startTime.first = '$pr_startTime_first' | .results.[$type].startTime.last = '$pr_startTime_last'' >"$$.json" && mv -f "$$.json" "$output"

# ${type} .status.completionTime first and last
pr_completionTime_first=$(echo $data | jq  '[.[] | .completionTime] | sort | first')
pr_completionTime_last=$(echo $data | jq  '[.[] | .completionTime] | sort | last')
cat $output | jq --arg type "$type" '.results.[$type].completionTime.first = '$pr_completionTime_first' | .results.[$type].completionTime.last = '$pr_completionTime_last'' >"$$.json" && mv -f "$$.json" "$output"
