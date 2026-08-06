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
data_overall=$(echo "$object_lists" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | $a ]')
data_successful=$(echo "$object_lists" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | select(.status.conditions[0].type == "Succeeded" and .status.conditions[0].status == "True") | $a ]')
data_failed=$(echo "$object_lists" | jq --raw-output '.items |= [.[] | . as $a | if . == null then [] else . end | select(.status.conditions[0].status == "False") | $a ]')

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
req_success=$(echo "$data_successful" | jq --raw-output '[.items[]] | length')
if [ "$req_success" != "0" ]; then
    req_avg=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | add / length')
    req_min=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | min')
    req_max=$(echo "$data_successful" | jq --raw-output '[.items[] | ((.status.conditions[0].lastTransitionTime | fromdate) - (.metadata.creationTimestamp | fromdate))] | max')
    cat $output | jq '.results.ResolutionRequests.Success.duration.min = '$req_min' | .results.ResolutionRequests.Success.duration.avg = '$req_avg' | .results.ResolutionRequests.Success.duration.max = '$req_max'' >"$$.json" && mv -f "$$.json" "$output"
else 
    echo "DEBUG: No success runs found. Skipping success resolution run calculation..."
fi

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
echo "DEBUG: ResolutionRequest Total ($req_overall) | Success ($req_success) | Failed ($req_failed)"
echo "$object_lists" > resolutionrequests.json

# Collect resolver controller log and compute sub-second reconcile duration stats
# The log has a "duration" field with sub-millisecond precision, scoped to this run's RR keys
resolver_log="tekton-pipelines-remote-resolvers.log"
kubectl -n openshift-pipelines logs --tail=-1 --all-containers=true -l app=tekton-pipelines-resolvers >"$resolver_log" 2>/dev/null || true

if [ -s "$resolver_log" ]; then
    python3 -c "
import json, sys
from datetime import datetime, timezone

log_file = '$resolver_log'
output_file = '$output'
rr_file = 'resolutionrequests.json'

with open(rr_file) as f:
    rr_data = json.load(f)

items = rr_data.get('items', [])
if not items:
    print('DEBUG: No ResolutionRequests to match against resolver log.')
    sys.exit(0)

def parse_k8s_timestamp(ts):
    \"\"\"Parse Kubernetes timestamp (1-second granularity) to datetime.\"\"\"
    for fmt in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S.%fZ'):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None

def parse_log_timestamp(ts):
    \"\"\"Parse resolver log timestamp (sub-second precision) to datetime.\"\"\"
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None

# Build {key: creationTimestamp} — only count log entries at or after the RR was created
key_creation_times = {}
for item in items:
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    key = f'{ns}/{name}'
    ct = parse_k8s_timestamp(item['metadata']['creationTimestamp'])
    if ct is not None:
        # If same key appears multiple times (unlikely within one run), use the latest
        if key not in key_creation_times or ct > key_creation_times[key]:
            key_creation_times[key] = ct

print(f'DEBUG: Filtering resolver log to {len(key_creation_times)} ResolutionRequest keys from this run')

succeeded_durations = []
failed_durations = []

with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue

        key = entry.get('knative.dev/key', '')
        if key not in key_creation_times:
            continue

        entry_ts = parse_log_timestamp(entry.get('timestamp', ''))
        if entry_ts is None or entry_ts < key_creation_times[key]:
            continue

        msg = entry.get('message', entry.get('msg', ''))
        duration = entry.get('duration')

        if duration is None or not isinstance(duration, (int, float)):
            continue

        if msg == 'Reconcile succeeded':
            succeeded_durations.append(duration)
        elif 'Reconcile failed' in msg or msg == 'Reconcile error':
            failed_durations.append(duration)

all_durations = succeeded_durations + failed_durations

if not all_durations:
    print('DEBUG: No matching reconcile entries found in resolver log.')
    sys.exit(0)

def compute_stats(durations):
    durations.sort()
    n = len(durations)
    return {
        'count': n,
        'min': durations[0],
        'max': durations[-1],
        'avg': sum(durations) / n,
        'p50': durations[n // 2],
        'p90': durations[int(n * 0.9)],
        'p95': durations[int(n * 0.95)],
        'p99': durations[int(n * 0.99)],
    }

with open(output_file) as f:
    data = json.load(f)

resolver_stats = {}
resolver_stats['Overall'] = compute_stats(all_durations)
if succeeded_durations:
    resolver_stats['Success'] = compute_stats(succeeded_durations)
if failed_durations:
    resolver_stats['Failed'] = compute_stats(failed_durations)

data.setdefault('results', {}).setdefault('ResolutionRequests', {})['ResolverLog'] = resolver_stats

with open(output_file, 'w') as f:
    json.dump(data, f, indent=2)

print(f'DEBUG: ResolverLog stats - {len(all_durations)} reconciles matched '
      f'(from {len(key_creation_times)} RR keys), '
      f'Success: {len(succeeded_durations)}, Failed: {len(failed_durations)}')
print(f'DEBUG: Duration (s) - avg={resolver_stats[\"Overall\"][\"avg\"]:.6f}, '
      f'p50={resolver_stats[\"Overall\"][\"p50\"]:.6f}, '
      f'p95={resolver_stats[\"Overall\"][\"p95\"]:.6f}, '
      f'p99={resolver_stats[\"Overall\"][\"p99\"]:.6f}, '
      f'max={resolver_stats[\"Overall\"][\"max\"]:.6f}')
"
else
    echo "DEBUG: Resolver log empty or not collected. Skipping sub-second duration stats."
fi
