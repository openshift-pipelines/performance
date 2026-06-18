# Horreum Integration

This directory (`tools/horreum/`) contains configuration and tooling for managing [Horreum](https://horreum.hyperfoil.io/) test definitions, schema labels, and change detection variables for OpenShift Pipelines performance tests.

## Files

| File | Purpose |
|---|---|
| `run_horreum_integration.sh` | Wrapper script that invokes `horreum_api.py` with env validation and defaults |
| `horreum_pipeline/` | Five scenario-specific Horreum configs under `tools/horreum/horreum_pipeline/` |
| `horreum_chains_fields.yaml` | Horreum config for the **Chains** test (`OpenShift Pipelines Chains signing test`) |

## Architecture

Both tests **share the same Horreum schema** (`urn:openshift-pipelines-perfscale-scalingPipelines:0.2`) since labels live on the schema, not the test. Each YAML defines its own:

- **Test** — separate Horreum test with its own name, fingerprint labels, and description
- **Labels** — subset of schema labels relevant to that test type
- **Change detection groups (CDGs)** — variables that trigger regression alerts

```
┌─────────────────────────────────────────────────┐
│          Shared Schema                          │
│  urn:openshift-pipelines-perfscale-...          │
│                                                 │
│  Labels from Pipelines YAML ──┐                 │
│  Labels from Chains YAML ─────┤ (union on       │
│                               │  shared schema) │
├───────────────────┬───────────┴─────────────────┤
│ Pipelines Test    │ Chains Test                 │
│ - own CDGs        │ - own CDGs                  │
│ - own fingerprint │ - own fingerprint           │
│ - own variables   │ - own variables             │
└───────────────────┴─────────────────────────────┘
```

## Usage

### Prerequisites

Install OPL extras (provides `horreum_api.py`):

```bash
pip install "git+https://github.com/redhat-performance/opl.git#subdirectory=extras&egg=opl-rhcloud-perf-team-extras"
```

### Required environment variables

```bash
export HORREUM_URL="https://your-horreum-instance"
export HORREUM_API_KEY="HUSR_00000000_0000_0000_0000_000000000000"
```

### Running

```bash
# Dry-run (default) — preview changes without applying
./tools/horreum/run_horreum_integration.sh

# Execute changes
./tools/horreum/run_horreum_integration.sh --execute

# Use a specific config file
./tools/horreum/run_horreum_integration.sh -c tools/horreum/horreum_chains_fields.yaml
```

### Multi-test setup

Since both YAMLs share the same schema, the script must be run **twice** with `CLEANUP_LABELS=false` to prevent one invocation from deleting the other test's labels:

```bash
export CLEANUP_LABELS=false

# Configure Pipelines test
./tools/horreum/run_horreum_integration.sh -c tools/horreum/horreum_pipeline_fields.yaml --execute

# Configure Chains test
./tools/horreum/run_horreum_integration.sh -c tools/horreum/horreum_chains_fields.yaml --execute
```

> **Warning:** With `CLEANUP_LABELS=false`, removing a label from a YAML file will **not** delete it from Horreum. Stale labels must be removed manually via the Horreum UI if needed.

## YAML structure

Each YAML file follows this structure:

```yaml
global:
  owner: "Openshift-pipelines-team"
  access: "PUBLIC"

change_detection_defaults:
  model: "relativeDifference"
  window: 10
  min_previous: 5
  threshold: 0.10

change_detection_groups:
  "group_name":
    description: "What this group monitors"
    model: "relativeDifference"    # or "fixedThreshold"
    threshold: 0.10
    window: 5
    min_previous: 5

test:
  name: "Test name (must match the 'name' field in benchmark-tekton.json)"
  owner: "Openshift-pipelines-team"
  folder: "Openshift-pipelines"
  fingerprintLabels:
    - label_name_1
    - label_name_2

schema:
  uri: "urn:openshift-pipelines-perfscale-scalingPipelines:0.2"
  name: "openshift-pipelines-perfscale-scalingPipelines-0.2"

fields:
  - name: "label_name"
    jsonpath: "$.path.in.benchmark.tekton.json"
    description: "Human-readable description"
    filtering: true              # available as a filter in Horreum UI
    metrics: true                # tracked as a metric
    change_detection_group: "group_name"  # null = no alerting
```

## Change detection models

| Model | Use case | Key parameters |
|---|---|---|
| `relativeDifference` | Performance metrics (CPU, memory, duration, throughput) | `threshold` (e.g. 0.10 = 10% change triggers alert) |
| `fixedThreshold` | Counts that must be exact (failures = 0, restarts = 0) | `min_value`, `max_value`, `min_enabled`, `max_enabled` |

## Fingerprint labels

Fingerprint labels partition data so Horreum compares like-for-like runs. Each test uses different fingerprints:

**Pipelines test:**
- `deployment_haConfig_haEnabled`, `deployment_version`, `parameters_test_total`, `parameters_test_concurrent`, `deployment_haConfig_controllerType`, `deployment_qbtConfig_qbtEnabled`

**Chains test:**
- `deployment_haConfig_haEnabled`, `deployment_version`, `parameters_test_total`, `deployment_qbtConfig_qbtEnabled`, `metadata_env_TEST_SCENARIO`

Chains omits `parameters_test_concurrent` (always 20) and `deployment_haConfig_controllerType` (always "deployments"), and adds `metadata_env_TEST_SCENARIO` to distinguish signing scenarios.

## How the `name` field connects everything

The `name` field in `benchmark-tekton.json` determines which Horreum test receives the data:

- `stats.sh` sets the name from deployment env vars (HA / QBT / controller type):
  - `*signing*` → `"OpenShift Pipelines Chains signing test"`
  - standard → `"Scaling Pipelines test-standard"`
  - QBT only → `"Scaling Pipelines test-qbt_deployement"`
  - HA deployments → `"Scaling Pipelines test-ha_deployement"`
  - HA statefulSets → `"Scaling Pipelines test-ha_statefulsets"`
  - HA + QBT → `"Scaling Pipelines test-ha_qbt"`
- `prow-to-storage.sh` patches `.name` from the Prow job suffix before upload
- The Horreum `test.name` in each scenario YAML must match exactly

Scenario YAML files:

| File | Horreum test name |
|---|---|
| `horreum_pipeline_standard.yaml` | `Scaling Pipelines test-standard` |
| `horreum_pipeline_qbt_deployement.yaml` | `Scaling Pipelines test-qbt_deployement` |
| `horreum_pipeline_ha_deployement.yaml` | `Scaling Pipelines test-ha_deployement` |
| `horreum_pipeline_ha_statefulsets.yaml` | `Scaling Pipelines test-ha_statefulsets` |
| `horreum_pipeline_ha_qbt.yaml` | `Scaling Pipelines test-ha_qbt` |
