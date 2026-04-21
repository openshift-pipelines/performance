#!/bin/bash -eu

CACHE_DIR="prow-to-es-cache-dir"
DRY_RUN=false
DEBUG=true

_PROW_VARIANT_SUFFIXES=("" "-ha-10" "-ha-10-state" "-qbt" "-ha-10-qbt")
PROW_JOBS=()
for sfx in "${_PROW_VARIANT_SUFFIXES[@]}"; do
    PROW_JOBS+=( "max-concurrency-downstream-nightly${sfx}" )
done
for pv in 19 20 21; do
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
            jq --arg sj "$subjob" \
                '.started = .results.started
                | .ended = .results.ended
                | .metadata.env.SUBJOB_BUILD_ID = .metadata.env.BUILD_ID + $sj' \
                "$out" >"${out}.tmp" && mv -f "${out}.tmp" "$out" \
                || { rm -f "${out}.tmp"; false; }
            json_complete "$out" || continue
            enritch_stuff "$out" '."$schema"' "urn:openshift-pipelines-perfscale-scalingPipelines:0.2"
            horreum_upload "$out" "metadata.env.SUBJOB_BUILD_ID" "__metadata_env_SUBJOB_BUILD_ID" "Openshift-pipelines-team" "PUBLIC" || ((errors_count+=1))
            resultsdashboard_upload "$out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )" "@metadata.env.SUBJOB_BUILD_ID" || ((errors_count+=1))
        done
    done
done

exit $errors_count
