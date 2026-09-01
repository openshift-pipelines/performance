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

# v2 dashboards (new per-variant test IDs)
build src/pipelines-version-comparison-v2.jsonnet generated/pipelines-version-comparison-v2.json
build src/chains-version-comparison-v2.jsonnet generated/chains-version-comparison-v2.json
build src/results-dashboard.jsonnet generated/results-dashboard.json
build src/results-comparison-dashboard.jsonnet generated/results-comparison-dashboard.json
build src/results-version-comparison-v2.jsonnet generated/results-version-comparison-v2.json
build src/resolvers-dashboard.jsonnet generated/resolvers-dashboard.json
build src/resolvers-comparison-dashboard.jsonnet generated/resolvers-comparison-dashboard.json
