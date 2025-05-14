#!/bin/bash -eu

source $(dirname $0)/lib.sh

PROW_GCSWEB_HOST="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com"
CACHE_DIR="prow-to-es-cache-dir"
HORREUM_HOST="https://horreum.corp.redhat.com"
DASHBOARD_ES_INDEX="results-dashboard-data"

DRY_RUN=false
DRY_RUN=true

# Check for required tools
if ! type shovel.py &>/dev/null; then
    fatal "shovel.py utility not available"
fi
if ! type jq >/dev/null; then
    fatal "Please install jq"
fi

# Check for required secrets
if [ -z "${HORREUM_API_TOKEN:-}" ]; then
    fatal "Please provide HORREUM_API_TOKEN variable"
fi

mkdir -p "$CACHE_DIR"


function check_json() {
    local f="$1"
    if cat "$f" | jq --exit-status >/dev/null; then
        debug "File is valid JSON, good"
        return 0
    else
        error "File is not a valid JSON, removing it and skipping further processing"
        head "$f"
        rm -f "$f"
        return 1
    fi
}


function check_json_string() {
    local data="$1"
    if echo "$data" | jq --exit-status >/dev/null; then
        return 0
    else
        error "String is not a valid JSON, bad"
        return 1
    fi
}


function json_complete() {
    local f="$1"
    local started="$( jq --raw-output .started "$f" )"
    if [ -z "$started" ] || [ "$started" = "null" ]; then
        error "File $f does not contain started filed: '$started'"
        return 1
    fi
    local ended="$( jq --raw-output .ended "$f" )"
    if [ -z "$ended" ] || [ "$ended" = "null" ]; then
        error "File $f does not contain ended filed: '$ended'"
        return 1
    fi
}


function enritch_stuff() {
    local f="$1"
    local key="$2"
    local value="$3"
    local current_in_file=$( cat "$f" | jq --raw-output "$key" )
    if [[ "$current_in_file" == "None" ]]; then
        debug "Adding $key to JSON file"
        cat $f | jq "$key = \"$value\"" >"$$.json" && mv -f "$$.json" "$f"
    elif [[ "$current_in_file" != "$value" ]]; then
        debug "Changing $key in JSON file"
        cat $f | jq "$key = \"$value\"" >"$$.json" && mv -f "$$.json" "$f"
    else
        debug "Key $key already in file, skipping enritchment"
    fi
}


function prow_list() {
    local job="$1"
    shovel.py prow --job-name "$job" list
}


function prow_subjob_list() {
    local url="$1"
    # Note: this `... | rev | cut ... | rev` is just a hack how to get last field
    shovel.py html links --url "$url" --regexp '.*/run-[^/]+/$' | rev | cut -d '/' -f 1 | rev
}


function prow_download() {
    local job="$1"
    local id="$2"
    local run="$3"
    local path="$4"
    local out="$5"
    if [ -e "$out" ]; then
        debug "We already have $out, not overwriting it"
    else
        shovel.py prow --job-name "$job" download --job-run-id $id --run-name "$run" --artifact-path "$path" --output-path "$out"
        debug "Downloaded $out"
    fi
}


function horreum_upload() {
    local f="$1"
    local test_job_matcher="${2:-jobName}"
    local test_job_matcher_label="${3:-jobName}"

    local test_owner="rhtap-perf-test-team"
    local test_access="PUBLIC"

    local test_matcher="$( status_data.py --status-data-file "$f" --get $test_job_matcher )"

    debug "Uploading to Horreum: $f with $test_job_matcher_label(a.k.a. $test_job_matcher): $test_matcher"

    if $DRY_RUN; then
        echo shovel.py horreum --base-url "$HORREUM_HOST" --api-token "..." upload --test-name "@name" --input-file "$f" --matcher-field "$test_job_matcher" --matcher-label "$test_job_matcher_label" --start "@started" --end "@ended" --trashed --trashed-workaround-count 20
        echo shovel.py horreum --base-url "$HORREUM_HOST" --api-token "..." result --test-name "@name" --output-file "$f" --start "@started" --end "@ended"
    else
        shovel.py horreum --base-url "$HORREUM_HOST" --api-token "$HORREUM_API_TOKEN" upload --test-name "@name" --input-file "$f" --matcher-field "$test_job_matcher" --matcher-label "$test_job_matcher_label" --start "@started" --end "@ended" --trashed --trashed-workaround-count 20
        shovel.py horreum --base-url "$HORREUM_HOST" --api-token "$HORREUM_API_TOKEN" result --test-name "@name" --output-file "$f" --start "@started" --end "@ended"
    fi
}


function resultsdashboard_upload() {
    local file="$1"
    local group="$2"
    local product="$3"
    local version="$4"

    debug "Uploading to Results Dashboard: $file"

    if $DRY_RUN; then
        echo shovel.py resultsdashboard --base-url $ES_HOST upload --input-file "$file" --group "$group" --product "$product" --test @name --result-id @metadata.env.BUILD_ID --result @result --date @started --link @jobLink --release latest --version "$version"
    else
        shovel.py resultsdashboard --base-url $ES_HOST upload --input-file "$file" --group "$group" --product "$product" --test @name --result-id @metadata.env.BUILD_ID --result @result --date @started --link @jobLink --release latest --version "$version"
    fi
}


format_date() {
    date -d "$1" +%FT%TZ --utc
}


counter=0

# Fetch JSON files from main test that runs every 12 hours
job_path="openshift-pipelines-scaling-pipelines/artifacts/"
subjob_file="benchmark-tekton.json"
for job in "scaling-pipelines-upstream-stable-daily" "scaling-pipelines-upstream-nightly-daily"; do
    prow_job="periodic-ci-openshift-pipelines-performance-main-$job"
    job_base="$PROW_GCSWEB_HOST/gcs/test-platform-results/logs/$prow_job"
    for i in $( prow_list "$prow_job" ); do
        ### TODO: We are running more sub-jobs in one job, so need to loop over this:
        ###prow_subjob_list "$job_base/$i/artifacts/$job/$job_path"
        out="$CACHE_DIR/$i-$subjob.benchmark-tekton.json"
        prow_download "$prow_job" "$i" "$job" "$job_path/$subjob/$file" "$out"
        check_json "$out" || continue
        json_complete "$out" || continue
        enritch_stuff "$out" "jobLink" "$job_base/$i/artifacts/$job/$job_path/$subjob/$subjob_file"
        enritch_stuff "$out" "\$schema" "urn:openshift-pipelines-perfscale-scalingPipelines:0.1"
        horreum_upload "$out" "metadata.env.BUILD_ID" ".metadata.env.BUILD_ID"
        resultsdashboard_upload "$out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )"
        let counter+=1
    done
done

info "Processed $counter files"
