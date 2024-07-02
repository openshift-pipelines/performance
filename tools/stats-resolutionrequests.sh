#!/bin/bash

output="benchmark-tekton.json"

# Loop through each namespace and get the JSON outputs for ResolutionRequests
object_jsons=()
for namespace_idx in $(seq 1 ${TEST_NAMESPACE});
do
    namespace_tag=$([ "$TEST_NAMESPACE" -eq 1 ] && echo "" || echo "$namespace_idx")
    namespace="benchmark${namespace_tag}"

    object_jsons+=("$(kubectl get resolutionrequest -o json -n "${namespace}")")
done

# Generate Object List for ResolutionRequests
items=$(printf '%s\n' "${object_jsons[@]}" | jq -s '{items: map(.items) | add}')
object_lists=$(echo "$items" | jq '. += {"apiVersion":"v1", "kind": "List", "metadata": {}}')

# Filter run details based on outcome 
data_overall=$(echo "$object_jsons" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | $a ]')
data_successful=$(echo "$object_jsons" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | select(.status.conditions[0].type == "Succeeded" and .status.conditions[0].status == "True") | $a ]')
data_failed=$(echo "$object_jsons" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | select(.status.conditions[0].type != "Succeeded" and .status.conditions[0].status != "True") | $a ]')

# In case the test doesn't contain ResolutionRequest, then terminate.
req_overall=$(echo "$data_overall" | jq --raw-output '[.items[]] | length')
if [ "$req_overall" == "0" ]; then
    echo "DEBUG: No ResolutionRequests found."
    exit 0
fi

# [Overall] ResolutionRequest duration (.status.conditions[0].lastTransitionTime - .metadata.creationTimestamp)
req_avg=$(echo "$data_overall" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
req_min=$(echo "$data_overall" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
req_max=$(echo "$data_overall" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.ResolutionRequests.Overall.duration.min = '$req_min' | .results.ResolutionRequests.Overall.duration.avg = '$req_avg' | .results.ResolutionRequests.Overall.duration.max = '$req_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Success] ResolutionRequest duration (.status.conditions[0].lastTransitionTime - .metadata.creationTimestamp)
req_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
req_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
req_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
cat $output | jq '.results.ResolutionRequests.Success.duration.min = '$req_min' | .results.ResolutionRequests.Success.duration.avg = '$req_avg' | .results.ResolutionRequests.Success.duration.max = '$req_max'' >"$$.json" && mv -f "$$.json" "$output"

# [Failed] ResolutionRequest duration (.status.conditions[0].lastTransitionTime - .metadata.creationTimestamp)
req_failed=$(echo "$data_failed" | jq --raw-output '[.items[]] | length')
if [ "$req_failed" != "0" ]; then
    req_avg=$(echo "$data_failed" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
    req_min=$(echo "$data_failed" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
    req_max=$(echo "$data_failed" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
    cat $output | jq '.results.ResolutionRequests.Failed.duration.min = '$req_min' | .results.ResolutionRequests.Failed.duration.avg = '$req_avg' | .results.ResolutionRequests.Failed.duration.max = '$req_max'' >"$$.json" && mv -f "$$.json" "$output"
else 
    echo "DEBUG: No failed runs found. Skipping failed resolution run calculation..."
fi

# Save result list
echo "$object_lists" > resolutionrequests.json
