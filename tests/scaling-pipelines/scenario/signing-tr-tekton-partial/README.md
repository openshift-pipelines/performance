# "signing-tr-tekton-partial" scenario

This scenario is supposed to stress Chains controller while still creating more PRs and TRs, signing just PipelineRuns and TaskRuns, no artifacts involved.

Goal here is to see if we can keep up.

Half of `TEST_TOTAL` PRs will be created, then Chains will be anabled, then rest of PRs will be created.

This scenario runs on downstream only.
