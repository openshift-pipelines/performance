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
build src/first.jsonnet generated/first.json
