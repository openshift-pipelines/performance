# "signing-tr-tekton-bigbang-with-baseline" scenario

This scenario is used to establish a baseline performance by:
1. Monitoring the cluster for $WAIT_TIME duration without any load.
2. Creating PRs/TRs and analyze the load for another $WAIT_TIME duration.
3. Enable Chains to analyze chains controller usage and metrics.

This scenario runs on downstream only.

> Make sure to set WAIT_TIME environment variable to duration of waiting time (in seconds).