#!/bin/bash
#
# Find benchmark runs in Prow and send each artifact to the storage worker.
#
# Usage:
#   ci-scripts/prow-to-storage.sh                  # upload for real
#   DRY_RUN=true ci-scripts/prow-to-storage.sh     # preview without uploading

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

PROW_JOB_PREFIX="periodic-ci-openshift-pipelines-performance-main-"
PROW_GCSWEB_HOST="${PROW_GCSWEB_HOST:-https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com}"
PROW_LOGS_URL="${PROW_GCSWEB_HOST%/}/gcs/test-platform-results-public/logs"

DRY_RUN="${DRY_RUN:-false}"

_MIN_VER=22
_MAX_VER=24

_PIPELINES_SUFFIXES=("" "-ha-10" "-ha-10-state" "-qbt" "-ha-10-qbt")
_CHAINS_SUFFIXES=("" "-ha-10" "-qbt" "-ha-10-qbt")
_RESOLVER_SUFFIXES=("-gr" "-br" "-cr" "-gr-ha-10" "-br-ha-10" "-cr-ha-10" "-cr-ha-10-cache")

# ── Mirror checkout ───────────────────────────────────────────────────────────

[[ -n "${HDM_DIR:-}" && -d "$HDM_DIR" ]] || {
    echo "HDM_DIR must point to horreum-data-mirror" >&2
    exit 1
}

# ── Functions ─────────────────────────────────────────────────────────────────

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

prow_list() {
    shovel.py prow --base-url "$PROW_LOGS_URL" --job-name "$1" list
}

prow_subjob_list() {
    local job="$1" build_id="$2" run="$3" artifact_dir="$4" link
    shovel.py html links \
        --url "$PROW_LOGS_URL/$job/$build_id/artifacts/$run/$artifact_dir" \
        --regexp '.*/run-[^/]+/' |
        while IFS= read -r link; do
            link="${link%/}"
            printf '%s\n' "${link##*/}"
        done
}

# Build the list of Prow job names: one nightly + one per version in
# [min, max], each crossed with every variant suffix.
#
# $1 - base prefix    (e.g. "max-concurrency-downstream-")
# $2 - tag            (e.g. "" or "-sign-tkn-bb")
# $3 - version prefix (e.g. "pipelines1-" or "1-")
# $4 - min version    $5 - max version
# $6... - variant suffixes (optional; defaults to the standard variant)
register_prow_jobs() {
    local prefix="$1" tag="$2" ver_prefix="$3"
    local min_ver="$4" max_ver="$5"
    shift 5
    local suffixes=("$@")
    if (( ${#suffixes[@]} == 0 )); then
        suffixes=("")
    fi

    local sfx pv
    for sfx in "${suffixes[@]}"; do
        PROW_JOBS+=("${prefix}nightly${tag}${sfx}")
    done
    for ((pv = min_ver; pv <= max_ver; pv++)); do
        for sfx in "${suffixes[@]}"; do
            PROW_JOBS+=("${prefix}${ver_prefix}${pv}${tag}${sfx}")
        done
    done
}

# Map a job name to its artifact directory within the Prow run.
artifact_path_for() {
    case "$1" in
        tkn-res-*) echo "openshift-pipelines-scaling-pipelines/artifacts/" ;;
        *)         echo "openshift-pipelines-max-concurrency/artifacts/"   ;;
    esac
}

# Process one benchmark artifact with the Python storage worker.
# $1 - Prow job   $2 - build ID   $3 - run name
# $4 - artifact directory   $5 - subjob name (optional)
process_artifact() {
    local args=(
        --prow-logs-url "$PROW_LOGS_URL" --prow-job "$1" --job-run-id "$2"
        --prow-run "$3" --artifact-dir "$4" --subjob "${5:-}"
    )
    if [[ "$DRY_RUN" == true ]]; then
        args+=(--dry-run)
    fi
    if ! python3 ci-scripts/prow-to-storage.py "${args[@]}"; then
        errors=$((errors + 1))
    fi
}

# Iterate all registered jobs: list Prow runs, download artifacts, upload.
process_prow_jobs() {
    local prow_run
    for prow_run in "${PROW_JOBS[@]}"; do
        local job_path prow_job
        job_path="$(artifact_path_for "$prow_run")"
        prow_job="${PROW_JOB_PREFIX}${prow_run}"
        log "Processing: $prow_run"

        local run_ids run_id subjobs subjob
        if ! run_ids="$(prow_list "$prow_job")"; then
            log "Failed to list Prow runs for $prow_run"
            errors=$((errors + 1))
            continue
        fi
        for run_id in $run_ids; do
            if ! subjobs="$(prow_subjob_list "$prow_job" "$run_id" "$prow_run" "$job_path")"; then
                log "Failed to list subjobs for $prow_run/$run_id"
                errors=$((errors + 1))
                continue
            fi

            if [[ -z "$subjobs" ]]; then
                process_artifact "$prow_job" "$run_id" "$prow_run" "$job_path"
            else
                for subjob in $subjobs; do
                    process_artifact "$prow_job" "$run_id" "$prow_run" "$job_path" "$subjob"
                done
            fi
        done
    done
}

# ── Job Registration ──────────────────────────────────────────────────────────
#
# Pipelines:  nightly + 1.{22..24}, each × 5 variants
# Chains:     nightly + 1.{22..24}, each × 4 variants (no statefulSets)
# Results:    nightly + 1.{22..24}, no variants
# Resolvers:  nightly + 1.{22..24}, each × 3 types (gr, br, cr) × standard + HA-10; cluster-resolver also has HA-10-cache

PROW_JOBS=()
register_prow_jobs "max-concurrency-downstream-" ""             "pipelines1-" $_MIN_VER $_MAX_VER "${_PIPELINES_SUFFIXES[@]}"
register_prow_jobs "max-concurrency-downstream-" "-sign-tkn-bb" "1-"          $_MIN_VER $_MAX_VER "${_CHAINS_SUFFIXES[@]}"
register_prow_jobs "tkn-res-downstream-"         ""             "pipelines1-" $_MIN_VER $_MAX_VER
register_prow_jobs "max-concurrency-downstream-" ""             "1-"          $_MIN_VER $_MAX_VER "${_RESOLVER_SUFFIXES[@]}"

# ── Main ──────────────────────────────────────────────────────────────────────

errors=0

process_prow_jobs

if (( errors > 0 )); then
    log "Finished with $errors failed listings or uploads"
    exit 1
fi
log "Finished without errors"
