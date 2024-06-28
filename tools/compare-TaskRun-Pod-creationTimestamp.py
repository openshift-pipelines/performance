#!/usr/bin/env python

## TODO: Rework on this script to consider benchmark-output.json as input with pod.json (need to be captured from the point when tests are executed) 

import argparse
import datetime
import json
import logging
import sys
import time
import yaml

import opl.skelet
import opl.data


def str2date(date_str):
    date_str = date_str.replace("Z", "+00:00")
    ###return datetime.datetime.fromisoformat(date_str)
    return datetime.datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S+00:00")


def load_file(fd):
    start = time.perf_counter()
    if fd.name.endswith(".yaml") or fd.name.endswith(".yml"):
        data = yaml.safe_load(fd)
    elif fd.name.endswith(".json"):
        data = json.load(fd)
    else:
        raise Exception(f"I do not know how to load {fd.name}")
    end = time.perf_counter()
    logging.debug(f"Loaded {fd.name} in {(end - start):.2f} seconds")
    return data


def doit(args, status_data):
    logging.info(f"Processing {args.taskruns_list.name}")
    data_taskruns = {}
    for i in load_file(args.taskruns_list)["items"]:
        try:
            # TaskRun Names can be duplicate across multiples namespaces
            # Combine namespace+taskrun name to generate unique name
            tr_namespace = i["metadata"]["namespace"]
            tr_name = f'{tr_namespace}.{i["metadata"]["name"]}'
            tr_creationTimestamp = i["metadata"]["creationTimestamp"]
            tr_podName = f'{tr_namespace}.{i["status"]["podName"]}'
        except KeyError as e:
            logging.warning(f"Missing key details in taskruns list: {e}")
            continue

        assert tr_name not in data_taskruns

        data_taskruns[tr_name] = {
            "creationTimestamp": tr_creationTimestamp,
            "podName": tr_podName,
        }

    logging.info(f"Processing {args.pods_list.name}")
    data_pods = {}
    for i in load_file(args.pods_list)["items"]:
        try:
            # Generate unique pod name to avoid duplicates across multi-namespace
            pod_namespace = i["metadata"]["namespace"]
            pod_name = f'{pod_namespace}.{i["metadata"]["name"]}'
            pod_tr_name = f'{pod_namespace}.{i["metadata"]["labels"]["tekton.dev/taskRun"]}'
            pod_creationTimestamp = i["metadata"]["creationTimestamp"]
        except KeyError as e:
            logging.warning(f"Missing key details in pods list: {e}")
            continue

        assert pod_name not in data_pods

        data_pods[pod_name] = {
            "taskRun": pod_tr_name,
            "creationTimestamp": pod_creationTimestamp,
        }

    logging.info("Computing creationTimestamp diff")
    durations = []
    for tr_name, tr_data in data_taskruns.items():
        try:
            pod_data = data_pods[tr_data["podName"]]
        except KeyError as e:
            logging.warning(f"Missing pod {tr_data['podName']}, skipping")
            continue

        assert pod_data["taskRun"] == tr_name

        duration = str2date(pod_data["creationTimestamp"]) - str2date(
            tr_data["creationTimestamp"]
        )
        durations.append(duration.total_seconds())

    logging.info("Saving result")
    status_data.set(
        "results.TaskRuns_to_Pods.creationTimestamp_diff",
        opl.data.data_stats(durations),
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare TaskRun creationTimestamp -> Pod creationTimestamp",  # noqa:E501
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--taskruns-list",
        type=argparse.FileType("r"),
        required=True,
        help="File with TaskRuns",
    )
    parser.add_argument(
        "--pods-list",
        type=argparse.FileType("r"),
        required=True,
        help="File with Pods",
    )
    with opl.skelet.test_setup(parser) as (args, status_data):
        return doit(args, status_data)


if __name__ == "__main__":
    sys.exit(main())
