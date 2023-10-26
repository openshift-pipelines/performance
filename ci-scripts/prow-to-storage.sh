#!/bin/bash -eu

source $(dirname $0)/lib.sh

JOB_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/logs/periodic-ci-openshift-pipelines-performance-master-scaling-pipelines-daily"
CACHE_DIR="prow-to-es-cache-dir"
ES_HOST="http://elasticsearch.intlab.perf-infra.lab.eng.rdu2.redhat.com"
ES_INDEX="pipelines_ci_status_data"
HORREUM_HOST="https://horreum.corp.redhat.com"
HORREUM_KEYCLOAK_HOST="https://horreum-keycloak.corp.redhat.com"

mkdir -p "$CACHE_DIR"

if ! type jq >/dev/null; then
    fatal "Please install jq"
fi
if [ -z "$HORREUM_JHUTAR_PASSWORD" ]; then
    fatal "Please provide HORREUM_JHUTAR_PASSWORD variable"
fi

format_date() {
    date -d "$1" +%FT%TZ --utc
}

function download() {
    local from="$1"
    local to="$2"
    if ! [ -f "$to" ]; then
        info "Downloading $from"
        curl -Ssl -o "$to" "$from"
    else
        debug "File $to already present, skipping download"
    fi
}

function check_json() {
    local f="$1"
    if cat "$f" | jq --exit-status >/dev/null; then
        debug "File is valid JSON, good"
        return 0
    else
        error "File is not a valid JSON, removing it and skipping further processing"
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

function upload_basic() {
    local f="$1"
    local build_id="$2"
    local current_doc_in_es=$( curl --silent -X GET $ES_HOST/$ES_INDEX/_search -H 'Content-Type: application/json' -d '{"query":{"term":{"metadata.env.BUILD_ID.keyword":{"value":"'$build_id'"}}}}' | jq --raw-output .hits.total.value )
    if [[ "$current_doc_in_es" -gt 0 ]]; then
        info "Already in ES, skipping upload"
        return 0
    fi

    info "Uploading to ES"
    curl --silent \
        -X POST \
        -H 'Content-Type: application/json' \
        $ES_HOST/$ES_INDEX/_doc \
        -d "@$f" | jq --raw-output .result
}

function upload_horreum() {
    local f="$1"
    local test_name="$2"
    local test_matcher="$3"
    local build_id="$4"

    if [ ! -f "$f" -o -z "$test_name" -o -z "$test_matcher" -o -z "$build_id" ]; then
        error "Insufficient parameters when uploading to Horreum"
        return 1
    fi

    local test_owner="Openshift-pipelines-team"
    local test_access="PUBLIC"

    local test_start="$( format_date $( cat "$f" | jq --raw-output ".results.started" ) )"
    local test_end="$( format_date $( cat "$f" | jq --raw-output ".results.ended" ) )"

    if [ -z "$test_start" -o -z "$test_end" -o "$test_start" == "null" -o "$test_end" == "null" ]; then
        error "We need start ($test_start) and end ($test_end) time in the JSON we are supposed to upload"
        return 1
    fi

    debug "Considering $f to upload to Horreum: start: $test_start, end: $test_end, $test_matcher: $build_id"

    local TOKEN=$( curl -s $HORREUM_KEYCLOAK_HOST/realms/horreum/protocol/openid-connect/token -d "username=jhutar@redhat.com" -d "password=$HORREUM_JHUTAR_PASSWORD" -d "grant_type=password" -d "client_id=horreum-ui" | jq --raw-output .access_token )

    local test_id=$( curl --silent --get -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" "$HORREUM_HOST/api/test/byName/$test_name" | jq --raw-output .id )

    local exists=$( curl --silent --get -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" "$HORREUM_HOST/api/dataset/list/$test_id" --data-urlencode "filter={\"$test_matcher\":\"$build_id\"}" | jq --raw-output '.datasets | length' )

    if [[ $exists -gt 0 ]]; then
        info "Test result $f ($test_matcher=$build_id) found in Horreum ($exists), skipping upload"
        return 0
    fi

    info "Uploading $f to Horreum"
    curl --silent \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        "$HORREUM_HOST/api/run/data?test=$test_name&start=$test_start&stop=$test_end&owner=$test_owner&access=$test_access" \
        -d "@$f"
}

counter=0

# Fetch JSON files from main test that runs every 12 hours
for i in $(curl -SsL "$JOB_BASE" | grep -Eo '[0-9]{19}' | sort -V | uniq | tail -n 10); do
    f="$JOB_BASE/$i/artifacts/scaling-pipelines-daily/openshift-pipelines-scaling-pipelines/artifacts/benchmark-tekton.json"
    out="$CACHE_DIR/$i.benchmark-tekton.json"

    download "$f" "$out"
    check_json "$out" || continue
    upload_basic "$out" "$i"
    enritch_stuff "$out" '."$schema"' "urn:openshift-pipelines-perfscale-scalingPipelines:0.1"
    upload_horreum "$out" "openshift-pipelines-perfscale-scalingPipelines" ".metadata.env.BUILD_ID" "$i"
    let counter+=1
done

info "Processed $counter files"
