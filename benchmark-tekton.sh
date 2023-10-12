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

echo "$data" >benchmark-tekton-runs.json
cat <<EOF >benchmark-tekton.json
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

echo "$(date -Ins --utc) done with ${total} runs of ${run} which ran with ${concurrent} runs"
