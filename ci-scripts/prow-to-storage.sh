#!/bin/bash -eu

CACHE_DIR="prow-to-es-cache-dir"
DRY_RUN=false
DEBUG=true


[ -e script-mate/ ] || git clone --depth=1 https://github.com/redhat-performance/script-mate.git
source script-mate/src/opl_shovel.sh

mkdir -p "$CACHE_DIR"


errors_count=0
job_path="openshift-pipelines-max-concurrency/artifacts/"
subjob_file="benchmark-tekton.json"
for prow_run in "max-concurrency-downstream-nightly-daily"; do
    prow_job="periodic-ci-openshift-pipelines-performance-main-$prow_run"
    for i in $( prow_list "$prow_job" ); do
        for subjob in $( prow_subjob_list "$prow_job" "$i" "$prow_run" "$job_path" ); do
            out="$CACHE_DIR/$i-$subjob.benchmark-tekton.json"
            prow_download "$prow_job" "$i" "$prow_run" "$job_path/$subjob/$subjob_file" "$out" "jobLink"
            check_json "$out" || continue
            jq '.started = .results.started | .ended = .results.ended' "$out" >"$$.json" && mv -f "$$.json" "$out"   # put started and ended dates to expected places
            jq '.metadata.env.SUBJOB_BUILD_ID = .metadata.env.BUILD_ID + "'"$subjob"'"' "$out" >"$$.json" && mv -f "$$.json" "$out"   # generate unique subjob ID
            json_complete "$out" || continue
            enritch_stuff "$out" '."$schema"' "urn:openshift-pipelines-perfscale-scalingPipelines:0.2"
            horreum_upload "$out" "metadata.env.SUBJOB_BUILD_ID" ".metadata.env.SUBJOB_BUILD_ID" "Openshift-pipelines-team" "PUBLIC" || ((errors_count+=1))
            resultsdashboard_upload "$out" "Developer" "OpenShift Pipelines" "$( date --utc -Idate )" || ((errors_count+=1))
        done
    done
done

exit $errors_count
