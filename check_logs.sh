#!/bin/bash
namespace="openshift-pipelines"
search=""

short=p:s:dh
long=podname:,search:,debug:,help

read -r -d '' usage <<EOF
Script needs following options
--podname       mandatory
--search        optional,
                Default value is '' and will return a line count of the whole log.
--debug         optional,
                default value is false
--help          optional,
                Print this message and exit
EOF

format=$(getopt -o $short --long $long --name "$script_name" -- "$@")

eval set -- "${format}"
while :; do
    case "${1}" in
        -p | --podname      )   podname=$2;                                            shift 2                          ;;
        -s | --search       )   search=$2;                                             shift 2                          ;;
        -d | --debug        )   set -x;                                                shift                            ;;
        --help              )   echo "${usage}" 1>&2;                                  exit                             ;;
        --                  )   shift;                                                 break                            ;;
        *                   )   echo "Error parsing, incorrect options ${format}";     exit 1                           ;;
    esac
done

mapfile -t POD_LIST < <(kubectl get pods -n "${namespace}" -o yaml | yq ".items.[].metadata.name" | grep "tekton-${podname}")
echo "Pod count: ${#POD_LIST[@]}"
for POD in "${POD_LIST[@]}"; do
    echo -n "$POD: "
    LINE_COUNT=$(kubectl logs -n "${namespace}" "$POD" | grep -c "$search")
    echo "$LINE_COUNT"
done
