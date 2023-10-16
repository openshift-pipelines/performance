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
    log WARNING "$1"
}

function error() {
    _log ERROR "$1"
}

function fatal() {
    _log FATAL "$1"
    exit 1
}
