# "cluster-resolver" scenario

This scenario is supposed to stress Pipelines controller and OpenShift scheduler.

This runs total number of `TEST_TOTAL` PipelineRuns with concurrency `TEST_CONCURRENT`. 

And based on the `TEST_RESOLVER_TYPE` it decides to resolve locally or from git .

This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable.
