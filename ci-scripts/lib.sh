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
    
    # Get CatalogSource image reference
    local catalog_image
    catalog_image=$(oc get catalogsource custom-osp-nightly -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || echo "unknown")
    
    # Get image digest and details if image is available
    local image_digest="unknown"
    local image_created="unknown"
    local build_release="unknown"
    local build_version="unknown"
    local os_git_commit="unknown"
    
    if [ "$catalog_image" != "unknown" ]; then
        # Check if image info command succeeds
        if oc image info "$catalog_image" --filter-by-os=linux/amd64 >/dev/null 2>&1; then
            image_digest=$(oc image info "$catalog_image" --filter-by-os=linux/amd64 | grep "Digest:" | awk '{print $2}' 2>/dev/null || echo "unknown")
            
            # Extract build information from image labels
            local image_info_json
            image_info_json=$(oc image info "$catalog_image" --filter-by-os=linux/amd64 -o json 2>/dev/null)
            
            if [ -n "$image_info_json" ] && [ "$image_info_json" != "null" ]; then
                image_created=$(echo "$image_info_json" | jq -r '.config.created // .config.config.Labels["build-date"] // "unknown"' 2>/dev/null || echo "unknown")
                build_release=$(echo "$image_info_json" | jq -r '.config.config.Env[] | select(startswith("BUILD_RELEASE=")) | split("=")[1] // "unknown"' 2>/dev/null || echo "unknown")
                build_version=$(echo "$image_info_json" | jq -r '.config.config.Env[] | select(startswith("BUILD_VERSION=")) | split("=")[1] // "unknown"' 2>/dev/null || echo "unknown")
                os_git_commit=$(echo "$image_info_json" | jq -r '.config.config.Env[] | select(startswith("OS_GIT_COMMIT=")) | split("=")[1] // "unknown"' 2>/dev/null || echo "unknown")
            fi
        fi
    fi
    
    # Determine deployment context
    local deployment_type="${DEPLOYMENT_TYPE:-unknown}"
    local deployment_version="${DEPLOYMENT_VERSION:-unknown}"
    local is_nightly_build="${NIGHTLY_BUILD:-false}"
    
    # Create the JSON structure for deployment and nightly build info
    local deployment_info_entry
    deployment_info_entry=$(jq -n \
        --arg deployment_type "$deployment_type" \
        --arg deployment_version "$deployment_version" \
        --arg is_nightly_build "$is_nightly_build" \
        --arg image "$catalog_image" \
        --arg digest "$image_digest" \
        --arg created "$image_created" \
        --arg build_release "$build_release" \
        --arg build_version "$build_version" \
        --arg os_git_commit "$os_git_commit" \
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
                os_git_commit: $os_git_commit
            }
        }')
    
    # Check if the output file exists and add the deployment info
    if [ -f "$output_file" ]; then
        # Add deployment info to existing JSON file
        jq --argjson deployment_info "$deployment_info_entry" '.deployment = $deployment_info' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
    else
        # Create a new JSON file with deployment info
        echo "{}" | jq --argjson deployment_info "$deployment_info_entry" '.deployment = $deployment_info' > "$output_file"
    fi
    
    info "Nightly build info collected: $catalog_image ($image_digest)"
}
