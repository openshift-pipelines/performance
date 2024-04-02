#!/bin/bash

# The scripts extracts run stats for PipelineRuns and TaskRuns from 'benchmark-output.json' into CSV files.
#
# Usage
# -----
# $ capture-sign-finalizer-runs-stats.sh artifacts/benchmark-output.json
#
# The script takes only one argument which is the path to the 'benchmark-output.json' artifact.
# It creates the below directory structure and stores the run stats into these CSV files.
# .
# └── sign-finalizers/
#     ├── pipelineruns-sign-finalizer-stat.csv
#     └── taskruns-sign-finalizer-stat.csv
#

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/../ci-scripts/lib.sh"

benchmark_result_file="$1"
output_folder_location="sign-finalizers"
pipelineruns_out_file="$output_folder_location/pipelineruns-sign-finalizer-stat.csv"
taskruns_out_file="$output_folder_location/taskruns-sign-finalizer-stat.csv"

headers="creationTimestamp,state,finalizers,signed,startTime,completionTime,finished_at,outcome,finalizers_at,signed_at\n"

if [ -z "$benchmark_result_file" ]; then
    fatal "Please provide a path to benchmark-outpiut.json"
fi

mkdir -p $output_folder_location

# Collect finalizer, sign statuses for pipelineruns

printf $headers > $pipelineruns_out_file

cat $benchmark_result_file | jq -r '.pipelineruns | to_entries | map(.value | [.creationTimestamp, .state, .finalizers, .signed, .startTime, .completionTime, .finished_at, .outcome, .finalizers_at, .signed_at] | @csv)[]' >> $pipelineruns_out_file

# Collect finalizer, sign statuses for taskruns

printf $headers > $taskruns_out_file

cat $benchmark_result_file | jq -r '.taskruns | to_entries | map(.value | [.creationTimestamp, .state, .finalizers, .signed, .startTime, .completionTime, .finished_at, .outcome, .finalizers_at, .signed_at] | @csv)[]' >> $taskruns_out_file
