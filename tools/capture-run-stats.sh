#!/bin/bash

# The scripts extracts run stats for PipelineRuns and TaskRuns from 'benchmark-output.json' into CSV files.
#
# Usage
# -----
# $ capture-run-stats.sh artifacts/benchmark-output.json
#
# The script takes only one argument which is the path to the 'benchmark-output.json' artifact.
# It creates the below directory structure and stores the run stats into these CSV files.
# .
# └── ./
#     ├── pipelineruns-stats.csv
#     └── taskruns-stats.csv
#

set -o nounset
set -o errexit
set -o pipefail

benchmark_result_file="$1"
pipelineruns_out_file="pipelineruns-stats.csv"
taskruns_out_file="taskruns-stats.csv"

headers="creationTimestamp,state,finalizers,signed,startTime,completionTime,finished_at,outcome,finalizers_at,signed_at,terminated,terminating,deleted,deleted_at,log_at,result_at\n"

if [ -z "$benchmark_result_file" ]
then
    echo "Please provide a path to benchmark-output.json"
    exit 1
fi

# Collect finalizer, sign statuses for pipelineruns

printf $headers > $pipelineruns_out_file

cat $benchmark_result_file | jq -r '.pipelineruns | to_entries | map(.value | [.creationTimestamp, .state, .finalizers, .signed, .startTime, .completionTime, .finished_at, .outcome, .finalizers_at, .signed_at, .terminated, .deletionTimestamp, .deleted, .deleted_at, .log_at, .result_at] | @csv)[]' >> $pipelineruns_out_file

# Collect finalizer, sign statuses for taskruns

printf $headers > $taskruns_out_file

cat $benchmark_result_file | jq -r '.taskruns | to_entries | map(.value | [.creationTimestamp, .state, .finalizers, .signed, .startTime, .completionTime, .finished_at, .outcome, .finalizers_at, .signed_at, .terminated, .deletionTimestamp, .deleted, .deleted_at, .log_at, .result_at] | @csv)[]' >> $taskruns_out_file
