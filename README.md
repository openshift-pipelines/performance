# OpenShift Pipelines Perf&Scale testing


## How to run manually

If you want to run the test manually, you will need these tools:

 * kubectl
 * oc
 * jq

Setup the OpenShift cluster (assuming `oc login ...` happened already):

    export DEPLOYMENT_TYPE="downstream"
    export DEPLOYMENT_VERSION="1.13"
    export DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS=""
    export DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="1/2Gi/1/2Gi"
    ci-scripts/setup-cluster.sh

Run the test:

    export TEST_TOTAL="100"
    export TEST_CONCURRENT="10"
    export TEST_RUN="./run.yaml"   # pick this scenario or some below
    # export TEST_RUN="./run-build-image.yaml"
    # export TEST_RUN="./run-image-signing.yaml"
    # export TEST_RUN="./run-image-signing-bigbang.yaml"
    export TEST_DO_CLEANUP="false"
    ci-scripts/load-test.sh

Collect the results:

    ci-scripts/collect-results.sh


## What scenarios are there

We can run multiple scenarios. These are configured via `TEST_RUN` environment variable. This is what each supported workload actually does:

### ./run.yaml

This scenario is supposed to stress Pipelines controller and OpenShift scheduler.

This runs total number of `TEST_TOTAL` PipelineRuns with concurrency `TEST_CONCURRENT`. It uses basic math Pipeline that contains of 4 simple Tasks.

This supports running on both upstream and downstream.

### ./run-build-image.yaml

This scenario is supposed to stress the cluster itself.

It deploys container serving a git repository with simple NodeJS application. It uses Pipeline that clones that repo, builds it and pushes to internal registry.

This was tested on downstream, but might work on upstream as well.

### ./run-image-signing.yaml

This scenario is supposed to stress both Pipelines and Chains controller at the same time.

It uses simple Pipeline with just one Task generates random data of a given size and pushes it to internal registry. It also measures how quickly the TaskRun gets signed annotation and also collects some additional data.

This scenario supports runs on downstreams only.

### ./run-image-signing-bigbang.yaml

This scenario is supposed to stress Chains controller.

It uses same Pipeline as previous one, but Chains controller is enabled only after all PipelineRuns are finished, so when Chains controller starts, it has `TEST_TOTAL` images to be signed waiting for it.

This scenario supports runs on downstreams only.


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

Every hour we run a CI puller script (see `ci-scripts/prow-to-storage.sh`) via [Jenkins job](https://master-jenkins-csb-perf.apps.ocp-c1.prod.psi.redhat.com/view/SeedJobs/job/PipelinesCI_puller/). There is a [Jenkinsfile](https://gitlab.cee.redhat.com/redhat-performance/ci-configs/-/blob/master/jenkins/PipelinesCI_puller.groovy) and [JobDSL](https://gitlab.cee.redhat.com/redhat-performance/ci-configs/-/blob/master/src/jobs/PipelinesCI_pullerJob.groovy?ref_type=heads) file for this job.

Script `ci-scripts/prow-to-storage.sh` lists N recent Prow builds of the job and if not pushed already, pushes their results JSON file to Horreum and OpenSearch. After uploading to Horreum, script checks if change detection detected some change, and if so, adds a "result" key to the JSON with "FAIL" value, otherwise "PASS". Upload to OpenSearch happens with this value in place.

### Horreum

Horreum instance we are using is: <https://horreum.corp.redhat.com/> (managed by Horreum team: [Horreum Google Chat space](https://chat.google.com/room/AAAALGqIRVQ?cls=7)). It is meant to help spot failing test by comparing it with historical data.

You can browse data and graphs without login, but to change the configuration, you will need an account. In Horreum we have a team `Openshift-pipelines`. Ping @johara in above linked Google Chat space to create you a user and then @kbaig or @jhutar to add you to the team.

Current test configuration:

 * JSON schema: [urn:openshift-pipelines-perfscale-scalingPipelines:0.1](https://horreum.corp.redhat.com/schema/177)
 * Test definition and changes detection configuration: [openshift-pipelines-perfscale-scalingPipelines](https://horreum.corp.redhat.com/test/295) (in `Openshift-pipelines` folder)
 * Test runs: [openshift-pipelines-perfscale-scalingPipelines Runs](https://horreum.corp.redhat.com/run/list/295)
 * Change detection: [openshift-pipelines-perfscale-scalingPipelines Changes](https://horreum.corp.redhat.com/changes?test=openshift-pipelines-perfscale-scalingPipelines&fingerprint=%7B%22.parameters.test.run%22%3A%22.%2Frun.yaml%22%2C%22.parameters.test.total%22%3A1000%2C%22.parameters.test.concurrent%22%3A100%7D)

Check test change detection settings to understand under which circumstances Horreum tags new result as a "change".

### OpenSearch

OpenSearch (a.k.a. ElasticSearch) instance we are using: <http://elasticsearch.intlab.perf-infra.lab.eng.rdu2.redhat.com/> and OpenSearch Dashboard (a.k.a. Kibana) instance we are using: <http://kibana.intlab.perf-infra.lab.eng.rdu2.redhat.com/> (managed by Perf&Scale Integrations lab team: [INTLAB Jira](https://issues.redhat.com/browse/INTLAB)). It is meant to provide useful dashboard and a way how to explore historical test data.

All data are being pushed to `pipelines_ci_status_data` index in OpenSearch. You can browse the data in "Discover" section with that index selected. As basic insight into the data you can use this [dashboard](http://kibana.intlab.perf-infra.lab.eng.rdu2.redhat.com/app/dashboards#/view/427d69b0-6e6d-11ee-897a-a399889b5129). It's JSON definition is backed up in `config/kibana/` directory.
