#!/bin/bash

set -euo pipefail

type -p jsonnet

function build() {
    local in="${1}"
    local out="${2}"
    time jsonnet -J vendor "${in}" | jq "." >"${out}"
}

mkdir -p generated/

# Dashboards
build src/pipelines-dashboard.jsonnet generated/pipelines-dashboard.json
build src/pipelines-comparison-dashboard.jsonnet generated/pipelines-comparison-dashboard.json
build src/chains-dashboard.jsonnet generated/chains-dashboard.json
build src/chains-comparison-dashboard.jsonnet generated/chains-comparison-dashboard.json
