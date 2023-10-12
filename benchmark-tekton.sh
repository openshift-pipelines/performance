#!/bin/bash

script_name=$(basename "$0")
short=t:c:r::dh
long=total:,concurrent:,run::,debug,help

total=10000
concurrent=100
run="./run.yaml"
debug=false

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


while true; do
    running=$(kubectl get pr -o=jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}' | wc -w)

    all=$(kubectl get pr -o=name | wc -l)

    scheduled=$(kubectl get pr -o=jsonpath='{.items[?(@.status.conditions[0].type=="Succeeded")].metadata.name}' | wc -w)

    curr=$((${all} - ${scheduled} + ${running}))

    if [ "${all}" -ge "${total}" ]; then
        break
    fi

    if ${debug}; then
        echo "scheduled running ${running}"
        echo "current running runs ${curr}"
        echo "all runs ${all}"
        echo "processed run ${scheduled}"
    fi

    if [ "${curr}" -lt "${concurrent}" ]; then
        req=$((${concurrent} - ${curr}))
        ${debug} && echo "running ${req} runs to get back to $concurrent level"
        parallel --will-cite -N0 kubectl create -f $run  2>&1 >/dev/null ::: $(seq 1 ${req})
        kubectl delete pod --field-selector=status.phase==Succeeded 2>&1 > /dev/null &
    fi
    echo "done with this cycle"
done

echo "done with ${total} runs of ${run} which ran with ${concurrent} runs"
