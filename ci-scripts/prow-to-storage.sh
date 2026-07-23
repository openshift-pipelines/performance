#!/bin/bash -eu
#
# Download benchmark artifacts from Prow and upload to Horreum + Results Dashboard.
#
# Usage:
#   bash ci-scripts/prow-to-storage.sh                  # upload for real
#   DRY_RUN=true  bash ci-scripts/prow-to-storage.sh    # preview without uploading

# ── Configuration ─────────────────────────────────────────────────────────────

CACHE_DIR="prow-to-es-cache-dir"
PROW_JOB_PREFIX="periodic-ci-openshift-pipelines-performance-main-"
SCHEMA_URI="urn:openshift-pipelines-perfscale-scalingPipelines:0.2"

# shellcheck disable=SC2034
DRY_RUN="${DRY_RUN:-false}"
# shellcheck disable=SC2034
DEBUG="${DEBUG:-true}"

_MIN_VER=20
_MAX_VER=23

_PIPELINES_SUFFIXES=("" "-ha-10" "-ha-10-state" "-qbt" "-ha-10-qbt")
_CHAINS_SUFFIXES=("" "-ha-10" "-qbt" "-ha-10-qbt")

# ── Dependencies ──────────────────────────────────────────────────────────────

[ -e script-mate/ ] || git clone --depth=1 https://github.com/redhat-performance/script-mate.git
source script-mate/src/opl_shovel.sh

# ── Functions ─────────────────────────────────────────────────────────────────

# Build the list of Prow job names: one nightly + one per version in
# [min, max], each crossed with every variant suffix.
#
# $1 - nameref to target array
# $2 - base prefix    (e.g. "max-concurrency-downstream-")
# $3 - tag            (e.g. "" or "-sign-tkn-bb")
# $4 - version prefix (e.g. "pipelines1-" or "1-")
# $5 - min version    $6 - max version
# $7 - nameref to suffix array (optional — omit for no variants)
register_prow_jobs() {
    local -n _target=$1
    local prefix="$2" tag="$3" ver_prefix="$4"
    local min_ver="$5" max_ver="$6"
    local _none=("")
    local -n _suffixes="${7:-_none}"

    local sfx pv
    for sfx in "${_suffixes[@]}"; do
        _target+=("${prefix}nightly${tag}${sfx}")
    done
    for pv in $(seq "$min_ver" "$max_ver"); do
        for sfx in "${_suffixes[@]}"; do
            _target+=("${prefix}${ver_prefix}${pv}${tag}${sfx}")
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

# jq expressions for setting timestamps and SUBJOB_BUILD_ID
_JQ_ENRICH='.started = .results.started | .ended = .results.ended'
_JQ_NO_SUBJOB="$_JQ_ENRICH"' | .metadata.env.SUBJOB_BUILD_ID = .metadata.env.BUILD_ID'
_JQ_WITH_SUBJOB="$_JQ_ENRICH"' | .metadata.env.SUBJOB_BUILD_ID = .metadata.env.BUILD_ID + $sj'

# Download a single artifact, validate, enrich, and upload.
#
# $1 - output file   $2 - prow job   $3 - run ID   $4 - prow_run short name
# $5 - artifact path $6 - jq expr    $7 - subjob name (optional)
download_and_upload() {
    local out="$1" prow_job="$2" run_id="$3" prow_run="$4"
    local artifact_path="$5" jq_expr="$6" subjob="${7:-}"
    local label="${run_id}${subjob:+/$subjob}"
    local tmp_out="${out}.tmp"

    [[ -f "$out" ]] && jq empty "$out" 2>/dev/null && { debug "Cached: $out"; return 0; }

    rm -f "$tmp_out"

    prow_download "$prow_job" "$run_id" "$prow_run" "$artifact_path" "$tmp_out" "jobLink" 2>/dev/null
    if ! jq empty "$tmp_out" 2>/dev/null; then
        info "No valid artifact for $label, skipping"
        rm -f "$tmp_out"
        return 1
    fi

    if ! jq --arg sj "$subjob" "$jq_expr" "$tmp_out" > "${tmp_out}.enriched"; then
        rm -f "$tmp_out" "${tmp_out}.enriched"
        return 1
    fi
    mv -f "${tmp_out}.enriched" "$tmp_out"

    json_complete "$tmp_out" || { rm -f "$tmp_out"; return 1; }

    # shellcheck disable=SC2016
    enritch_stuff "$tmp_out" '."$schema"' "$SCHEMA_URI"

    local upload_errors=0
    horreum_upload "$tmp_out" "metadata.env.SUBJOB_BUILD_ID" "__metadata_env_SUBJOB_BUILD_ID" \
        "Openshift-pipelines-team" "PUBLIC" || ((upload_errors+=1))
    resultsdashboard_upload "$tmp_out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )" \
        "@metadata.env.SUBJOB_BUILD_ID" || ((upload_errors+=1))

    if [[ $upload_errors -eq 0 ]]; then
        mv -f "$tmp_out" "$out"
    else
        errors=$((errors + upload_errors))
        rm -f "$tmp_out"
        return 1
    fi
}

# Iterate all registered jobs: list Prow runs, download artifacts, upload.
process_prow_jobs() {
    local -n _jobs=$1

    for prow_run in "${_jobs[@]}"; do
        local job_path prow_job
        job_path="$(artifact_path_for "$prow_run")"
        prow_job="${PROW_JOB_PREFIX}${prow_run}"
        info "Processing: $prow_run"

        for run_id in $(prow_list "$prow_job"); do
            local subjobs
            subjobs=$(prow_subjob_list "$prow_job" "$run_id" "$prow_run" "$job_path") || true

            if [[ -z "$subjobs" ]]; then
                download_and_upload \
                    "$CACHE_DIR/${run_id}.benchmark-tekton.json" \
                    "$prow_job" "$run_id" "$prow_run" \
                    "$job_path/benchmark-tekton.json" \
                    "$_JQ_NO_SUBJOB" || continue
            else
                for subjob in $subjobs; do
                    download_and_upload \
                        "$CACHE_DIR/${run_id}-${subjob}.benchmark-tekton.json" \
                        "$prow_job" "$run_id" "$prow_run" \
                        "$job_path/$subjob/benchmark-tekton.json" \
                        "$_JQ_WITH_SUBJOB" "$subjob" || continue
                done
            fi
        done
    done
}

# ── Job Registration ──────────────────────────────────────────────────────────
#
# Pipelines:  nightly + 1.{20..22}, each × 5 variants
# Chains:     nightly + 1.{20..22}, each × 4 variants (no statefulSets)
# Results:    nightly + 1.{20..22}, no variants

PROW_JOBS=()
register_prow_jobs PROW_JOBS "max-concurrency-downstream-" ""             "pipelines1-" $_MIN_VER $_MAX_VER _PIPELINES_SUFFIXES
register_prow_jobs PROW_JOBS "max-concurrency-downstream-" "-sign-tkn-bb" "1-"          $_MIN_VER $_MAX_VER _CHAINS_SUFFIXES
register_prow_jobs PROW_JOBS "tkn-res-downstream-"         ""             "pipelines1-" $_MIN_VER $_MAX_VER

# ── Main ──────────────────────────────────────────────────────────────────────

mkdir -p "$CACHE_DIR"
errors=0

process_prow_jobs PROW_JOBS

exit $errors
