#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import argparse
import csv
import datetime
import json
import logging
import logging.handlers
import requests
import signal
import sys
import time
import urllib3


def setup_logger(stderr_log_lvl):
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
        filename="/tmp/measure-signed.log",
        maxBytes=100 * 1000,
        backupCount=2,
    )
    rotating_handler.setLevel(logging.DEBUG)
    rotating_handler.setFormatter(formatter)
    logging.getLogger().addHandler(rotating_handler)

    return logging.getLogger("root")


def sigterm_handler(_signo, _stack_frame):
    logging.debug(f"Detected signal {_signo}")
    sys.exit(0)   # Raises SystemExit(0):


def parsedate(string):
    try:
        return datetime.datetime.fromisoformat(string)
    except AttributeError:
        out = datetime.datetime.strptime(string, "%Y-%m-%dT%H:%M:%SZ")
        out = out.replace(tzinfo=datetime.timezone.utc)
        return out


def main():
    parser = argparse.ArgumentParser(
        prog="Count signed TaskRuns",
        description="Measure number of signed Tekton TaskRuns and time needed to do so",
    )
    parser.add_argument(
        "--delay",
        help="How many seconds to wait between measurements",
        default=5,
        type=float,
    )
    parser.add_argument(
        "--server",
        help="Kubernetes API server to talk to",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--namespace",
        help="Namespace to read TaskRuns from",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--token",
        help="Authorization Bearer token",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--insecure",
        help="Ignore SSL thingy",
        action="store_true",
    )
    parser.add_argument(
        "--save",
        help="Save CSV with ongoing values to this file",
        default="/tmp/measure-signed.csv",
        type=str,
    )
    parser.add_argument(
        "--status-data-file",
        help="JSON file where we should save some final stats",
        type=str,
    )
    parser.add_argument(
        "--expect-signatures",
        help="How many signatures to expect? End once we reach the number. Use 0 for no limit.",
        default=0,
        type=int,
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
        logger = setup_logger(logging.DEBUG)
    elif args.verbose:
        logger = setup_logger(logging.INFO)
    else:
        logger = setup_logger(logging.WARNING)

    logger.debug(f"Args: {args}")

    signal.signal(signal.SIGTERM, sigterm_handler)

    session = requests.Session()
    url = f"{args.server}/apis/tekton.dev/v1/namespaces/{args.namespace}/taskruns"
    headers = {
        "Authorization": f"Bearer {args.token}",
        "Accept": "application/json;as=Table;g=meta.k8s.io;v=v1",
        "Accept-Encoding": "gzip",
    }
    verify = not args.insecure

    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    with open(args.save, "w") as fd:
        csv_writer = csv.writer(fd)
        csv_writer.writerow(["date", "all", "succeeded", "signed true", "signed false", "unsigned", "guessed avg", "guessed from count", "latency created succeeded", "latency succeeded signed"])

    what_when = {}   # when was each TaskRun completed and signed?

    try:
        while True:
            if "UTC" in dir(datetime):
                now = datetime.datetime.now(datetime.UTC)
            else:
                # Older Python workaround
                now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)

            response = session.get(url, headers=headers, verify=verify, timeout=100)
            response.raise_for_status()
            data = response.json()
            logging.debug(f"Obtained {len(response.content)} bytes of data with {response.status_code} status code")
            # with open("../openshift-pipelines_performance/taskruns-table.json", "r") as fd:
            #     data = json.load(fd)

            taskruns_all = 0
            taskruns_succeeded = 0
            taskruns_signed_true = 0
            taskruns_signed_false = 0
            taskruns_sig_duration = []

            for row in data["rows"]:
                name = row["object"]["metadata"]["name"]
                if name not in what_when:
                    what_when[name] = {"created": None, "succeeded": None, "signed": None}
                if what_when[name]["created"] is None:
                    what_when[name]["created"] = parsedate(row["object"]["metadata"]["creationTimestamp"])

                taskruns_all += 1
                if row["cells"][2] == "Succeeded" and row["cells"][1] == "True":
                    taskruns_succeeded += 1

                    if what_when[name]["succeeded"] is None:
                        what_when[name]["succeeded"] = now

                if "annotations" in row["object"]["metadata"] and "chains.tekton.dev/signed" in row["object"]["metadata"]["annotations"]:
                    if row["object"]["metadata"]["annotations"]["chains.tekton.dev/signed"] == "true":
                        taskruns_signed_true += 1
                    elif row["object"]["metadata"]["annotations"]["chains.tekton.dev/signed"] == "false":
                        taskruns_signed_false += 1
                    else:
                        logging.error(f"Failed to process chains.tekton.dev/signed annotation {row['object']['metadata']['annotations']['chains.tekton.dev/signed']} for name {name}")
                        continue

                    if what_when[name]["signed"] is None:
                        what_when[name]["signed"] = now

                    # Guess signing duration
                    completed_time = None
                    signed_time = None
                    for item in row["object"]["metadata"]["managedFields"]:
                        if item["manager"] == "openshift-pipelines-controller" \
                           and "f:status" in item["fieldsV1"] \
                           and "f:completionTime" in item["fieldsV1"]["f:status"]:
                            completed_time = parsedate(item["time"])
                        if item["manager"] == "openshift-pipelines-chains-controller" \
                           and "f:metadata" in item["fieldsV1"] \
                           and "f:annotations" in item["fieldsV1"]["f:metadata"] \
                           and "f:chains.tekton.dev/signed" in item["fieldsV1"]["f:metadata"]["f:annotations"]:
                            signed_time = parsedate(item["time"])
                    if completed_time is not None and signed_time is not None:
                        taskruns_sig_duration.append((signed_time - completed_time).total_seconds())

            taskruns_sig_avg = 0
            if len(taskruns_sig_duration) > 0:
                taskruns_sig_avg = sum(taskruns_sig_duration) / len(taskruns_sig_duration)

            latency_created_succeeded = 0.0
            data_created_succeeded = [(t["succeeded"] - t["created"]).total_seconds() for t in what_when.values() if t["created"] is not None and t["succeeded"] is not None]
            if len(data_created_succeeded) > 0:
                latency_created_succeeded = sum(data_created_succeeded) / len(data_created_succeeded)
            latency_succeeded_signed = 0.0
            data_succeeded_signed = [(t["signed"] - t["succeeded"]).total_seconds() for t in what_when.values() if t["succeeded"] is not None and t["signed"] is not None]
            if len(data_succeeded_signed) > 0:
                latency_succeeded_signed = sum(data_succeeded_signed) / len(data_succeeded_signed)

            logger.info(f"Status as of {now.isoformat()}: all={taskruns_all}, succeeded={taskruns_succeeded}, signed true={taskruns_signed_true}, signed false={taskruns_signed_false}, guessed avg duration={taskruns_sig_avg:.02f} out of {len(taskruns_sig_duration)}, latency_created_succeeded={latency_created_succeeded}, latency_succeeded_signed={latency_succeeded_signed}")

            with open(args.save, "a") as fd:
                csv_writer = csv.writer(fd)
                csv_writer.writerow([now.isoformat(), taskruns_all, taskruns_succeeded, taskruns_signed_true, taskruns_signed_false, taskruns_succeeded - taskruns_signed_true - taskruns_signed_false, taskruns_sig_avg, len(taskruns_sig_duration), latency_created_succeeded, latency_succeeded_signed])

            if args.expect_signatures != 0 and taskruns_signed_true + taskruns_signed_false >= args.expect_signatures:
                logger.info(f"We reached {taskruns_signed_true + taskruns_signed_false} signed TaskRuns and we expected {args.expect_signatures}, so we are good")
                break

            time.sleep(args.delay)
    finally:
        logger.info("Goodbye")

        if args.status_data_file is not None:
            with open(args.status_data_file, "r") as fd:
                sd = json.load(fd)
            if "results" not in sd:
                sd["results"] = {}
            if "signatures" not in sd["results"]:
                sd["results"]["signatures"] = {}
            sd["results"]["signatures"]["all"] = taskruns_all
            sd["results"]["signatures"]["succeeded"] = taskruns_succeeded
            sd["results"]["signatures"]["signed_true"] = taskruns_signed_true
            sd["results"]["signatures"]["signed_false"] = taskruns_signed_false
            sd["results"]["signatures"]["signed"] = taskruns_signed_true + taskruns_signed_false
            sd["results"]["signatures"]["guessed_avg_duration"] = taskruns_sig_avg
            sd["results"]["signatures"]["guessed_avg_count"] = len(taskruns_sig_duration)
            sd["results"]["signatures"]["latency_created_succeeded"] = latency_created_succeeded
            sd["results"]["signatures"]["latency_succeeded_signed"] = latency_succeeded_signed
            with open(args.status_data_file, "w") as fd:
                sd = json.dump(sd, fd, indent=4, sort_keys=True)


if __name__ == "__main__":
    sys.exit(main())
