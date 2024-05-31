#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import argparse
import collections
import csv
import datetime
import json
import kubernetes
import kubernetes.client.exceptions
import logging
import logging.handlers
import os
import queue
import pkg_resources
import requests
import sys
import time
import threading
import urllib3
import yaml

# Constants Flags and Parameters
TOTAL_RUN__FOR__WAIT_FOR_DURAITON_FLAG = 1_000_000
NAMESPACE_NAME_FORMAT = "benchmark{idx}"


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
        self._buffer = queue.Queue()

        kubernetes.config.load_kube_config()
        self._api_instance = None
        self._func = None
        self._kwargs = None
        self._watch = kubernetes.watch.Watch()

    def stop(self):
        self.logger.info("We were asked to stop")
        self.stop_event.set()
        self._watch.stop()

    def _safe_stream(self):
        """
        Iterate through events, skipping these without resource version.
        If watch just ends (no more events), retry it.
        Catch unimportant issues and retries as needed.
        """
        while True:
            try:

                # First list all
                self.logger.info("Starting list all stream")
                _newest = None
                for event in self._func(**self._kwargs)["items"]:
                    try:
                        _completion_time = event["status"]["completionTime"]
                        _resource_version = event["metadata"]["resourceVersion"]
                    except KeyError:
                        continue
                    else:
                        if (
                            _newest is None or _newest <= _completion_time
                        ):  # comparing strings, yay!
                            _newest = _completion_time
                            self._kwargs["resource_version"] = _resource_version

                    yield {"type": "MY_INITIAL_SYNC", "object": event}

                # Now start watching
                self.logger.info("Starting watch stream")
                for event in self._watch.stream(self._func, **self._kwargs):
                    # Remember resource_version if it is there, if it is missing, ignore event.
                    try:
                        self._kwargs["resource_version"] = event["object"]["metadata"][
                            "resourceVersion"
                        ]
                    except KeyError:
                        self.logger.warning(
                            f"Missing resource version in {json.dumps(event)} => skipping it"
                        )
                        continue

                    yield event

                self.logger.info("Watch stream finished")

                if self.stop_event.is_set():
                    self.logger.info("Was asked to stop, bye!")
                    return
                else:
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

    def _buffered_iterator(self):
        my_iterator = self._safe_stream()
        try:
            while True:
                self._buffer.put(next(my_iterator))
                if self.stop_event.is_set():
                    raise StopIteration("Quitting detached iterator on request")
        except BaseException as e:
            self._buffer.put(e)

    def __iter__(self):
        # Having actual iterator in standalone thread, putting data to the queue
        # and then locally just reading from the queue allows us to kill
        # the iterator when needed. Idea comes from this timeout_iterator code:
        # https://github.com/leangaurav/pypi_iterator/blob/main/iterators/timeout_iterator.py
        self.iterator_thread = threading.Thread(
            target=self._buffered_iterator, daemon=True
        )
        self.iterator_thread.start()
        return self

    def __next__(self):
        if self.stop_event.is_set():
            raise StopIteration("Quitting on request")

        try:
            event = self._buffer.get(timeout=0.1)
        except queue.Empty:
            event = None
        else:
            self.counter += 1

        # Propagate any exceptions including StopIteration
        if isinstance(event, BaseException):
            self.stop()
            raise event

        return event


class PRsEventsWatcher(EventsWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._api_instance = kubernetes.client.CustomObjectsApi()
        self._func = self._api_instance.list_namespaced_custom_object
        self._kwargs = {
            "group": "tekton.dev",
            "version": "v1",
            "namespace": "",
            "plural": "pipelineruns",
            "pretty": False,
            "limit": 500,
            "timeout_seconds": 10800,  # server timeout
            "_request_timeout": 600,  # client timeout
        }


class TRsEventsWatcher(EventsWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._api_instance = kubernetes.client.CustomObjectsApi()
        self._func = self._api_instance.list_namespaced_custom_object
        self._kwargs = {
            "group": "tekton.dev",
            "version": "v1",
            "namespace": "",
            "plural": "taskruns",
            "pretty": False,
            "limit": 500,
            "timeout_seconds": 10800,  # server timeout
            "_request_timeout": 600,  # client timeout
        }


def process_events_thread(watcher, data, lock):
    for event in watcher:
        if event is None:
            continue

        logging.debug(f"Processing event: {json.dumps(event)[:100]}...")

        try:
            e_name = find("object.metadata.name", event)
        except KeyError as e:
            logging.warning(f"Missing name in {json.dumps(event)}: {e} => skipping it")
            continue

        with lock:
            # Collect metadata and timestamps if we do not have it already
            for path in [
                "object.metadata.namespace",
                "object.metadata.creationTimestamp",
                "object.metadata.deletionTimestamp",
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

                    if "finished_at" not in data[e_name]:
                        data[e_name]["finished_at"] = now()

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

            # Determine finalizers
            # PRs: chains.tekton.dev/pipelinerun
            # TRs: chains.tekton.dev
            try:
                finalizers = find("object.metadata.finalizers", event)
            except KeyError:
                if "finalizer" not in data[e_name]:
                    data[e_name]["finalizers"] = None
            else:
                if "finalizers_at" not in data[e_name]:
                    data[e_name]["finalizers_at"] = now()
                if (
                    "chains.tekton.dev/pipelinerun" in finalizers
                    or "chains.tekton.dev" in finalizers
                ):
                    data[e_name]["finalizers"] = True
                else:
                    data[e_name]["finalizers"] = False

            # Determine signature
            try:
                annotations = find("object.metadata.annotations", event)
            except KeyError:
                if "signed" not in data[e_name]:
                    data[e_name]["signed"] = "unknown"
            else:
                if "chains.tekton.dev/signed" in annotations:
                    if "signed_at" not in data[e_name]:
                        data[e_name]["signed_at"] = now()
                    data[e_name]["signed"] = annotations["chains.tekton.dev/signed"]

            # Determine deleted status
            if event["type"] == "DELETED":
                data[e_name]["deleted"] = True
                if "deleted_at" not in data[e_name]:
                    data[e_name]["deleted_at"] = now()
            else:
                data[e_name]["deleted"] = False

            # Determine terminated status
            if "deletionTimestamp" in data[e_name]:
                data[e_name]["terminated"] = True
            else:
                data[e_name]["terminated"] = False


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


def start_pipelinerun_thread(body, namespace):
    logging.debug("Starting PipelineRun creation")
    kubernetes.config.load_kube_config()
    api_instance = kubernetes.client.CustomObjectsApi()
    kwargs = {
        "group": "tekton.dev",
        "version": "v1",
        "namespace": namespace,
        "plural": "pipelineruns",
        "_request_timeout": 300,  # client timeout
    }
    response = api_instance.create_namespaced_custom_object(body=body, **kwargs)
    logging.debug(f"Created PipelineRun: {json.dumps(response)[:100]}...")


def fetch_current_concurrency(value):
    # Check if the value is a number
    if value.isdigit():
        return int(value)
    # Check if the value is a valid file path
    if os.path.isfile(value):
        with open(value, "r") as file:
            contents = file.read().strip()
        if contents.isdigit():
            return int(contents)
        else:
            logging.error(f"File '{value}' does not contain a valid integer")


def counter_thread(args, pipelineruns, pipelineruns_lock, taskruns, taskruns_lock):
    monitoring_start = now()
    started_worked = 0
    started_failed = 0

    # Used to check if --wait-for-state has reached across all namespaces
    namespace_wait_for_state_completed = set()

    if fetch_current_concurrency(args.concurrent) > 0:
        with open(args.run, "r") as fd:
            run_to_start = yaml.load(fd, Loader=yaml.Loader)

    while True:
        for namespace_idx in range(1, args.namespace + 1):
            monitoring_now = now()
            monitoring_second = (monitoring_now - monitoring_start).total_seconds()

            namespace = NAMESPACE_NAME_FORMAT.format(idx=str(namespace_idx))
            # Use "benchmark" as default namespace to handle backward compatibility for test-scenarios
            if args.namespace == 1:
                namespace = NAMESPACE_NAME_FORMAT.format(idx="")

            with pipelineruns_lock:
                namespaced_pipelineruns = [
                    i for i in pipelineruns.values() if i["namespace"] == namespace
                ]
                total = len(namespaced_pipelineruns)
                finished = len(
                    [i for i in namespaced_pipelineruns if i["state"] == "finished"]
                )
                running = len(
                    [i for i in namespaced_pipelineruns if i["state"] == "running"]
                )
                failed = len(
                    [i for i in namespaced_pipelineruns if "outcome" in i and i["outcome"] == "failed"]
                )
                pending = len(
                    [i for i in namespaced_pipelineruns if i["state"] == "pending"]
                )
                signed_true = len(
                    [
                        i
                        for i in namespaced_pipelineruns
                        if "signed" in i and i["signed"] == "true"
                    ]
                )
                signed_false = len(
                    [
                        i
                        for i in namespaced_pipelineruns
                        if "signed" in i and i["signed"] == "false"
                    ]
                )
                finalizers_present = len(
                    [i for i in namespaced_pipelineruns if i["finalizers"] is True]
                )
                finalizers_absent = len(
                    [i for i in namespaced_pipelineruns if i["finalizers"] is False]
                )
                deleted = len(
                    [i for i in namespaced_pipelineruns if i["deleted"] is True]
                )
                terminated = len(
                    [i for i in namespaced_pipelineruns if i["terminated"] is True]
                )
            prs = {
                "monitoring_start": monitoring_start,
                "monitoring_now": monitoring_now,
                "monitoring_second": monitoring_second,
                "finished": finished,
                "running": running,
                "failed": failed,
                "pending": pending,
                "total": total,
                "signed_true": signed_true,
                "signed_false": signed_false,
                "finalizers_present": finalizers_present,
                "finalizers_absent": finalizers_absent,
                "deleted": deleted,
                "terminated": terminated,
            }

            if fetch_current_concurrency(args.concurrent) > 0:
                _remaining = max(
                    0, args.total - total
                )  # avoid negative number if there is more PRs than what was asked on commandline
                _needed = fetch_current_concurrency(args.concurrent) - running - pending
                prs["should_be_started"] = min(_needed, _remaining)
            else:
                prs["should_be_started"] = 0

            with taskruns_lock:
                namespaced_taskruns = [
                    i for i in taskruns.values() if i["namespace"] == namespace
                ]
                total = len(namespaced_taskruns)
                finished = len(
                    [i for i in namespaced_taskruns if i["state"] == "finished"]
                )
                running = len(
                    [i for i in namespaced_taskruns if i["state"] == "running"]
                )
                failed = len(
                    [i for i in namespaced_taskruns if "outcome" in i and i["outcome"] == "failed"]
                )
                pending = len(
                    [i for i in namespaced_taskruns if i["state"] == "pending"]
                )
                signed_true = len(
                    [
                        i
                        for i in namespaced_taskruns
                        if "signed" in i and i["signed"] == "true"
                    ]
                )
                signed_false = len(
                    [
                        i
                        for i in namespaced_taskruns
                        if "signed" in i and i["signed"] == "false"
                    ]
                )
                finalizers_present = len(
                    [i for i in namespaced_taskruns if i["finalizers"] is True]
                )
                finalizers_absent = len(
                    [i for i in namespaced_taskruns if i["finalizers"] is False]
                )
                deleted = len([i for i in namespaced_taskruns if i["deleted"] is True])
                terminated = len(
                    [i for i in namespaced_taskruns if i["terminated"] is True]
                )
            trs = {
                "monitoring_start": monitoring_start,
                "monitoring_now": monitoring_now,
                "monitoring_second": monitoring_second,
                "finished": finished,
                "running": running,
                "failed": failed,
                "pending": pending,
                "total": total,
                "signed_true": signed_true,
                "signed_false": signed_false,
                "finalizers_present": finalizers_present,
                "finalizers_absent": finalizers_absent,
                "deleted": deleted,
                "terminated": terminated,
            }

            if monitoring_second > args.delay and prs["should_be_started"] > 0:
                logging.info(
                    f"Creating {prs['should_be_started']} PipelineRuns in {namespace}"
                )
                creation_threads = set()
                started_worked_now = 0
                started_failed_now = 0
                for _ in range(prs["should_be_started"]):
                    future = PropagatingThread(
                        target=start_pipelinerun_thread, args=[run_to_start, namespace]
                    )
                    future.start()
                    creation_threads.add(future)
                for future in creation_threads:
                    try:
                        future.join()
                    except:
                        logging.exception(f"PipelineRun creation failed in {namespace}")
                        started_failed_now += 1
                    else:
                        started_worked_now += 1
                logging.info(
                    f"Finished creating {prs['should_be_started']} PipelineRuns in {namespace}: {started_worked_now}/{started_failed_now}"
                )
                started_worked += started_worked_now
                started_failed += started_failed_now
            prs["started_worked"] = started_worked
            prs["started_failed"] = started_failed

            logging.info(f"PipelineRuns: {json.dumps(prs, cls=DateTimeEncoder)}")
            logging.info(f"TaskRuns: {json.dumps(trs, cls=DateTimeEncoder)}")

            if args.stats_file is not None:
                if not os.path.isfile(args.stats_file):
                    with open(args.stats_file, "w") as fd:
                        csvwriter = csv.writer(fd)
                        csvwriter.writerow(
                            [
                                "namespace",
                                "monitoring_start",
                                "monitoring_now",
                                "monitoring_second",
                                "prs_total",
                                "prs_failed",
                                "prs_pending",
                                "prs_running",
                                "prs_finished",
                                "prs_signed_true",
                                "prs_signed_false",
                                "prs_finalizers_present",
                                "prs_finalizers_absent",
                                "prs_started_worked",
                                "prs_started_failed",
                                "prs_deleted",
                                "prs_terminated",
                                "trs_total",
                                "trs_failed",
                                "trs_pending",
                                "trs_running",
                                "trs_finished",
                                "trs_signed_true",
                                "trs_signed_false",
                                "trs_finalizers_present",
                                "trs_finalizers_absent",
                                "trs_deleted",
                                "trs_terminated",
                            ]
                        )
                with open(args.stats_file, "a") as fd:
                    csvwriter = csv.writer(fd)
                    csvwriter.writerow(
                        [
                            namespace,
                            monitoring_start.isoformat(),
                            monitoring_now.isoformat(),
                            monitoring_second,
                            prs["total"],
                            prs['failed'],
                            prs["pending"],
                            prs["running"],
                            prs["finished"],
                            prs["signed_true"],
                            prs["signed_false"],
                            prs["finalizers_present"],
                            prs["finalizers_absent"],
                            prs["started_worked"],
                            prs["started_failed"],
                            prs["deleted"],
                            prs["terminated"],
                            trs["total"],
                            trs['failed'],
                            trs["pending"],
                            trs["running"],
                            trs["finished"],
                            trs["signed_true"],
                            trs["signed_false"],
                            trs["finalizers_present"],
                            trs["finalizers_absent"],
                            trs["deleted"],
                            trs["terminated"],
                        ]
                    )

            # Add namespace into completion
            if prs[args.wait_for_state] >= args.total:
                namespace_wait_for_state_completed.add(namespace)

            # Terminate script after reaching timeout defined in --wait-for-duration
            if (
                args.wait_for_duration is not None
                and (now() - monitoring_start).total_seconds() >= args.wait_for_duration
            ):
                logging.info("--wait-for-duration timeout reached, we are done.")
                return

            # If --wait-for-state count reached across all namespaces, then exit
            if len(namespace_wait_for_state_completed) == args.namespace:
                logging.info(
                    "--wait-for-state reached across all namespaces, we are done."
                )
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
        target=process_events_thread,
        args=[
            taskruns_watcher,
            taskruns,
            taskruns_lock,
        ],
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
        ],
    )
    counter_future.name = "counter_thread"
    counter_future.start()

    try:
        counter_future.join()
    except:
        logging.exception("Counter thread failed")

    logging.info("Asking watcher threads to stop")
    pipelineruns_watcher.stop()
    taskruns_watcher.stop()

    pipelineruns_future.join()
    taskruns_future.join()

    with open(args.output_file, "w") as fd:
        json.dump(
            {"pipelineruns": pipelineruns, "taskruns": taskruns},
            fd,
            cls=DateTimeEncoder,
        )


def main():
    parser = argparse.ArgumentParser(
        prog="Tekton monitoring and benchmark test",
        description="Track number of running PipelineRuns and TaskRuns and optionally keep given paralelism",
    )
    parser.add_argument(
        "--concurrent",
        help="How many concurrent PipelineRuns to run? Defaults to 0 meaning we will not start more PRs.Either it can be integer or a file which has integer",
        default=0,
    )
    parser.add_argument(
        "--total",
        help="Quit once there is this many PipelineRuns.",
        default=100,
        type=int,
    )
    parser.add_argument(
        "--namespace",
        help="How many namespaces to consider for benchmarking? Defaults to 1. The values for --total and --concurrent is considered per namespace.",
        default=1,
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
        "--wait-for-state",
        help="When waiting for '--total <N>' PipelineRuns, count these in this state",
        choices=("total", "finished", "signed_true"),
        default="finished",
        type=str,
    )
    parser.add_argument(
        "--wait-for-duration",
        help="Terminate this benchmark script after given duration (seconds).\
            This flag overrides --total flag and sets a large value to avoid early exit.",
        default=None,
        type=int,
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

    if args.wait_for_duration is not None:
        args.total = TOTAL_RUN__FOR__WAIT_FOR_DURAITON_FLAG

    return doit(args)


if __name__ == "__main__":
    sys.exit(main())
