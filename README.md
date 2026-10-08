# OpenShift Pipelines Perf&Scale testing


## How to run manually

If you want to run the test manually, you will need these tools:

 * kubectl
 * oc
 * jq

Setup the OpenShift cluster (assuming `oc login ...` happened already):

## For Regular Builds

    export DEPLOYMENT_TYPE="downstream"
    export DEPLOYMENT_VERSION="1.15"          # Required for regular builds
    # export NIGHTLY_BUILD="true"               # DEPLOYMENT_VERSION not needed for nightly builds
    export DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS=""
    export DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS=""
    export DEPLOYMENT_PIPELINES_KUBE_API_QPS=""
    export DEPLOYMENT_PIPELINES_KUBE_API_BURST=""
    export DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER=""
    export DEPLOYMENT_CHAINS_KUBE_API_QPS=""
    export DEPLOYMENT_CHAINS_KUBE_API_BURST=""
    export DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER=""
    export DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="1/2Gi/1/2Gi"

    # export INSTALL_RESULTS="true"
    # export STORE_LOGS_IN_S3="true"
    # export DEPLOYMENT_TYPE_RESULTS="downstream" # "upstream" (Default: downstream)
    # export DEPLOYMENT_RESULTS_UPSTREAM_VERSION="v0.11.0" # Used only for upstream (Default: latest)
    # export RUN_LOCUST="true"
    # export DEPLOYMENT_RESULTS_DOWNSTREAM_VERSION="1.16" (Default: 1.16)
    # export AWS_REGION="eu-west-1"
    # export AWS_ENDPOINT="https://s3.eu-west-1.amazonaws.com"

    # Results Watcher Performance Tuning (optional, used when INSTALL_RESULTS="true")
    # export DEPLOYMENT_RESULTS_WATCHER_KUBE_API_QPS="50.0"           # API QPS limit for Results Watcher
    # export DEPLOYMENT_RESULTS_WATCHER_KUBE_API_BURST="100"          # API burst limit for Results Watcher
    # export DEPLOYMENT_RESULTS_WATCHER_THREADINESS="16"              # Number of worker threads for Results Watcher
    # export DEPLOYMENT_RESULTS_WATCHER_HA_REPLICAS="2"               # Results Watcher replicas; buckets are calculated automatically
    # export DEPLOYMENT_RESULTS_WATCHER_CONTROLLER_TYPE="deployments"  # deployments or statefulSets; statefulSets enables StatefulSet ordinals
    # export DEPLOYMENT_RESULTS_WATCHER_DISABLE_STORING_INCOMPLETE_RUNS="true"  # Disable storing incomplete runs (improves performance)
    # Results Watcher HA and StatefulSet settings are experimental; validate them against the installed Results/operator version.


    # export DEPLOYMENT_VERSION="1.14"
    # export DEPLOYMENT_VERSION="1.13"
    ci-scripts/setup-cluster.sh

Run the test:

    export TEST_NAMESPACE="1"
    export TEST_DO_CLEANUP="false"
    export TEST_TOTAL="100"
    export TEST_CONCURRENT="10"
    export TEST_TIMEOUT=18000
    export TEST_SCENARIO="math"   # pick this scenario or some of these below
    # export TEST_SCENARIO="build"
    # export TEST_SCENARIO="signing-ongoing"
    # export TEST_SCENARIO="signing-bigbang"
    # export TEST_SCENARIO="signing-tr-varying-concurrency"
    # export TEST_SCENARIO="cluster-resolver"
    # export CHAINS_ENABLE_TIME=0
    # ...and more
    ci-scripts/load-test.sh

Collect the results:

    ci-scripts/collect-results.sh


## Dependencies

This is what I did recently on RHEL9 to make test run:

    # Packages
    rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
    dnf install tmux python3-pip jq parallel git-core

    # kubectl
    curl -Lso /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    chmod +x /usr/local/bin/kubectl

    # oc from https://access.redhat.com/downloads/content/290
    curl -o oc-4.15.0-linux.tar.gz -L "https://access.cdn.redhat.com/content/origin/files/sha256/f0/f0.../oc-4.15.0-linux.tar.gz?user=...&_auth_=..."
    tar xzf oc-4.15.0-linux.tar.gz
    cp oc /usr/local/bin/oc
    chmod +x /usr/local/bin/oc

    # cosign
    curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
    mv cosign-linux-amd64 /usr/local/bin/cosign
    chmod +x /usr/local/bin/cosign

    # Login to OCP cluster
    oc login https://...:6443 --username ... --password ... --insecure-skip-tls-verify


## What scenarios are there

You can run multiple different scenarios.
These are configured via `TEST_SCENARIO` environment variable.
To learn what each scenario does, check readme files in `tests/scaling-pipelines/scenario/` subfolders.


## How perf&scale CI works

This section describes what is configured where when it comes to automated runs of this test in OpenShift CI/Prow system.

### Prow

To execute the tests we are using Prow. Jobs in Prow were configured in [openshift/release PR#44206](https://github.com/openshift/release/pull/44206).

Nice documentation on how to onboard new test is [OpenShift CI Scenario Onboarding Guide](https://github.com/CSPI-QE/ocp-ci-docs/blob/main/docs/Onboarding/Onboarding_Guide.md).

Description of ci-operator configuration is in [Types of Tests](https://docs.ci.openshift.org/docs/architecture/ci-operator/#types-of-tests).

If we ever need to add some secrets to the test, review [OpenShift CI Interop Scenario Secrets Guide](https://github.com/CSPI-QE/ocp-ci-docs/blob/main/docs/OCP_CI_Tutorials/Secrets/Secrets_Guide.md) docs. There is *openshift-pipelines-perfscale* collection in [OpenShift CI Secret Collection Management](https://selfservice.vault.ci.openshift.org/). Login there and ping @jhutar to make you a member to be able to see it. Once added, you should be able to see the secret in [OpenShift CI Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/show/selfservice/openshift-pipelines-perfscale/scalingPipelines). In the job, secrets needs to be mounted under `/usr/local/ci-secrets/openshift-pipelines-perfscale` directory (it was removed as not necessary after initial PR).

In openshift/release repo PR, you can trigger the test with `/pj-rehearse pull-ci-openshift-pipelines-performance-master-scaling-pipelines`. Also twice a day (02:00 and 14:00 UTC) Prow will trigger `periodic-ci-openshift-pipelines-performance-master-scaling-pipelines-daily` ([history](https://prow.ci.openshift.org/job-history/gs/origin-ci-test/logs/periodic-ci-openshift-pipelines-performance-master-scaling-pipelines-daily)).

Test code is in `tests/scalingPipelines/` directory. See readme in that directory for more info.

### Pusher

Every hour we run a CI puller script (see `ci-scripts/prow-to-storage.sh`) via [Jenkins job](https://jenkins-csb-perf-master.dno.corp.redhat.com/job/PipelinesCI_puller/). There is a [Jenkinsfile](https://gitlab.cee.redhat.com/redhat-performance/ci-configs/-/blob/master/jenkins/PipelinesCI_puller.groovy) and [JobDSL](https://gitlab.cee.redhat.com/redhat-performance/ci-configs/-/blob/master/src/jobs/PipelinesCI_pullerJob.groovy?ref_type=heads) file for this job.

`ci-scripts/prow-to-storage.sh` lists recent nightly and per-version Prow builds for Pipelines, Chains, Results, and Resolvers, including their variants and subjobs. For each artifact, `ci-scripts/prow-to-storage.py` downloads and enriches `benchmark-tekton.json` with timestamps, `SUBJOB_BUILD_ID`, schema URI, and temporary `PASS` result. It runs `compute_labels.py` from `horreum-data-mirror` against the single definition in `config/benchmark-label-schema.json`, omits labels with missing values to match historical PostgreSQL rows, then calls its `labels_to_postgresql.py` to insert into the existing PostgreSQL `data` table. The complete benchmark JSON remains in Prow; PostgreSQL receives the extracted labels. The Python script passes `--check-label __metadata_env_SUBJOB_BUILD_ID`, so repeated and historically mirrored Prow runs are skipped. It also sends the enriched JSON to Results Dashboard and automatically removes its temporary files.

The puller calls `shovel.py` for Prow discovery and Results Dashboard uploads. The Python script downloads Prow JSON with `requests` and checks its HTTP status, JSON content, and required fields before computing labels. Missing artifacts (HTTP 404) are skipped; other HTTP failures fail the job. Results Dashboard uses `SUBJOB_BUILD_ID` as its result ID, so separate subjobs have separate entries. The job no longer clones or sources `script-mate`.

The PostgreSQL table retains its historical column names (`horreum_testid`, `horreum_runid`, `horreum_datasetid`). New rows use the existing per-variant test IDs needed by current reports and Grafana queries. The run and dataset IDs are the UTC start date (`YYYYMMDD`) and time (`HHMMSS`). If two different runs share that second, the Python script retries with a negative dataset ID; a true repeat is identified by `SUBJOB_BUILD_ID`. `__test_family`, `__test_variant`, `__resolver_type`, and Prow provenance labels distinguish the records. The Jenkins job passes the PostgreSQL connection through `POSTGRES_PIPELINE_DB_HOST`, `POSTGRES_PIPELINE_DB_PORT`, `POSTGRES_PIPELINE_DB_USER`, `POSTGRES_PIPELINE_DB_NAME`, and `POSTGRES_PIPELINE_DB_PASSWORD`.

Run `DRY_RUN=true bash ci-scripts/prow-to-storage.sh` to list and download Prow artifacts, validate them, compute labels, and preview PostgreSQL and Results Dashboard writes without connecting to PostgreSQL or uploading. When running outside Jenkins, activate the project virtual environment and set `HDM_DIR` to a local `horreum-data-mirror` checkout. The label schema is shared; separate YAML files are not needed for ingestion.

To inspect the exact `label_values` JSONB object for one artifact, call `ci-scripts/prow-to-storage.py` with `--dry-run --show-label-values` and the Prow job name, build ID, run name, and artifact directory. This prints the fetched URL and only the labels with values; it does not need PostgreSQL credentials.

The hourly run uses `shovel.py prow list`, which returns the latest 10 builds per job.

### Regression alerts

The YAML files under `tools/horreum/` remain as the source for historical safe bounds and change detection settings. The direct PostgreSQL ingestion path does not evaluate these rules yet. Until a PostgreSQL-based alerting script is connected to the job, new Results Dashboard entries are marked `PASS` as a temporary default; this is not the result of a regression check. Porting the rules, establishing a comparable-run baseline, and wiring notifications are the remaining alerting work in the Horreum retirement.

### OpenSearch

OpenSearch (a.k.a. ElasticSearch) instance we are using: <http://elasticsearch.intlab.perf-infra.lab.eng.rdu2.redhat.com/> and OpenSearch Dashboard (a.k.a. Kibana) instance we are using: <http://kibana.intlab.perf-infra.lab.eng.rdu2.redhat.com/> (managed by Perf&Scale Integrations lab team: [INTLAB Jira](https://issues.redhat.com/browse/INTLAB)). It is meant to provide useful dashboard and a way how to explore historical test data.

All data are being pushed to `pipelines_ci_status_data` index in OpenSearch. You can browse the data in "Discover" section with that index selected. As basic insight into the data you can use this [dashboard](http://kibana.intlab.perf-infra.lab.eng.rdu2.redhat.com/app/dashboards#/view/427d69b0-6e6d-11ee-897a-a399889b5129). It's JSON definition is backed up in `config/kibana/` directory.
