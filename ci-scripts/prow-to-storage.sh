#!/bin/bash -eu

CACHE_DIR="prow-to-es-cache-dir"
# Used by sourced opl_shovel.sh
# shellcheck disable=SC2034
DRY_RUN=false
# shellcheck disable=SC2034
DEBUG=true

_PROW_VARIANT_SUFFIXES=("" "-ha-10" "-ha-10-state" "-qbt" "-ha-10-qbt")
_PROW_CHAINS_VARIANT_SUFFIXES=("" "-ha-10" "-qbt" "-ha-10-qbt")

# Append max-concurrency downstream Prow run names to PROW_JOBS.
#
# $1 - suffix after "nightly" (e.g. "" or "-sign-tkn-bb")
# $2 - versioned segment before ${pv} (e.g. "pipelines1-" or "1-")
# $3 - versioned segment after ${pv} (e.g. "" or "-sign-tkn-bb")
# $4 - minimum Pipelines version (inclusive)
# $5 - maximum Pipelines version (inclusive)
# $6 - nameref to variant suffix array
register_max_concurrency_jobs() {
    local nightly_extra="$1"
    local versioned_prefix="$2"
    local versioned_suffix="$3"
    local min_version="$4"
    local max_version="$5"
    local -n variant_suffixes=$6

    local sfx pv
    for sfx in "${variant_suffixes[@]}"; do
        PROW_JOBS+=( "max-concurrency-downstream-nightly${nightly_extra}${sfx}" )
    done
    for pv in $(seq "$min_version" "$max_version"); do
        for sfx in "${variant_suffixes[@]}"; do
            PROW_JOBS+=( "max-concurrency-downstream-${versioned_prefix}${pv}${versioned_suffix}${sfx}" )
        done
    done
}

# Download, enrich, and upload benchmark results from Prow to Horreum.
#
# $1 - nameref to job name array
# $2 - artifact path under the Prow run (e.g. "openshift-pipelines-max-concurrency/artifacts/")
process_prow_jobs() {
    local -n jobs=$1
    local job_path="$2"
    local subjob_file="benchmark-tekton.json"

    for prow_run in "${jobs[@]}"; do
    prow_job="periodic-ci-openshift-pipelines-performance-main-$prow_run"
    echo "prow_run: $prow_run"
    for i in $( prow_list "$prow_job" ); do
        for subjob in $( prow_subjob_list "$prow_job" "$i" "$prow_run" "$job_path" ); do
            out="$CACHE_DIR/$i-$subjob.benchmark-tekton.json"
            prow_download "$prow_job" "$i" "$prow_run" "$job_path/$subjob/$subjob_file" "$out" "jobLink"
            check_json "$out" || continue
            if jq --arg sj "$subjob" \
                '.started = .results.started
                | .ended = .results.ended
                | .metadata.env.SUBJOB_BUILD_ID = .metadata.env.BUILD_ID + $sj' \
                "$out" >"${out}.tmp"; then
                mv -f "${out}.tmp" "$out"
            else
                rm -f "${out}.tmp"
                false
            fi
                # Fix .name for early Results runs that were incorrectly labeled as Pipelines
                if [[ "$prow_run" == tkn-res-* ]] && jq -e '.name == "Scaling Pipelines test-standard"' "$out" >/dev/null 2>&1; then
                    jq '.name = "Results Performance test-standard"' "$out" > "${out}.tmp" && mv -f "${out}.tmp" "$out"
                    info "Patched .name for Results job: $out"
                fi
            json_complete "$out" || continue
            # shellcheck disable=SC2016  # $schema is a jq field name, not a shell variable
            enritch_stuff "$out" '."$schema"' "urn:openshift-pipelines-perfscale-scalingPipelines:0.2"
            horreum_upload "$out" "metadata.env.SUBJOB_BUILD_ID" "__metadata_env_SUBJOB_BUILD_ID" "Openshift-pipelines-team" "PUBLIC" || ((errors_count+=1))
            resultsdashboard_upload "$out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )" "@metadata.env.SUBJOB_BUILD_ID" || ((errors_count+=1))
            done
        done
    done
}

PROW_JOBS=()
register_max_concurrency_jobs "" "pipelines1-" "" 19 22 _PROW_VARIANT_SUFFIXES
register_max_concurrency_jobs "-sign-tkn-bb" "1-" "-sign-tkn-bb" 20 22 _PROW_CHAINS_VARIANT_SUFFIXES

_PROW_RESULTS_JOBS=(
    "tkn-res-downstream-nightly"
    "tkn-res-downstream-pipelines1-20"
    "tkn-res-downstream-pipelines1-21"
    "tkn-res-downstream-pipelines1-22"
)

[ -e script-mate/ ] || git clone --depth=1 https://github.com/redhat-performance/script-mate.git
source script-mate/src/opl_shovel.sh

mkdir -p "$CACHE_DIR"

errors_count=0
process_prow_jobs PROW_JOBS "openshift-pipelines-max-concurrency/artifacts/"
process_prow_jobs _PROW_RESULTS_JOBS "openshift-pipelines-scaling-pipelines/artifacts/"

exit $errors_count
