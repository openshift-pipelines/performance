#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function cleanup() {
    sed \
        -e 's/PipelineRun "[a-zA-Z0-9-]\+" failed/PipelineRun "..." failed/' \
        -e 's/The step "[a-zA-Z0-9-]\+" in TaskRun/The step "..." in TaskRun/' \
        -e 's/TaskRun "[a-zA-Z0-9-]\+" failed/TaskRun "..." failed/' \
        -e 's/TaskRun "[a-zA-Z0-9-]\+" was cancelled/TaskRun "..." was cancelled/' \
        -e 's/task run pod "[a-zA-Z0-9-]\+"/task run pod "..."/' \
        -e 's/containers with \(unready\|incomplete\) status: \[[a-zA-Z0-9 -]\+\]/containers with unready status: [...]/' \
        -e 's/Maybe missing or invalid Task [a-zA-Z0-9-]\+\+\/[a-zA-Z0-9-]\+/Maybe missing or invalid Task ...\/.../' \
        -e 's/"[a-zA-Z0-9-]\+" exited with code/"..." exited with code/' \
        -e 's/for logs run: kubectl -n benchmark logs [a-zA-Z0-9-]\+ -c [a-zA-Z0-9-]\+/for logs run: kubectl -n benchmark logs ... -c .../'
}


directory="$1"
if [ ! -d "$directory" ]; then
    echo "ERROR: Directory '$directory' does not exist"
    exit 1
fi

for file in "pipelineruns.json" "taskruns.json" "pods.json"; do
    path="$directory/$file"
    if [ ! -f "$path" ]; then
        echo "ERROR: File '$path' does not exist"
        continue
    fi

    echo -e "\n#### Processing $path:"

    #cat "$path" | jq --raw-output '.items[] | (.metadata.name as $name | .status.conditions | map(($name, .type, .status, .reason, .message)) | @csv)'
    types=$( cat $path | jq --raw-output '.items[] | .status.conditions[] | .type' | sort -u )

    for t in $types; do
        echo -e "\n##### Condition $t:"
        echo "\`\`\`"
        cat $path | jq --raw-output '.items[] | .status.conditions[] | select(.type | contains("'"$t"'")) | .message' | cleanup | sort | uniq -c | sed -e 's/\s\+/ /g' -e 's/^ //' -e 's/ $//' | sort -nr
        echo "\`\`\`"
    done
done
