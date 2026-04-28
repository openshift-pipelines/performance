#!/bin/bash

function _log() {
    echo "$( date -Ins --utc ) $1 $2" >&1
}

function debug() {
    _log DEBUG "$1"
}

function info() {
    _log INFO "$1"
}

function warning() {
    _log WARNING "$1"
}

function error() {
    _log ERROR "$1"
}

function fatal() {
    _log FATAL "$1"
    exit 1
}

function entity_by_selector_exists() {
    local ns
    local entity
    local l
    local expected
    local count

    ns="$1"
    entity="$2"
    l="$3"
    expected="${4:-}"   # Expect this much entities, if not set, expect more than 0

    count=$( kubectl -n "$ns" get "$entity" -l "$l" -o name 2>/dev/null | wc -l )

    if [ -n "$expected" ]; then
        debug "Number of $entity entities in $ns with label $l: $count out of $expected"
        if [ "$count" -eq "$expected" ]; then
            return 0
        fi
    else
        debug "Number of $entity entities in $ns with label $l: $count"
        if [ "$count" -gt 0 ]; then
            return 0
        fi
    fi

    return 1
}

function wait_for_entity_by_selector() {
    local timeout
    local ns
    local entity
    local l
    local expected
    local before
    local now

    timeout="$1"
    ns="$2"
    entity="$3"
    l="$4"
    expected="${5:-}"

    before=$(date --utc +%s)

    while ! entity_by_selector_exists "$ns" "$entity" "$l" "$expected"; do
        now=$(date --utc +%s)
        if [[ $(( now - before )) -ge "$timeout" ]]; then
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( now - before ))/$timeout), waiting and trying again"
        sleep 3
    done
}

function capture_results_db_query(){
    local pg_user=$1
    local pg_pwd=$2
    local pg_db=$3
    local query=$4
    local output_file=$5

    local result
    result=$(oc -n openshift-pipelines exec -i tekton-results-postgres-0 -- bash -c "PGPASSWORD=$pg_pwd psql -d $pg_db -U $pg_user -c \"SELECT json_agg(t) from ($query) t\" --tuples-only --no-align ")
    
    if [ -z "$result" ]; then
        warning "No results found or query failed."
        return
    fi

    # Create the JSON structure for the current query
    local new_entry
    new_entry=$(jq -n --arg query "$query" --argjson result "$result" '
        {query: $query, result: $result}'
    )

    # Check if the output file exists
    if [ -f "$output_file" ]; then
        # Append to existing JSON array in the file
        jq --argjson new_entry "$new_entry" '.results.ResultsDB.queries += [$new_entry]' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
    else
        # Create a new JSON array and add the new entry
        echo "{}" | jq ".results.ResultsDB.queries = [$new_entry]" > "$output_file"
    fi
}

version_gte() {
    # Compare whether the version number specified in the first argument
    # is greater than or equal to the version number in the second argument.

    # TODO: Use package manager utility for version comparison
    # https://github.com/openshift-pipelines/performance/pull/64#discussion_r2041881415
    printf '%s\n%s\n' "$2" "$1" | sort --check=quiet --version-sort
}

capture_nightly_build_info() {
    local output_file=$1

    info "Collecting nightly build information"

    # CatalogSource image reference
    local catalog_image
    catalog_image=$(oc get catalogsource custom-osp-nightly -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || echo "unknown")

    # Defaults
    local image_digest="unknown" image_created="unknown"
    local build_release="unknown" build_version="unknown"
    local pipelines_controller_git_commit="unknown"

    if [ "$catalog_image" != "unknown" ]; then
        local image_info_json
        image_info_json=$(oc image info "$catalog_image" --filter-by-os=linux/amd64 -o json 2>/dev/null || echo "")

        if [ -n "$image_info_json" ]; then
            read -r image_digest image_created build_release build_version <<<"$(
              echo "$image_info_json" | jq -r '
                [
                  .digest // "unknown",
                  .config.created // .config.config.Labels["build-date"] // "unknown",
                  (.config.config.Env[] | select(startswith("BUILD_RELEASE=")) | split("=")[1]) // "unknown",
                  (.config.config.Env[] | select(startswith("BUILD_VERSION=")) | split("=")[1]) // "unknown"
                ] | @tsv
              '
            )"
        fi
    fi

    local controller_image
    controller_image=$(
        oc -n openshift-pipelines get deploy tekton-pipelines-controller \
            -o jsonpath='{.spec.template.spec.containers[?(@.name=="tekton-pipelines-controller")].image}' \
            2>/dev/null
    ) || true
    
    controller_image="${controller_image#"${controller_image%%[![:space:]]*}"}"
    controller_image="${controller_image%"${controller_image##*[![:space:]]}"}"

    if [ -n "$controller_image" ] && [ "$controller_image" != "null" ]; then
        local controller_image_info_json
        controller_image_info_json=$(
            oc image info "$controller_image" --filter-by-os=linux/amd64 -o json 2>/dev/null
        ) || true
        if [ -n "$controller_image_info_json" ]; then
            pipelines_controller_git_commit=$(
                echo "$controller_image_info_json" | jq -r '
                    (.config.config.Labels // {}) as $L |
                    $L["upstream-vcs-ref"] // empty
                ' 2>/dev/null
            )
            [ -z "$pipelines_controller_git_commit" ] && pipelines_controller_git_commit="unknown"
        fi
    fi

    # Short SHA (7 chars) for upstream Pipelines revision
    if [ "$pipelines_controller_git_commit" != "unknown" ]; then
        pipelines_controller_git_commit="${pipelines_controller_git_commit:0:7}"
    fi

    # JSON struct
    local deployment_info_entry
    deployment_info_entry=$(jq -n \
        --arg deployment_type "${DEPLOYMENT_TYPE:-unknown}" \
        --arg deployment_version "${DEPLOYMENT_VERSION:-unknown}" \
        --arg is_nightly_build "${NIGHTLY_BUILD:-false}" \
        --arg image "$catalog_image" \
        --arg digest "$image_digest" \
        --arg created "$image_created" \
        --arg build_release "$build_release" \
        --arg build_version "$build_version" \
        --arg pipelines_controller_git_commit "$pipelines_controller_git_commit" \
        '{
            type: $deployment_type,
            version: $deployment_version,
            is_nightly_build: ($is_nightly_build | test("true"; "i")),
            nightly_build: {
                image: $image,
                digest: $digest,
                created: $created,
                build_release: $build_release,
                build_version: $build_version,
                pipelines_controller_git_commit: $pipelines_controller_git_commit
            }
        }')

    # Merge into output file (create if not exists)
    (jq --argjson deployment_info "$deployment_info_entry" \
        '.deployment = $deployment_info' "$output_file" 2>/dev/null \
     || echo "{}" | jq --argjson deployment_info "$deployment_info_entry" '.deployment = $deployment_info') \
     > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"

    info "Nightly build info collected: $catalog_image ($image_digest)"
}

capture_ha_qbt_config() {
    local output_file=$1

    info "Collecting HA and QBT configuration information"

    (cat "$output_file" 2>/dev/null || echo "{}") | jq \
        --arg ha_pipelines "${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-0}" \
        --arg controller_type "${DEPLOYMENT_PIPELINES_CONTROLLER_TYPE:-deployments}" \
        --arg qps "${DEPLOYMENT_PIPELINES_KUBE_API_QPS:-}" \
        --arg burst "${DEPLOYMENT_PIPELINES_KUBE_API_BURST:-}" \
        --arg threads "${DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER:-}" \
        --arg ocp_version "${OCP_VERSION:-$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1,2)}" \
        '.deployment.ha_config = {
            ha_enabled: (($ha_pipelines | tonumber) > 0),
            ha_replicas: ($ha_pipelines | tonumber),
            controller_type: $controller_type
        } |
        .deployment.qbt_config = {
            qbt_enabled: ($qps != "" or $burst != "" or $threads != ""),
            kube_api_qps: (if $qps != "" then ($qps | tonumber) else null end),
            kube_api_burst: (if $burst != "" then ($burst | tonumber) else null end),
            threads_per_controller: (if $threads != "" then ($threads | tonumber) else null end)
        } |
        .deployment.ocp_version = (if $ocp_version != "" then $ocp_version else null end)' > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"

    info "HA and QBT configuration collected"
}

capture_scenario_name() {
    local output_file=$1

    info "Generating scenario descriptive name"

    local scenario_name
    scenario_name=$(jq -n \
        --arg ha_replicas "${DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS:-0}" \
        --arg controller_type "${DEPLOYMENT_PIPELINES_CONTROLLER_TYPE:-deployments}" \
        --arg qps "${DEPLOYMENT_PIPELINES_KUBE_API_QPS:-}" \
        --arg burst "${DEPLOYMENT_PIPELINES_KUBE_API_BURST:-}" \
        --arg threads "${DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER:-}" \
        -r '
        "Pipelines controller with rising concurrency" as $base |
        [] |
        if ($ha_replicas | tonumber) > 0 then . + ["HA=\($ha_replicas)"] else . end |
        if $controller_type == "statefulsets" then . + ["statefulsets"] else . end |
        if ($qps != "" or $burst != "" or $threads != "") then . + ["QBT"] else . end |
        if length > 0 then "\($base) with \(join(" ")) setup" else $base end
        ')

    # Add scenario name to JSON
    (cat "$output_file" 2>/dev/null || echo "{}") | jq \
        --arg scenario_name "$scenario_name" \
        '.metadata.scenario_name = $scenario_name' \
        > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"

    info "Scenario name: $scenario_name"
}
