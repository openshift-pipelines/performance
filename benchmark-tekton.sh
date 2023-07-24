#!/bin/bash

script_name=$(basename "$0")
short=t:c:j:p
long=total:,concurrent:,job:,jsonpath:,help

total=10000
concurrent=100
job="https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml"

read -r -d '' usage <<EOF
Script needs following options
--concurrent     optional,
                 default value is 100

--total          optional,
                 default value is 10000

--job            optional default value is
                 https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml

EOF

format=$(getopt -o $short --long $long --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -t | --total        )   total=$2;                                              shift 2                          ;;
        -b | --concurrent   )   concurrent=$2;                                         shift 2                          ;;
        -s | --job          )   job=$2;                                                shift 2                          ;;
        --help              )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done


while [ "$total" -ne 0 ]
do
    running=$(kubectl get pr -o=jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}' | wc -w)
    all=$(expr  $(kubectl get pr | wc --line) - 1)

    if [ "$all" -ge "$total" ]; then
        break
    fi

    if [ "$running" -lt "$concurrent" ]; then
        run=$(expr $concurrent - $running)
        for i in {1..$run}; do
            kubectl create -f $job &
        done
    fi
    wait
done

echo $total
echo $concurrent
echo $job
