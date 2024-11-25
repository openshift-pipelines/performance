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

function describe_entity(){
    local ns="$1"
    local entity="$2"
    local l="$3"
    
    kubectl -n "$ns" describe "$entity" -l "$l"
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
            describe_entity "$ns" "$entity" "$l"
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( now - before ))/$timeout), waiting and trying again"
        sleep 3
    done
}
