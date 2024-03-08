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
import threading
import urllib3
import yaml


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
    keys = path.split(".")
    rv = data
    for key in keys:
        rv = rv[key]
    return rv


class DateTimeEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, datetime.datetime):
            return o.isoformat()

        return json.JSONEncoder.default(self, o)


class EventsWatcher:

    def __init__(self, args, stop_event):
        """
        Watch indefinetely.
        """
        self.logger = logging.getLogger(self.__class__.__name__)
        self.args = args
        self.stop_event = stop_event
        self.counter = 0  # how many event we have returned

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

    def _safe_stream(self):
        """
        Iterate through events, skipping these without resource version.
        If watch just ends (no more events), retry it.
        Catch unimportant issues and retries as needed.
        """
        while True:
            if self.stop_event.is_set():
                self.logger.info("Was asked to stop, bye!")
                return

            try:

                iterator = self._watch.stream(self._func, **self._kwargs)
                while True:
                    event = next(iterator, None)

                    # If there are no new events, check if we are supposed to quit and if not, check events queue again
                    if event is None:
                        if self.stop_event.is_set():
                            self.logger.info("Was asked to stop, bye!")
                            return

                        time.sleep(0.1)
                        continue

                    # Remember resource_version if it is there, if it is missing, ignore event.
                    try:
                        self._kwargs["resource_version"] = event["object"]["metadata"][
                            "resourceVersion"
                        ]
                    except KeyError as e:
                        self.logger.warning(
                            f"Missing resource version in {json.dumps(e)} => skipping it"
                        )
                        continue

                    yield event

                self.logger.warning(
                    f"Watch ended (last resource version {self._kwargs['resource_version']}), retrying"
                )

            except kubernetes.client.exceptions.ApiException as e:

                if e.status == 410:  # Resource too old
                    e_text = str(e).replace("\n", "")
                    self.logger.warning(
                        f"Watch failed with: {e_text}, resetting resource_version"
                    )
                    self._kwargs["resource_version"] = None
                else:
                    raise

            except (
                urllib3.exceptions.ReadTimeoutError,
                urllib3.exceptions.ProtocolError,
            ) as e:
                logging.warning(f"Watch failed with: {e}, retrying")

    def __iter__(self):
        if self.args.load_events_file is None:
            self.iterator = iter(self._safe_stream())
        else:
            self.iterator = iter(open(self.args.load_events_file, "r"))
        return self

    def __next__(self):
        while True:
            event = next(self.iterator, None)
            if event is None:
                # No data, let's check if we are supposed to quit.
                if self.stop_event.is_set():
                    self.logger.info("Was asked to stop, bye!")
                    raise StopIteration("Was asked to stop, bye!")

                time.sleep(0.1)
                continue
            else:
                # We have the data, yay! Let's go on.
                break

        if self.args.dump_events_file is not None:
            self._dump_events_fd.write(json.dumps(event) + "\n")

        self.counter += 1

        return event


class PRsEventsWatcher(EventsWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._api_instance = kubernetes.client.CustomObjectsApi()
        self._func = self._api_instance.list_namespaced_custom_object
        self._kwargs = {
            "group": "tekton.dev",
            "version": "v1",
            "namespace": "benchmark",
            "plural": "pipelineruns",
            "pretty": False,
            "limit": 10,
            "timeout_seconds": 10,  # server timeout
            "_request_timeout": 10,  # client timeout
        }


class TRsEventsWatcher(EventsWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._api_instance = kubernetes.client.CustomObjectsApi()
        self._func = self._api_instance.list_namespaced_custom_object
        self._kwargs = {
            "group": "tekton.dev",
            "version": "v1",
            "namespace": "benchmark",
            "plural": "taskruns",
            "pretty": False,
            "limit": 10,
            "timeout_seconds": 10,  # server timeout
            "_request_timeout": 10,  # client timeout
        }


def process_events_thread(watcher, data, lock):
    for event in watcher:
        logging.debug(f"Processing event: {json.dumps(event)[:100]}...")
        try:
            e_name = find("object.metadata.name", event)
        except KeyError as e:
            logging.warning(f"Missing name in {json.dumps(event)}: {e} => skipping it")
            continue

        with lock:
            # Collect timestamps if we do not have it already
            for path in [
                "object.metadata.creationTimestamp",
                "object.status.startTime",
                "object.status.completionTime",
            ]:
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
                        if (
                            conditions[0]["status"] == "True"
                            and conditions[0]["reason"] == "Succeeded"
                        ):
                            data[e_name]["outcome"] = "succeeded"
                        elif (
                            conditions[0]["status"] != "True"
                            and conditions[0]["reason"] != "Succeeded"
                        ):
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


class PropagatingThread(threading.Thread):
    def run(self):
        self.exc = None
        try:
            # Need this on Python 2
            # self.ret = self._Thread__target(*self._Thread__args, **self._Thread__kwargs)
            self.ret = self._target(*self._args, **self._kwargs)
        except BaseException as e:
            self.exc = e

    def join(self, timeout=None):
        super(PropagatingThread, self).join(timeout)
        if self.exc:
            raise RuntimeError("Exception in thread") from self.exc
        return self.ret


def start_pipelinerun_thread(body):
    logging.debug("Starting PipelineRun creation")
    kubernetes.config.load_kube_config()
    api_instance = kubernetes.client.CustomObjectsApi()
    kwargs = {
        "group": "tekton.dev",
        "version": "v1beta1",
        "namespace": "benchmark",
        "plural": "pipelineruns",
        "_request_timeout": 300,  # client timeout
    }
    response = api_instance.create_namespaced_custom_object(body=body, **kwargs)
    logging.debug(f"Created PipelineRun: {json.dumps(response)[:100]}...")


def counter_thread(
    args, pipelineruns, pipelineruns_lock, taskruns, taskruns_lock, stop_event
):
    monitoring_start = now()
    started_prs_worked = 0
    started_prs_failed = 0

    if args.concurrent > 0:
        with open(args.run, "r") as fd:
            run_to_start = yaml.load(fd, Loader=yaml.Loader)

    while True:
        monitoring_now = now()
        monitoring_second = (monitoring_now - monitoring_start).total_seconds()

        with pipelineruns_lock:
            total = len(pipelineruns)
            finished = len(
                [i for i in pipelineruns.values() if i["state"] == "finished"]
            )
            running = len([i for i in pipelineruns.values() if i["state"] == "running"])
            pending = len([i for i in pipelineruns.values() if i["state"] == "pending"])
            signed_true = len(
                [
                    i
                    for i in pipelineruns.values()
                    if "signed" in i and i["signed"] == "true"
                ]
            )
            signed_false = len(
                [
                    i
                    for i in pipelineruns.values()
                    if "signed" in i and i["signed"] == "false"
                ]
            )
        prs = {
            "monitoring_start": monitoring_start,
            "monitoring_now": monitoring_now,
            "monitoring_second": monitoring_second,
            "finished": finished,
            "running": running,
            "pending": pending,
            "total": total,
            "signed_true": signed_true,
            "signed_false": signed_false,
        }

        if args.concurrent > 0:
            _remaining = max(
                0, args.total - total
            )  # avoid negative number if there is more PRs than what was asked on commandline
            _needed = args.concurrent - running - pending
            prs["should_be_started"] = min(_needed, _remaining)
        else:
            prs["should_be_started"] = 0

        with taskruns_lock:
            total = len(taskruns)
            finished = len([i for i in taskruns.values() if i["state"] == "finished"])
            running = len([i for i in taskruns.values() if i["state"] == "running"])
            pending = len([i for i in taskruns.values() if i["state"] == "pending"])
            signed_true = len(
                [
                    i
                    for i in taskruns.values()
                    if "signed" in i and i["signed"] == "true"
                ]
            )
            signed_false = len(
                [
                    i
                    for i in taskruns.values()
                    if "signed" in i and i["signed"] == "false"
                ]
            )
        trs = {
            "monitoring_start": monitoring_start,
            "monitoring_now": monitoring_now,
            "monitoring_second": monitoring_second,
            "finished": finished,
            "running": running,
            "pending": pending,
            "total": total,
            "signed_true": signed_true,
            "signed_false": signed_false,
        }

        if monitoring_second > args.delay and prs["should_be_started"] > 0:
            logging.debug(f"Starting {prs['should_be_started']} threads")
            creation_threads = set()
            for _ in range(prs["should_be_started"]):
                future = PropagatingThread(
                    target=start_pipelinerun_thread, args=[run_to_start]
                )
                future.start()
                creation_threads.add(future)
            for future in creation_threads:
                try:
                    future.join()
                except:
                    logging.exception("PipelineRun creation failed")
                    started_prs_failed += 1
                else:
                    started_prs_worked += 1
            prs["started_prs_worked"] = started_prs_worked
            prs["started_prs_failed"] = started_prs_failed

        logging.info(f"PipelineRuns: {json.dumps(prs, cls=DateTimeEncoder)}")
        logging.info(f"TaskRuns: {json.dumps(trs, cls=DateTimeEncoder)}")

        if prs["total"] >= args.total:
            stop_event.set()
            logging.info("We are done, asking watcher threads to stop")
            return

        time.sleep(args.delay)


def doit(args):
    stop_event = threading.Event()

    pipelineruns = collections.defaultdict(dict)
    pipelineruns_lock = threading.Lock()
    pipelineruns_watcher = PRsEventsWatcher(args=args, stop_event=stop_event)

    taskruns = collections.defaultdict(dict)
    taskruns_lock = threading.Lock()
    taskruns_watcher = TRsEventsWatcher(args=args, stop_event=stop_event)

    pipelineruns_future = PropagatingThread(
        target=process_events_thread,
        args=[pipelineruns_watcher, pipelineruns, pipelineruns_lock],
    )
    pipelineruns_future.name = "pipelineruns_watcher"
    pipelineruns_future.start()
    taskruns_future = PropagatingThread(
        target=process_events_thread, args=[taskruns_watcher, taskruns, taskruns_lock]
    )
    taskruns_future.name = "taskruns_watcher"
    taskruns_future.start()
    counter_future = PropagatingThread(
        target=counter_thread,
        args=[
            args,
            pipelineruns,
            pipelineruns_lock,
            taskruns,
            taskruns_lock,
            stop_event,
        ],
    )
    counter_future.name = "counter_thread"
    counter_future.start()

    try:
        counter_future.join()
    except:
        logging.exception("Counter thread failed, asking watcher threads to stop")
        stop_event.set()  # let other threads to stop as well

    pipelineruns_future.join()
    taskruns_future.join()

    with open(args.output_file, "w") as fd:
        json.dump({"pipelineruns": pipelineruns, "taskruns": taskruns}, fd)


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
        "--delay",
        help="How many seconds to wait between reconciliation loops.",
        default=10,
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
            requests.packages.urllib3.disable_warnings(
                requests.packages.urllib3.exceptions.InsecureRequestWarning
            )
        else:
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    return doit(args)


if __name__ == "__main__":
    sys.exit(main())
