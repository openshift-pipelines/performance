#!/bin/bash

script_name=$(basename "$0")
short=t:c:j:p
long=total:,concurrent:,job:,jsonpath:,help

total=10000
concurrent=100
run="./run.yaml"

read -r -d '' usage <<EOF
Script needs following options
--concurrent     optional,
                 default value is 100

--total          optional,
                 default value is 10000

--run            optional default value is
                 https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml

EOF

format=$(getopt -o $short --long $long --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -t | --total        )   total=$2;                                              shift 2                          ;;
        -b | --concurrent   )   concurrent=$2;                                         shift 2                          ;;
        -s | --run          )   run=$2;                                                shift 2                          ;;
        --help              )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done


while [ "$total" -ne 0 ]
do
    running=$(kubectl get pr -o=jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}' | wc -w)
    all=$(expr $(kubectl get pr | wc -l) - 1)
    scheduled=$(kubectl get pr -o=jsonpath='{.items[?(@.status.conditions[0].type=="Succeeded")].metadata.name}' | wc -w)
    running=$(expr $all - $scheduled + $running)

    if [ "$all" -ge "$total" ]; then
        break
    fi

    echo "running $running"
    echo "all $all"
    echo "scheduled $scheduled"

    if [ "$running" -lt "$concurrent" ]; then
        req=$(expr $concurrent - $running)
        echo "running ${req} runs to get back to $concurrent level"
        parallel -N0 kubectl create -f $run >/dev/null 2>&1 ::: $(seq 1 ${req})
        kubectl delete pod --field-selector=status.phase==Succeeded
    fi
done

echo "done with $total runs of $run which ran with $concurrent runs"
