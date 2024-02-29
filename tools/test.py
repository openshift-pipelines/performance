#!/usr/bin/env python
# -*- coding: UTF-8 -*-

import argparse
import collections
import datetime
import json
import kubernetes
import kubernetes.client.exceptions
import logging
import logging.handlers
import os
import pkg_resources
import requests
import sys
import time
import urllib3


def setup_logger(stderr_log_lvl, log_file):
    """
    Create logger that logs to both stderr and log file but with different log level
    """
    # Remove all handlers from root logger if any
    logging.basicConfig(level=logging.NOTSET, handlers=[])
    # Change root logger level from WARNING (default) to NOTSET in order for all messages to be delegated.
    logging.getLogger().setLevel(logging.NOTSET)

    # Log message format
    formatter = logging.Formatter(
        "%(asctime)s %(name)s %(processName)s %(threadName)s %(levelname)s %(message)s"
    )
    formatter.converter = time.gmtime

    # Add stderr handler, with level INFO
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    console.setLevel(stderr_log_lvl)
    logging.getLogger("root").addHandler(console)

    # Add file rotating handler, with level DEBUG
    rotating_handler = logging.handlers.RotatingFileHandler(
        filename=log_file,
        maxBytes=100 * 1000,
        backupCount=2,
    )
    rotating_handler.setLevel(logging.DEBUG)
    rotating_handler.setFormatter(formatter)
    logging.getLogger().addHandler(rotating_handler)

    return logging.getLogger("root")


def now():
    if "UTC" in dir(datetime):
        return datetime.datetime.now(datetime.UTC)
    else:
        # Older Python workaround
        return datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)


def find(path, data):
    # Thanks https://stackoverflow.com/questions/31033549/nested-dictionary-value-from-key-path
    keys = path.split('.')
    rv = data
    for key in keys:
        rv = rv[key]
    return rv


class EventsWatcher():

    def __init__(self, args):
        """
        Watch indefinetely.
        """
        self.logger = logging.getLogger(self.__class__.__name__)
        self.args = args
        self.counter = 0   # how many event we have returned

        # Either we will process events from OCP cluster or from file (for debugging)
        if self.args.load_events_file is None:
            kubernetes.config.load_kube_config()
            self._api_instance = kubernetes.client.CustomObjectsApi()
            self._func = self._api_instance.list_namespaced_custom_object
            self._kwargs = {
                "group": "tekton.dev",
                "version": "v1",
                "namespace": "benchmark",
                "plural": "pipelineruns",
                "pretty": False,
                "limit": 10,
                "timeout_seconds": 100,   # server timeout
                "_request_timeout": 100,   # client timeout
            }
            self._watch = kubernetes.watch.Watch()
        else:
            assert os.path.isreadable(self.args.load_events_file)

        # If we are supposed to dump events, prepare file
        if self.args.dump_events_file is not None:
            self._dump_events_fd = open("data.json", "w")

    def _create_iterator(self):
        if self.args.load_events_file is None:
            return iter(self._watch.stream(self._func, **self._kwargs))
        else:
            return iter(open(self.args.load_events_file, "r"))

    def _safe_stream_retry(self):
        """
        Iterate through events, skipping these without resource version.
        If watch just ends (no more events), retry it.
        """
        while True:
            for event in self._watch.stream(self._func, **self._kwargs):
                try:
                    self._kwargs["resource_version"] = event["object"]["metadata"]["resourceVersion"]
                except KeyError as e:
                    self.logger.warning(f"Missing resource version in {json.dumps(e)} => skipping it")
                    continue
                yield event

            self.logger.warning(f"Watch failed (last resource version {self._kwargs['resource_version']}), retrying")

    def _safe_stream(self):
        """
        Catch unimportant issues and retries as needed.
        """
        while True:
            try:
                for event in self._safe_stream_retry():
                    yield event
            except kubernetes.client.exceptions.ApiException as e:
                if e.status == 410:   # Resource too old
                    e_text = str(e).replace("\n", "")
                    self.logger.warning(f"Watch failed with: {e_text}, resetting resource_version")
                    self._kwargs["resource_version"] = None
                else:
                    raise
            except (urllib3.exceptions.ReadTimeoutError, urllib3.exceptions.ProtocolError) as e:
                logging.warning(f"Watch failed with: {e}, retrying")

    def __iter__(self):
        if self.args.load_events_file is None:
            self.iterator = iter(self._safe_stream())
        else:
            self.iterator = iter(open(self.args.load_events_file, "r"))
        return self

    def __next__(self):
        event = next(self.iterator)

        if self.args.dump_events_file is not None:
            self._dump_events_fd.write(json.dumps(event) + "\n")

        self.counter += 1

        return event


def doit(args):
    pipelineruns = collections.defaultdict(dict)

    events_watcher = EventsWatcher(args)
    for event in events_watcher:
        try:
            pr_name = find("object.metadata.name", event)
        except KeyError as e:
            logging.warning(f"Missing name in {json.dumps(event)}: {e} => skipping it")
            continue

        # Collect timestamps if we do not have it already
        for path in ["object.metadata.creationTimestamp", "object.status.startTime", "object.status.completionTime"]:
            name = path.split(".")[-1]
            if name not in pipelineruns[pr_name]:
                try:
                    response = find(path, event)
                except KeyError:
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

        # Determine signature
        try:
            annotations = find("object.metadata.annotations", event)
        except KeyError:
            if "signed" not in pipelineruns[pr_name]:
                pipelineruns[pr_name]["signed"] = "unknown"
        else:
            if "chains.tekton.dev/signed" in annotations:
                pipelineruns[pr_name]["signed"] = annotations["chains.tekton.dev/signed"]

        # Count some stats
        total = len(pipelineruns)
        if events_watcher.counter % 100 == 0:
            finished = len([i for i in pipelineruns.values() if i["state"] == "finished"])
            running = len([i for i in pipelineruns.values() if i["state"] == "running"])
            pending = len([i for i in pipelineruns.values() if i["state"] == "pending"])
            should_be_started = min(args.concurrent - running - pending, args.total - total)
            signed_true = len([i for i in pipelineruns.values() if "signed" in i and i["signed"] == "true"])
            signed_false = len([i for i in pipelineruns.values() if "signed" in i and i["signed"] == "false"])
            print({"finished": finished, "running": running, "pending": pending, "total": total, "should_be_started": should_be_started, "signed_true": signed_true, "signed_false": signed_false})

        if total >= args.total:
            print("DONE")
            break

    with open(args.output_file, "w") as fd:
        json.dump(pipelineruns, fd)


def main():
    parser = argparse.ArgumentParser(
        prog="Tekton benchmark test",
        description="Track number of running PipelineRuns TODO",
    )
    parser.add_argument(
        "--concurrent",
        help="How many concurrent PipelineRuns to run?",
        default=10,
        type=int,
    )
    parser.add_argument(
        "--total",
        help="How many PipelineRuns to to create?",
        default=100,
        type=int,
    )
    parser.add_argument(
        "--run",
        help="PipelineRun file",
        type=str,
    )
    parser.add_argument(
        "--stats-file",
        help="File where we will keep adding stats",
        default="/tmp/benchmark-tekton.csv",
        type=str,
    )
    parser.add_argument(
        "--output-file",
        help="File where to dump final data",
        default="/tmp/benchmark-tekton.json",
        type=str,
    )
    parser.add_argument(
        "--log-file",
        help="Log file (will be rotated if needed)",
        default="/tmp/benchmark-tekton.log",
        type=str,
    )
    parser.add_argument(
        "--dump-events-file",
        help="File where to dump events as they are comming (for debugging)",
        default=None,
        type=str,
    )
    parser.add_argument(
        "--load-events-file",
        help="File where to load events from instead of OCP cluster (for debugging)",
        default=None,
        type=str,
    )
    parser.add_argument(
        "--insecure",
        help="Disable 'InsecureRequestWarning' warnings",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Verbose output",
        action="store_true",
    )
    parser.add_argument(
        "-d",
        "--debug",
        help="Debug output",
        action="store_true",
    )
    args = parser.parse_args()

    if args.debug:
        logger = setup_logger(logging.DEBUG, args.log_file)
    elif args.verbose:
        logger = setup_logger(logging.INFO, args.log_file)
    else:
        logger = setup_logger(logging.WARNING, args.log_file)

    logger.debug(f"Args: {args}")

    if args.insecure:
        # https://stackoverflow.com/questions/27981545/suppress-insecurerequestwarning-unverified-https-request-is-being-made-in-pytho
        requests_version = pkg_resources.parse_version(requests.__version__)
        border_version = pkg_resources.parse_version("2.16.0")
        if requests_version < border_version:
            requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)
        else:
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    return doit(args)


if __name__ == "__main__":
    sys.exit(main())
