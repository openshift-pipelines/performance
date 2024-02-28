#!/usr/bin/env python
# -*- coding: UTF-8 -*-

import json
import logging
from kubernetes import client, config, watch
import kubernetes.client.exceptions

import urllib3

urllib3.disable_warnings()

config.load_kube_config()

api_instance = client.CustomObjectsApi()

func = api_instance.list_namespaced_custom_object
kwargs = {
    "group": "tekton.dev",
    "version": "v1",
    "namespace": "benchmark",
    "plural": "pipelineruns",
    "pretty": False,
    "limit": 10,
    "timeout_seconds": 100,   # server timeout
    "_request_timeout": 100,   # client timeout
}
w = watch.Watch()

def find(path, data):
    # Thanks https://stackoverflow.com/questions/31033549/nested-dictionary-value-from-key-path
    keys = path.split('.')
    rv = data
    for key in keys:
        rv = rv[key]
    return rv

pipelineruns = {}
expected_concurrent = 100
expected_total = 30000

###fd = open("data.json", "w")
###for event in w.stream(func, **kwargs):
###    fd.write(json.dumps(event) + "\n")
###fd.close()
###sys.exit()

def safe_stream_retry(w, func, **kwargs):
    """
    Iterate through events, skipping these without resource_version.
    If watch just ends (no more events), retry it.
    """
    while True:
        for e in w.stream(func, **kwargs):
            try:
                kwargs["resource_version"] = e["object"]["metadata"]["resourceVersion"]
            except KeyError as e:
                logging.warning("Missing resource version in {json.dumps(e)} => skipping it")
                continue
            yield e

        logging.warning("Event watch failed (last resource version {kwargs['resource_version']}), retrying")


def safe_stream(w, func, **kwargs):
    """
    Catch unimportant issues and retries as needed.
    """
    while True:
        try:
            for e in safe_stream_retry(w, func, **kwargs):
                yield e
        except kubernetes.client.exceptions.ApiException as e:
            if e.status == 410:   # Resource too old
                e_text = str(e).replace("\n", "")
                logging.warning(f"Watch failed with: {e_text}, resetting resource_version")
                kwargs["resource_version"] = None
            else:
                raise
        except urllib3.exceptions.ReadTimeoutError as e:
            logging.warning(f"Watch failed with: {e}, retrying")

###count = 10
###fd = open("data.json", "r")
counter = 0
for event in safe_stream(w, func, **kwargs):
###for event in fd.readlines():
    ###event = json.loads(event)
    #print(f"Event: {event['type']} {event['object']['kind']} {event['object']['metadata']['name']}     {json.dumps(event)}")
    ###print(f"Event: {event['type']} {event['object']['kind']} {event['object']['metadata']['name']}")
    ###count -= 1
    ###if count == 0:
    ###    break

    try:
        pr_name = find("object.metadata.name", event)
    except KeyError as e:
        logging.warning(f"Missing name in {json.dumps(event)} => skipping it")
        continue

    if pr_name not in pipelineruns:
        pipelineruns[pr_name] = {}

    # Collect timestamps if we do not have it already
    for path in ["object.metadata.creationTimestamp", "object.status.startTime", "object.status.completionTime"]:
        name = path.split(".")[-1]
        if name not in pipelineruns[pr_name]:
            try:
                response = find(path, event)
            except KeyError as e:
                ###logging.warning(f"Missing {path} in {pr_name}")
                pass
            else:
                pipelineruns[pr_name][name] = response

    # Determine state and possibly outcome
    try:
        conditions = find("object.status.conditions", event)
    except KeyError:
        pipelineruns[pr_name]["state"] = "pending"
    else:
        if conditions[0]["status"] == "Unknown":
            pipelineruns[pr_name]["state"] = "running"
        elif conditions[0]["status"] != "Unknown":
            pipelineruns[pr_name]["state"] = "finished"

            if conditions[0]["type"] == "Succeeded":
                if conditions[0]["status"] == "True" and conditions[0]["reason"] == "Succeeded":
                    pipelineruns[pr_name]["outcome"] = "succeeded"
                elif conditions[0]["status"] != "True" and conditions[0]["reason"] != "Succeeded":
                    pipelineruns[pr_name]["outcome"] = "failed"
                else:
                    pipelineruns[pr_name]["outcome"] = "unknown"

    ###print(pipelineruns[pr_name])

    # Count some stats
    total = len(pipelineruns)
    if counter % 100 == 0:
        finished = len([i for i in pipelineruns.values() if i["state"] == "finished"])
        running = len([i for i in pipelineruns.values() if i["state"] == "running"])
        pending = len([i for i in pipelineruns.values() if i["state"] == "pending"])
        should_be_started = min(expected_concurrent - running - pending, expected_total - total)
        print({"finished": finished, "running": running, "pending": pending, "total": total, "should_be_started": should_be_started})

    counter += 1

    if total >= expected_total:
        print("DONE")
        break


fd = open("data2.json", "w")
json.dump(pipelineruns, fd)
fd.close()
