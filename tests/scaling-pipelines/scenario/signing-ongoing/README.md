# "signing-ongoing" scenario

This scenario is supposed to stress both Pipelines and Chains controller at the same time.

It uses simple Pipeline with just one Task that generates random data of a given size and pushes it to internal registry. It also measures how quickly the TaskRun gets signed annotation and also collects some additional data.

This scenario runs on downstream only.
