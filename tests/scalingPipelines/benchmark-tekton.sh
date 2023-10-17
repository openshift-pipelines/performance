#!/bin/bash

script_name=$(basename "$0")
short=t:c:r::dh
long=total:,concurrent:,run::,debug,help

total=10000
concurrent=100
run="./run.yaml"
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

--debug          optional default value is false

EOF

format=$(getopt -o "$short" --long "$long" --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -t | --total        )   total=$2;                                              shift 2                          ;;
        -c | --concurrent   )   concurrent=$2;                                         shift 2                          ;;
        -r | --run          )   run=$2;                                                shift 2                          ;;
        -d | --debug        )   debug=true;                                            shift                            ;;
        -h | --help         )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done


started=$(date -Ins --utc)
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
    "results": {
        "started": "$started",
        "ended": "$ended"
    },
    "parameters": {
        "test": {
            "total": $total,
            "concurrent": $concurrent,
            "run": "$run"
        }
    }
}
EOF
echo "$data" >benchmark-tekton-runs.json

echo "$(date -Ins --utc) adding stats to data files"
prs_avg=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.duration.min = '$prs_min' | .results.PipelineRuns.duration.avg = '$prs_avg' | .results.PipelineRuns.duration.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"
prs_avg=$(echo "$data" | jq --raw-output '[.items[] | ((.status.StartTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
prs_min=$(echo "$data" | jq --raw-output '[.items[] | ((.status.StartTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
prs_max=$(echo "$data" | jq --raw-output '[.items[] | ((.status.StartTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.pending.min = '$prs_min' | .results.PipelineRuns.pending.avg = '$prs_avg' | .results.PipelineRuns.pending.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"
prs_avg=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.StartTime | fromdate))] | add / length')
prs_min=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.StartTime | fromdate))] | min')
prs_max=$(echo "$data" | jq --raw-output '[.items[] | ((.status.completionTime | fromdate) - (.status.StartTime | fromdate))] | max')
cat $output | jq '.results.PipelineRuns.running.min = '$prs_min' | .results.PipelineRuns.running.avg = '$prs_avg' | .results.PipelineRuns.running.max = '$prs_max'' >"$$.json" && mv -f "$$.json" "$output"
prs_succeeded=$(echo "$data" | jq --raw-output '[.items[] | .status.conditions[] | select(.type == "Succeeded" and .status == "True")] | length')
prs_failed=$(echo "$data" | jq --raw-output '[.items[] | .status.conditions[] | select(.type == "Succeeded" and .status != "True")] | length')
cat $output | jq '.results.PipelineRuns.count.succeeded = '$prs_succeeded' | .results.PipelineRuns.count.failed = '$prs_failed'' >"$$.json" && mv -f "$$.json" "$output"
pr_creationTimestamp_first=$(echo "$data" | jq --raw-output '[.items[] | .metadata.creationTimestamp] | sort | first')
pr_creationTimestamp_last=$(echo "$data" | jq --raw-output '[.items[] | .metadata.creationTimestamp] | sort | last')
cat $output | jq '.results.PipelineRuns.creationTimestamp.first = '$pr_creationTimestamp_first' | .results.PipelineRuns.creationTimestamp.last = '$pr_creationTimestamp_last'' >"$$.json" && mv -f "$$.json" "$output"
pr_completionTime_first=$(echo "$data" | jq --raw-output '[.items[] | .status.completionTime] | sort | first')
pr_completionTime_last=$(echo "$data" | jq --raw-output '[.items[] | .status.completionTime] | sort | last')
cat $output | jq '.results.PipelineRuns.completionTime_first.first = '$pr_completionTime_first' | .results.PipelineRuns.completionTime.last = '$pr_completionTime_last'' >"$$.json" && mv -f "$$.json" "$output"

echo "$(date -Ins --utc) done with ${total} runs of ${run} which ran with ${concurrent} runs"
