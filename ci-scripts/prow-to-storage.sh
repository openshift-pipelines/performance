#!/bin/bash -eu

CACHE_DIR="prow-to-es-cache-dir"
# Used by sourced opl_shovel.sh
# shellcheck disable=SC2034
DRY_RUN=false
# shellcheck disable=SC2034
DEBUG=true

_PROW_VARIANT_SUFFIXES=("" "-ha-10" "-ha-10-state" "-qbt" "-ha-10-qbt")
PROW_JOBS=()
for sfx in "${_PROW_VARIANT_SUFFIXES[@]}"; do
    PROW_JOBS+=( "max-concurrency-downstream-nightly${sfx}" )
done
PROW_MIN_VERSION=19
PROW_MAX_VERSION=22
for pv in $(seq $PROW_MIN_VERSION $PROW_MAX_VERSION); do
    for sfx in "${_PROW_VARIANT_SUFFIXES[@]}"; do
        PROW_JOBS+=( "max-concurrency-downstream-pipelines1-${pv}${sfx}" )
    done
done
unset _PROW_VARIANT_SUFFIXES

[ -e script-mate/ ] || git clone --depth=1 https://github.com/redhat-performance/script-mate.git
source script-mate/src/opl_shovel.sh

mkdir -p "$CACHE_DIR"


errors_count=0
job_path="openshift-pipelines-max-concurrency/artifacts/"
subjob_file="benchmark-tekton.json"
for prow_run in "${PROW_JOBS[@]}"; do
    prow_job="periodic-ci-openshift-pipelines-performance-main-$prow_run"
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
            json_complete "$out" || continue
            # shellcheck disable=SC2016  # $schema is a jq field name, not a shell variable
            enritch_stuff "$out" '."$schema"' "urn:openshift-pipelines-perfscale-scalingPipelines:0.2"
            horreum_upload "$out" "metadata.env.SUBJOB_BUILD_ID" "__metadata_env_SUBJOB_BUILD_ID" "Openshift-pipelines-team" "PUBLIC" || ((errors_count+=1))
            resultsdashboard_upload "$out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )" "@metadata.env.SUBJOB_BUILD_ID" || ((errors_count+=1))
        done
    done
done

exit $errors_count
