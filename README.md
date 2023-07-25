# scalingPipelines
The script needs following options:

* --concurrent   optional,
                 default value is 100

* --total        optional,
                 default value is 10000

* --job          optional default value is
                 https://raw.githubusercontent.com/tektoncd/pipeline/main/examples/v1/pipelineruns/using_context_variables.yaml

* --debug        optional default value is false

## Example run
```
./benchmark-tekton.sh --total 100 --concurrent 10
```
