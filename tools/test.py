#!/usr/bin/env python
# -*- coding: UTF-8 -*-

import argparse
import collections
import concurrent.futures
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
import threading
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
            self._api_instance = None
            self._func = None
            self._kwargs = None
            self._watch = kubernetes.watch.Watch()
        else:
            assert os.path.isreadable(self.args.load_events_file)

        # If we are supposed to dump events, prepare file
        if self.args.dump_events_file is not None:
            self._dump_events_fd = open("data.json", "w")

    ###def _create_iterator(self):
    ###    if self.args.load_events_file is None:
    ###        return iter(self._watch.stream(self._func, **self._kwargs))
    ###    else:
    ###        return iter(open(self.args.load_events_file, "r"))

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


class PRsEventsWatcher(EventsWatcher):

    def __init__(self, args):
        super().__init__(args)
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


class TRsEventsWatcher(EventsWatcher):

    def __init__(self, args):
        super().__init__(args)
        self._api_instance = kubernetes.client.CustomObjectsApi()
        self._func = self._api_instance.list_namespaced_custom_object
        self._kwargs = {
            "group": "tekton.dev",
            "version": "v1",
            "namespace": "benchmark",
            "plural": "taskruns",
            "pretty": False,
            "limit": 10,
            "timeout_seconds": 100,   # server timeout
            "_request_timeout": 100,   # client timeout
        }


def process_events_thread(watcher, data, lock):
    for event in watcher:
        ###logging.debug(f"Processing event: {json.dumps(event)}")
        try:
            e_name = find("object.metadata.name", event)
        except KeyError as e:
            logging.warning(f"Missing name in {json.dumps(event)}: {e} => skipping it")
            continue

        with lock:
            # Collect timestamps if we do not have it already
            for path in ["object.metadata.creationTimestamp", "object.status.startTime", "object.status.completionTime"]:
                name = path.split(".")[-1]
                if name not in data[e_name]:
                    try:
                        response = find(path, event)
                    except KeyError:
                        pass
                    else:
                        data[e_name][name] = response

            # Determine state and possibly outcome
            try:
                conditions = find("object.status.conditions", event)
            except KeyError:
                data[e_name]["state"] = "pending"
            else:
                if conditions[0]["status"] == "Unknown":
                    data[e_name]["state"] = "running"
                elif conditions[0]["status"] != "Unknown":
                    data[e_name]["state"] = "finished"

                    if conditions[0]["type"] == "Succeeded":
                        if conditions[0]["status"] == "True" and conditions[0]["reason"] == "Succeeded":
                            data[e_name]["outcome"] = "succeeded"
                        elif conditions[0]["status"] != "True" and conditions[0]["reason"] != "Succeeded":
                            data[e_name]["outcome"] = "failed"
                        else:
                            data[e_name]["outcome"] = "unknown"

            # Determine signature
            try:
                annotations = find("object.metadata.annotations", event)
            except KeyError:
                if "signed" not in data[e_name]:
                    data[e_name]["signed"] = "unknown"
            else:
                if "chains.tekton.dev/signed" in annotations:
                    data[e_name]["signed"] = annotations["chains.tekton.dev/signed"]


def counter_thread(args, pipelineruns, pipelineruns_lock, taskruns, taskruns_lock):
    while True:
        with pipelineruns_lock:
            total = len(pipelineruns)
            finished = len([i for i in pipelineruns.values() if i["state"] == "finished"])
            running = len([i for i in pipelineruns.values() if i["state"] == "running"])
            pending = len([i for i in pipelineruns.values() if i["state"] == "pending"])
            if args.concurrent > 0:
                should_be_started = min(args.concurrent - running - pending, args.total - total)
            else:
                should_be_started = 0
            signed_true = len([i for i in pipelineruns.values() if "signed" in i and i["signed"] == "true"])
            signed_false = len([i for i in pipelineruns.values() if "signed" in i and i["signed"] == "false"])
            prs = {"finished": finished, "running": running, "pending": pending, "total": total, "should_be_started": should_be_started, "signed_true": signed_true, "signed_false": signed_false}

        with taskruns_lock:
            total = len(taskruns)
            finished = len([i for i in taskruns.values() if i["state"] == "finished"])
            running = len([i for i in taskruns.values() if i["state"] == "running"])
            pending = len([i for i in taskruns.values() if i["state"] == "pending"])
            signed_true = len([i for i in taskruns.values() if "signed" in i and i["signed"] == "true"])
            signed_false = len([i for i in taskruns.values() if "signed" in i and i["signed"] == "false"])
            trs = {"finished": finished, "running": running, "pending": pending, "total": total, "should_be_started": should_be_started, "signed_true": signed_true, "signed_false": signed_false}

        logging.info(f"{now().isoformat()} PipelineRuns: {json.dumps(prs)}, TaskRuns: {json.dumps(trs)}")

        if prs["total"] >= args.total:
            return

        time.sleep(10)


def doit(args):
    pipelineruns = collections.defaultdict(dict)
    pipelineruns_lock = threading.Lock()
    pipelineruns_watcher = PRsEventsWatcher(args)

    taskruns = collections.defaultdict(dict)
    taskruns_lock = threading.Lock()
    taskruns_watcher = TRsEventsWatcher(args)

    with concurrent.futures.ThreadPoolExecutor() as executor:
        pipelineruns_future = executor.submit(process_events_thread, pipelineruns_watcher, pipelineruns, pipelineruns_lock)
        print(pipelineruns_future)
        taskruns_future = executor.submit(process_events_thread, taskruns_watcher, taskruns, taskruns_lock)
        print(taskruns_future)
        counter_future = executor.submit(counter_thread, args, pipelineruns, pipelineruns_lock, taskruns, taskruns_lock)
        print(counter_future)
    #    if total >= args.total:
    #        print("DONE")
    #        break

    r = counter_future.result()
    pipelineruns_future.cancel()
    taskruns_future.cancel()
    print(r)

    with open(args.output_file, "w") as fd:
        json.dump(pipelineruns, fd)


def main():
    parser = argparse.ArgumentParser(
        prog="Tekton monitoring and benchmark test",
        description="Track number of running PipelineRuns and TaskRuns and optionally keep given paralelism",
    )
    parser.add_argument(
        "--concurrent",
        help="How many concurrent PipelineRuns to run? Defaults to 0 meaning we will not start more PRs.",
        default=0,
        type=int,
    )
    parser.add_argument(
        "--total",
        help="Quit once there is this many PipelineRuns.",
        default=100,
        type=int,
    )
    parser.add_argument(
        "--run",
        help="PipelineRun file. Only relevant if we are going to start more PipelineRuns (see --concurrent option).",
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
