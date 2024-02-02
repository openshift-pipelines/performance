# "signing-bigbang" scenario

This scenario is supposed to stress Chains controller.

It uses same Pipeline as "signing-ongoing" scenario, but Chains controller is enabled only after all PipelineRuns are finished, so when Chains controller starts, it has `TEST_TOTAL` images to be signed waiting for it.

This scenario runs on downstream only.
