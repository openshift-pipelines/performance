#!/bin/bash

started="$1"
ended="$2"

echo "$(date -Ins --utc) dumping basic results to data files"
output="benchmark-tekton.json"
cat <<EOF >$output
{
    "name": "OpenShift Pipelines scalingPipelines test",
    "results": {
        "started": "$started",
        "ended": "$ended"
    },
    "parameters": {
        "test": {
            "total": $TEST_TOTAL,
            "concurrent": $TEST_CONCURRENT,
            "run": "$TEST_RUN"
        }
    }
}
EOF

echo "$(date -Ins --utc) adding stats to data file"
data=$(kubectl get pr -o=json)
echo "$data" >pipelineruns.json
data_successful=$(echo "$data" | jq --raw-output '.items |= [.[] | . as $a | .status.conditions | if . == null then [] else . end | .[] | select(.type == "Succeeded" and .status == "True") | $a]')

# PipelineRuns total duration (.status.completionTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.duration.min = '$prs_min' | .results.PipelineRuns.duration.avg = '$prs_avg' | .results.PipelineRuns.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns pending duration (.status.startTime - .metadata.creationTimestamp)
prs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.pending.min = '$prs_min' | .results.PipelineRuns.pending.avg = '$prs_avg' | .results.PipelineRuns.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns running duration (.status.completionTime - .status.startTime)
prs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | add / length')
prs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | min')
prs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.running.min = '$prs_min' | .results.PipelineRuns.running.avg = '$prs_avg' | .results.PipelineRuns.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns succeeded and failed count
prs_succeeded=$(echo "$data" | jq --raw-output '[.items[] | .status.conditions | if . == null then [] else . end | .[] | select(.type == "Succeeded" and .status == "True" and .reason == "Succeeded")] | length')
prs_failed=$(echo "$data" | jq --raw-output '[.items[] | .status.conditions | if . == null then [] else . end | .[] | select(.type == "Succeeded" and .status != "True" and .reason != "Running")] | length')
prs_remaining=$remaining
prs_pending=$pending
prs_running=$running
echo 'DEBUG: .results.PipelineRuns.count.succeeded = "'$prs_succeeded'" | .results.PipelineRuns.count.failed = "'$prs_failed'" | .results.PipelineRuns.count.remaining = "'$prs_remaining'" | .results.PipelineRuns.count.pending = "'$prs_pending'" | .results.PipelineRuns.count.running = "'$prs_running'"'
cat $output | jq '.results.PipelineRuns.count.succeeded = "'$prs_succeeded'" | .results.PipelineRuns.count.failed = "'$prs_failed'" | .results.PipelineRuns.count.remaining = "'$prs_remaining'" | .results.PipelineRuns.count.pending = "'$prs_pending'" | .results.PipelineRuns.count.running = "'$prs_running'"' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns .metadata.creationTimestamp first and last
pr_creationTimestamp_first=$(echo "$data" | jq --raw-output '[.items[] | .metadata.creationTimestamp] | sort | first')
pr_creationTimestamp_last=$(echo "$data" | jq --raw-output '[.items[] | .metadata.creationTimestamp] | sort | last')
cat $output | jq '.results.PipelineRuns.creationTimestamp.first = "'$pr_creationTimestamp_first'" | .results.PipelineRuns.creationTimestamp.last = "'$pr_creationTimestamp_last'"' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns .status.startTime first and last
pr_startTime_first=$(echo "$data" | jq --raw-output '[.items[] | .status.startTime] | sort | first')
pr_startTime_last=$(echo "$data" | jq --raw-output '[.items[] | .status.startTime] | sort | last')
cat $output | jq '.results.PipelineRuns.startTime.first = "'$pr_startTime_first'" | .results.PipelineRuns.startTime.last = "'$pr_startTime_last'"' >"$$.json" && mv -f "$$.json" "$output"

# PipelineRuns .status.completionTime first and last
pr_completionTime_first=$(echo "$data" | jq --raw-output '[.items[] | .status.completionTime] | sort | first')
pr_completionTime_last=$(echo "$data" | jq --raw-output '[.items[] | .status.completionTime] | sort | last')
cat $output | jq '.results.PipelineRuns.completionTime.first = "'$pr_completionTime_first'" | .results.PipelineRuns.completionTime.last = "'$pr_completionTime_last'"' >"$$.json" && mv -f "$$.json" "$output"

# TaskRuns
data=$(kubectl get tr -o=json)
echo "$data" >taskruns.json
data_successful=$(echo "$data" | jq --raw-output '.items |= [.[] | . as $a | .status.conditions | if . == null then [] else . end | .[] | select(.type == "Succeeded" and .status == "True") | $a]')

# TaskRuns total duration (.status.completionTime - .metadata.creationTimestamp)
trs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
trs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
trs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.TaskRuns.duration.min = '$trs_min' | .results.TaskRuns.duration.avg = '$trs_avg' | .results.TaskRuns.duration.max = '$trs_max'' >"$$.json" && mv -f "$$.json" "$output"

# TaskRuns pending duration (.status.startTime - .metadata.creationTimestamp)
trs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
trs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
trs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.startTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.TaskRuns.pending.min = '$trs_min' | .results.TaskRuns.pending.avg = '$trs_avg' | .results.TaskRuns.pending.max = '$trs_max'' >"$$.json" && mv -f "$$.json" "$output"

# TaskRuns running duration (.status.completionTime - .status.startTime)
trs_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | add / length')
trs_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | min')
trs_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.startTime | fromdate))] | max')
cat $output | jq '.results.TaskRuns.running.min = '$trs_min' | .results.TaskRuns.running.avg = '$trs_avg' | .results.TaskRuns.running.max = '$trs_max'' >"$$.json" && mv -f "$$.json" "$output"

echo "$(date -Ins --utc) done with ${total} runs of ${run} which ran with ${concurrent} runs"
