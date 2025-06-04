#!/bin/bash

set -eu -o pipefail

# Here we are using 'shovel.py' utility from OPL:
#
#   https://github.com/redhat-performance/opl/
#
# Example of some commands are:
#
#   shovel.py horreum --base-url https://horreum.corp.redhat.com/ --api-token "$HORREUM_API_TOKEN" schema-label-add --schema-uri "urn:rhtap-perf-team-load-test:1.0" --extractor-jsonpath "\$.xyz" --metrics --owner hybrid-cloud-experience-perfscale-team
#
#   shovel.py horreum --base-url https://horreum.corp.redhat.com/ --api-token "$HORREUM_API_TOKEN" schema-label-list --schema-uri "urn:rhtap-perf-team-load-test:1.0" | grep xyz
#
#   shovel.py horreum --base-url https://horreum.corp.redhat.com/ --api-token "$HORREUM_API_TOKEN" schema-label-add --schema-uri "urn:rhtap-perf-team-load-test:1.0" --extractor-jsonpath "\$.xyz" --metrics --owner hybrid-cloud-experience-perfscale-team --name something --update-by-id 999999
#
#   shovel.py horreum --base-url https://horreum.corp.redhat.com/ --api-token "$HORREUM_API_TOKEN" schema-label-delete --schema-uri "urn:rhtap-perf-team-load-test:1.0" --id 999999
#
# But here we are using just one that updates (or adds if label with the name is missing) labels for given extractor JSON path expressions:

function horreum_schema_label_present() {
    local extractor="$1"
    local opts="${2:---metrics}"
    shovel.py \
        --verbose \
        horreum \
        --base-url https://horreum.corp.redhat.com/ \
        --api-token "$HORREUM_API_TOKEN" \
        schema-label-update \
        --schema-uri "urn:openshift-pipelines-perfscale-scalingPipelines:0.2" \
        --owner Openshift-pipelines-team \
        --update-by-name \
        --add-if-missing \
        $opts \
        --extractor-jsonpath "${extractor}"
}

horreum_schema_label_present '$.metadata.env.BUILD_ID' "--filtering"
horreum_schema_label_present '$.metadata.env.SUBJOB_BUILD_ID' "--filtering"
horreum_schema_label_present '$.parameters.test.concurrent' "--filtering"
horreum_schema_label_present '$.parameters.test.run' "--filtering"
horreum_schema_label_present '$.parameters.test.total' "--filtering"
horreum_schema_label_present '$.results.PipelineRuns.duration.avg'
horreum_schema_label_present '$.started'
