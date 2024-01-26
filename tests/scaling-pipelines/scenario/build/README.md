# "build" scenario

This scenario is supposed to stress the cluster itself.

It deploys container serving a git repository with simple NodeJS application. It uses Pipeline that clones that repo, builds it and pushes to internal registry.

This was tested on downstream, but might work on upstream as well.
