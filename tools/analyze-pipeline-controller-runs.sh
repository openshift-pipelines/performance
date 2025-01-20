#!/bin/bash

# This script is modified version of https://github.com/jkhelil/sample-maven/blob/main/hack/generate-db.sh that
# takes in pipeline-controller log files as input and generates a json mapping of pipelinerus/taskruns 
# to its pipeline-controller pod that processes the run.
#
# Usage
# -----
# # Collect logs 
# $ oc -n openshift-pipelines logs --tail=-1 tekton-pipelines-controller-0 > logs/controller-0.log
# $ ....

# $ analyze-pipeline-controller-runs.sh logs pipeline-controller-runs.json
#
# First Argument: Directory path to pipeline controller *.log files
# Second Argument: Location to save JSON result
#

input_dir=$1
output_path=$2



# Use temporary files instead of associative arrays for better compatibility
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

# Create temp logs directory to store filtered json lines from log
mkdir -p "$temp_dir/logs/"

index=0
for log_file in $input_dir/*.log; do
    cat $log_file | sed '/Registering [0-9] clients/d;/Registering [0-9] informer factories/d;/Registering [0-9] informers/d;/Registering [0-9] controllers/d;/Readiness and health check server listening on port 8080/d' > $temp_dir/logs/controller-$index.json
    index=$((index + 1))
done

# Initialize an empty JSON structure
json_database="{}"

# First pass: collect all pipeline runs and their task runs, mapping them to controllers
for log_file in $temp_dir/logs/controller-*.json; do
    controller_name=$(basename "$log_file" | cut -d'-' -f2 | cut -d'.' -f1)
    controller_key="controller-$controller_name"
    
    # Extract task runs and their controller assignments
    while IFS= read -r line; do
        if [[ $line =~ \"knative.dev/kind\":\"tekton.dev.TaskRun\" && $line =~ \"knative.dev/key\":\"benchmark.+\" ]]; then
            task_run=$(echo "$line" | jq -r '."knative.dev/key"' | sed 's/^benchmark[0-9]*\///')
            pipeline_run=$(echo "$task_run" | cut -d'-' -f1-2)

            # Store task run with its controller assignment
            echo "$controller_key" > "$temp_dir/${task_run}.controller"
            echo "$task_run" >> "$temp_dir/${pipeline_run}.tasks"
            echo "$pipeline_run" >> "$temp_dir/all_pipelineruns"
        fi
    done < "$log_file"
done

# Get unique pipeline runs
sort -u "$temp_dir/all_pipelineruns" > "$temp_dir/unique_pipelineruns"

# Initialize controllers in JSON
for log_file in $temp_dir/logs/controller-*.json; do
    controller_name=$(basename "$log_file" | cut -d'-' -f2 | cut -d'.' -f1)
    controller_key="controller-$controller_name"
    json_database=$(echo "$json_database" | jq --arg key "$controller_key" '. + {($key): {}}')
done

# Create a temporary file to store controller-task mappings
> "$temp_dir/controller_mappings"

# Process each pipeline run
while IFS= read -r pipeline_run; do
    [[ -z "$pipeline_run" ]] && continue
    
    # Get all task runs for this pipeline run
    if [[ -f "$temp_dir/${pipeline_run}.tasks" ]]; then
        # Clear the controller mappings for this pipeline run
        > "$temp_dir/controller_mappings"
        
        # Create mappings of controllers to task runs
        while IFS= read -r task_run; do
            if [[ -f "$temp_dir/${task_run}.controller" ]]; then
                controller=$(cat "$temp_dir/${task_run}.controller")
                echo "${controller}:${task_run}" >> "$temp_dir/controller_mappings"
            fi
        done < "$temp_dir/${pipeline_run}.tasks"

        # Process mappings for each controller
        for controller_key in $(cut -d':' -f1 "$temp_dir/controller_mappings" | sort -u); do
            # Get all task runs for this controller
            task_runs=$(grep "^${controller_key}:" "$temp_dir/controller_mappings" | cut -d':' -f2)
            
            # Skip if no task runs for this controller
            [[ -z "$task_runs" ]] && continue
            
            taskrun_array=$(echo "$task_runs" | jq -R . | jq -s '. | sort | unique')
            
            # echo "Adding to $controller_key - Pipeline Run: $pipeline_run"
            # echo "Task Runs: $(echo "$taskrun_array" | jq -c '.')"
            
            json_database=$(echo "$json_database" | jq --arg controller "$controller_key" --arg pipeline_run "$pipeline_run" --argjson taskruns "$taskrun_array" '
                .[$controller][$pipeline_run] = $taskruns
            ')
        done
    fi
done < "$temp_dir/unique_pipelineruns"

# Write the result to output.json
echo "$json_database" | jq '.' > $output_path
echo "JSON mapping generated in $output_path"


echo "Analysis of controller workload:"
echo "--------------------------------"

# Count pipeline runs per controller
echo "Pipeline runs per controller:"
jq -r 'to_entries | .[] | "\(.key): \(.value | length) pipeline runs"' $output_path

echo -e "\nTask runs per controller:"
# Count task runs per controller (flatten arrays and count unique entries)
jq -r 'to_entries | .[] | "\(.key): \(.value | values | flatten | length) task runs"' $output_path
