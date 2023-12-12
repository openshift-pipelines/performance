# OpenShift Pipelines Perf&Scale testing


## What variables are there

Setup the cluster (assuming `oc login ...` happened already):

    export DEPLOYMENT_TYPE="downstream"
    export DEPLOYMENT_VERSION="1.12"
    export DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS=""
    export DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="1/2Gi/1/2Gi"
    ci-scripts/setup-cluster.sh

Run the test:

    export TEST_TOTAL="100"
    export TEST_CONCURRENT="10"
    export TEST_RUN="./run.yaml"
    export TEST_DO_CLEANUP="false"
    ci-scripts/load-test.sh

Collect the results:

    ci-scripts/collect-results.sh


## How perf&scale CI works

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
