# "math" scenario

This scenario is supposed to stress Pipelines controller and OpenShift scheduler.

This runs total number of `TEST_TOTAL` PipelineRuns with concurrency `TEST_CONCURRENT`. It uses basic math Pipeline that consists of 4 simple Tasks, each with some parameters and results.

This supports running on both upstream Tekton and downstream Pipelines.

This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable.
