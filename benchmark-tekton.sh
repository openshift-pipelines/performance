#!/bin/bash

script_name=$(basename "$0")
script_dir=$(dirname "$0")
short=t:c:n:r:d:h
long=total:,concurrent:,namespace:,run:,debug:,help

total=10000
concurrent=100
namespace="benchmark"
run="./run.yaml"
debug=false

read -r -d '' usage <<EOF
Script needs following options
--namespace     optional,
                default value is 'benchmark'
--concurrent    optional,
                default value is '100'

--total         optional,
                default value is '10000'

--run           optional,
                default value is
                https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml

--debug         optional default value is false

EOF

format=$(getopt -o $short --long $long --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -t | --total        )   total=$2;                                              shift 2                          ;;
        -c | --concurrent   )   concurrent=$2;                                         shift 2                          ;;
        -n | --namespace    )   namespace=$2;                                          shift 2                          ;;
        -r | --run          )   run=$2;                                                shift 2                          ;;
        -d | --debug        )   debug=$2;                                              shift 2                          ;;
        --help              )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done

for BIN in kubectl parallel; do
    if ! command -v $BIN >/dev/null; then
        echo "[ERROR] Install $BIN"
        exit 1
    fi
done

#Refresh OSP pods
echo -n "recycling OSP pods: "
for pod in $(kubectl get pods -n openshift-pipelines -o=jsonpath='{.items[*].metadata.name}'); do
    kubectl delete pod -n openshift-pipelines "${pod}" &
done >/dev/null
wait
while [ $(kubectl get pods -n openshift-pipelines -o=jsonpath='{.items[?(@.status.phase!="Running")].metadata.name}' | wc -w) != "0" ]; do
    echo -n "."
    sleep 5
done
echo "OK"

# Create or reset namespace
echo -n "preparing namespace: "
if kubectl get ns "${namespace}" >/dev/null 2>&1; then
    if [ $(kubectl get pr -n "${namespace}" -o name | wc -l) != "0" ]; then
        kubectl delete -n "${namespace}" $(kubectl get pr -n "${namespace}" -o name) >/dev/null
    fi
    while [ $(kubectl get pr -n "${namespace}" -o name | wc -l) != "0" ]; do
        echo -n "."
        sleep 5
    done
else
    kubectl create ns "${namespace}"
    kubectl -n "${namespace}" apply -f "${script_dir}/pipeline.yaml"
fi
echo "OK"

# Run load test
starttime=$(date +%s)
while true
do
    running=$(kubectl get pr -n "${namespace}" -o=jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}' | wc -w)

    all=$(kubectl get pr -n "${namespace}" -o name | wc -l)

    completed=$(kubectl get pr -n "${namespace}" -o=jsonpath='{.items[?(@.status.conditions[0].type=="Succeeded")].metadata.name}' | wc -w)

    curr=$(expr ${all} - ${completed} + ${running})

    runtime=$(expr $(date +%s) - ${starttime})

    if ${debug}; then
        echo "scheduled running ${running}"
        echo "current running runs ${curr}"
        echo "all runs ${all}"
        echo "processed run ${completed}"
    else
        delta=$(( all - concurrent))
        if [ $delta -lt 1 ]; then
                delta=1
        fi
        echo -en "\rRunning test: pipelineruns=${all}/${total} (running=${curr}/${concurrent}) ETA=$(( runtime * (total - all + concurrent) / delta ))s        "
    fi

    if [ "${all}" -ge "${total}" ]; then
        break
    fi

    if [ "${curr}" -lt "${concurrent}" ]; then
        req=$(expr ${concurrent} - ${curr})
        ${debug} && echo "running ${req} runs to get back to $concurrent level"
        parallel -N0 kubectl create -n "${namespace}" -f $run  2>&1 >/dev/null ::: $(seq 1 ${req})
        kubectl delete pod -n "${namespace}" --field-selector=status.phase==Succeeded 2>&1 > /dev/null &
    fi
    if ${debug}; then
        echo "done with this cycle"
    fi
done
echo
echo "done with ${total} runs of ${run} which ran with ${concurrent} runs: ${runtime}s"
