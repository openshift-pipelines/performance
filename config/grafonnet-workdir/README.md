Creating dashboards from code
=============================

We manage some dashboards using Jsonnet and Grafonnet. These tools helps us to
generate Grafana dashboard JSONs from reasonably readable code with all the
usual benefits it brings.


How to build dashboard
----------------------

First you need to install Jsonnet and Jsonnet Bundler:

    # dnf install jsonnet golang-github-jsonnet-bundler

But because default jsonnet implementation is very slow, it is better to avoid
it and install release from and put it into your PATH so it gets precedence
over one from RPM (or do not install the RPM at all):

    https://github.com/google/go-jsonnet/releases

Now you need to initialize project and download it's dependencies:

    $ jb init
    $ jb install   # will install dependencies from jsonnetfile.json

And now you can finally build some dashboard:

    $ jsonnet -J vendor dashboard.jsonnet > dashboard.json

But we have a helper to build dashboards we have right now and put them to
right places:

    $ build.sh


Links to Jsonnet and comp.
--------------------------

* Jsonnet tutorial: https://jsonnet.org/learning/tutorial.html
* Jsonnet Bundler: https://github.com/jsonnet-bundler/jsonnet-bundler/
* Grafonnet home: https://grafana.github.io/grafonnet/
* Grafonnet API refference: https://grafana.github.io/grafonnet/API/index.html
