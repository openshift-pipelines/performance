#!/bin/bash

script_name=$(basename "$0")
short=t:c:r:o:dh
long=total:,concurrent:,run:,timeout:,debug,help

total=10000
concurrent=100
run="./run.yaml"
timeout=0
debug=false

if ! type jq >/dev/null; then
    echo "Please install jq"
    exit 1
fi

if ! type parallel >/dev/null; then
    echo "Please install 'parallel'"
    exit 1
fi

read -r -d '' usage <<EOF
Script needs following options
--concurrent     optional,
                 default value is 100

--total          optional,
                 default value is 10000

--run            optional default value is
                 https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml

--timeout        optional, how many seconds to to let the test run overall, use 0 for no limit,
                 default value is 0

--debug          optional default value is false

EOF

format=$(getopt -o "$short" --long "$long" --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -t | --total        )   total=$2;                                              shift 2                          ;;
        -c | --concurrent   )   concurrent=$2;                                         shift 2                          ;;
        -r | --run          )   run=$2;                                                shift 2                          ;;
        -o | --timeout      )   timeout=$2;                                            shift 2                          ;;
        -d | --debug        )   debug=true;                                            shift                            ;;
        -h | --help         )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done


started=$(date -Ins --utc)
started_ts=$(date +%s)
while true; do
    # When you run with `--total 1000`, final JSON have almost 7MB.
    # Maybe we can use this to get the size down:
    # https://kubernetes.io/docs/reference/using-api/api-concepts/#receiving-resources-as-tables
    data=$(kubectl get pr -o=json)
    all=$(echo "$data" | jq --raw-output '.items | length')
    pending=$(echo "$data" | jq --raw-output '.items | map(select(.status.conditions == null)) | length')
    running=$(echo "$data" | jq --raw-output '.items | map(select(.status.conditions[0].status == "Unknown")) | length')
    finished=$(echo "$data" | jq --raw-output '.items | map(select(.status.conditions[0].status != null and .status.conditions[0].status != "Unknown")) | length')

    ${debug} && echo "$(date -Ins --utc) out of ${total} runs ${all} already exists, ${pending} pending, ${finished} finished and ${running} running"

    [ "${finished}" -ge "${total}" ] && break

    remaining=$((${total} - ${all}))
    needed=$((${concurrent} - ${running} - ${pending}))
    [[ ${needed} -gt ${remaining} ]] && needed=${remaining}

    if [ "${timeout}" -gt 0 ]; then
        now_ts=$(date +%s)
        elapsed=$((${now_ts} - ${started_ts}))
        if [ "${elapsed}" -gt "${timeout}" ]; then
            echo "$(date -Ins --utc) after ${elapsed}s exceeded ${timeout}s timeout, bye"
            break
        fi
    fi

    if [ "${needed}" -gt 0 ]; then
        ${debug} && echo "$(date -Ins --utc) creating ${needed} runs to raise concurrency to ${concurrent}"
        parallel --will-cite -N0 kubectl create -f $run  2>&1 >/dev/null ::: $(seq 1 ${needed})
    fi
    echo "$(date -Ins --utc) done with this cycle"
    sleep 1
done
ended=$(date -Ins --utc)

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
            "total": $total,
            "concurrent": $concurrent,
            "run": "$run",
            "timeout": "$timeout"
        }
    }
}
EOF
echo "$data" >pipelineruns.json

echo "$(date -Ins --utc) adding stats to data file"
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
