#!/usr/bin/env python

import argparse
import copy
import datetime
import errno
import json
import logging
import os
import os.path
import re
import sys

import matplotlib.pyplot
import matplotlib.colors

import opl.skelet
import opl.data

import requests

import tabulate

import kubernetes   # noqa: I100

import urllib3
import urllib3.exceptions

import utils_users


def str2date(date_str):
    return datetime.datetime.fromisoformat(date_str.replace("Z", "+00:00"))


class DateTimeEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, datetime.datetime):
            return o.isoformat()
        return super().default(o)


class DateTimeDecoder(json.JSONDecoder):
    def __init__(self, *args, **kwargs):
        super().__init__(object_hook=self.object_hook, *args, **kwargs)

    def object_hook(self, o):
        ret = {}
        for key, value in o.items():
            if isinstance(value, str):
                try:
                    ret[key] = datetime.datetime.fromisoformat(value)
                except ValueError:
                    ret[key] = value
            else:
                ret[key] = value
        return ret


class Something():
    SPEC_PIPELINERUNS = {
        "group": "tekton.dev",
        "version": "v1beta1",
        "plural": "pipelineruns",
    }
    SPEC_TASKRUNS = {
        "group": "tekton.dev",
        "version": "v1beta1",
        "plural": "taskruns",
    }

    def __init__(self, status_data, users_list, info_dir):
        self.status_data = status_data
        self.users_list = users_list
        self.info_dir = info_dir

        self.raw_data_path = os.path.join(self.info_dir, "raw-data.json")
        self.lanes_path = os.path.join(self.info_dir, "lanes-data.json")
        self.raw_cr_dir = os.path.join(self.info_dir, "cr-dir/")
        self._create_dir(self.raw_cr_dir)
        self.fig_path = os.path.join(self.info_dir, "output.svg")

        self.pr_count = 0
        self.tr_count = 0
        self.pr_skips = 0   # how many PipelineRuns we skipped
        self.tr_skips = 0   # how many TaskRuns we skipped
        self.pod_skips = 0   # how many Pods we skipped
        self.pr_duration = datetime.timedelta(0)   # total time of all PipelineRuns
        self.tr_duration = datetime.timedelta(0)   # total time of all TaskRuns
        self.pr_idle_duration = datetime.timedelta(0)   # total time in PipelineRuns when no TaskRun was running

    def _create_dir(self, name):
        try:
            os.makedirs(name)
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise

    def _client_for_user(self, user):
        """Return k8s API client for given user."""
        configuration = kubernetes.client.Configuration()
        configuration.api_key_prefix["authorization"] = "Bearer"
        configuration.verify_ssl = user["verify"]
        configuration.host = user["api_host"]
        configuration.sso_host = user["sso_host"]

        self._refresh_token(configuration, refresh_token=user["offline_token"])
        configuration.refresh_api_key_hook = self._refresh_token
        api_client = kubernetes.client.ApiClient(configuration)
        logging.debug(f"Initiated kubernets client object with {configuration.host}")
        return api_client

    @staticmethod
    def _refresh_token(conf, refresh_token=None):
        """Based on offline token, generate access token."""
        if refresh_token is None:
            refresh_token = conf.sso_token["refresh_token"]
            now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
            max_age = conf.sso_token["expires_in"] / 2
            current_age = (now - conf.sso_token_refresh).total_seconds()
            do_refresh = current_age >= max_age
            if do_refresh:
                logging.debug(f"SSO token is {current_age:.0f} seconds old and because max allowed age is {max_age:.0f} seconds, refreshing")
        else:
            do_refresh = True
            logging.debug("No token available, generating one")

        if do_refresh:
            refresh_at = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
            response = requests.post(
                f"{conf.sso_host}/auth/realms/redhat-external/protocol/openid-connect/token",
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={
                    "grant_type": "refresh_token",
                    "client_id": "cloud-services",
                    "refresh_token": refresh_token,
                },
            )
            sso_token = response.json()
            conf.sso_token_refresh = refresh_at
            conf.sso_token = sso_token
            conf.api_key["authorization"] = sso_token["access_token"]
            logging.debug(f"SSO token refreshed, valid for {sso_token['expires_in']} seconds")

    def _populate_pipelineruns(self, api_instance, namespace):
        """Load PipelineRuns."""
        api_response = api_instance.list_namespaced_custom_object(
            **self.SPEC_PIPELINERUNS,
            namespace=namespace,
        )

        for pr in api_response["items"]:
            try:
                pr_name = pr["metadata"]["name"]
            except KeyError as e:
                logging.warning(f"PipelineRun '{str(pr)[:200]}...' missing name, skipping: {e}")
                self.pr_skips += 1
                continue

            safe_now = re.sub(r'[^a-zA-Z0-9_-]', '-', datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).isoformat())
            path = os.path.join(self.raw_cr_dir, pr_name + "-" + safe_now)
            self._dump_json(data=pr, path=path)

            try:
                pr_conditions = pr["status"]["conditions"]
                pr_creationTimestamp = str2date(pr["metadata"]["creationTimestamp"])
                pr_completionTime = str2date(pr["status"]["completionTime"])
                pr_startTime = str2date(pr["status"]["startTime"])
            except KeyError as e:
                logging.warning(f"PipelineRun {pr_name} missing some fields, skipping: {e}")
                self.pr_skips += 1
                continue

            pr_condition_ok = False
            for c in pr_conditions:
                if c["type"] == "Succeeded":
                    if c["status"] == "True":
                        pr_condition_ok = True
                    break
            if not pr_condition_ok:
                logging.warning(f"PipelineRun {pr_name} is not in right condition, skipping: {pr_conditions}")
                self.pr_skips += 1
                continue

            self.data[pr_name] = {
                "creationTimestamp": pr_creationTimestamp,
                "completionTime": pr_completionTime,
                "start_time": pr_startTime,
                "taskRuns": {},
            }

    def _populate_taskruns(self, api_instance, namespace):
        """Load TaskRuns."""
        api_response = api_instance.list_namespaced_custom_object(
            **self.SPEC_TASKRUNS,
            namespace=namespace,
        )

        for tr in api_response["items"]:
            try:
                tr_name = tr["metadata"]["labels"]["tekton.dev/task"]
                tr_pipelinerun = tr["metadata"]["labels"]["tekton.dev/pipelineRun"]
            except KeyError as e:
                logging.warning(f"TaskRun missing name or pipelinerun, skipping: {e}")
                self.tr_skips += 1
                continue

            safe_now = re.sub(r'[^a-zA-Z0-9_-]', '-', datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).isoformat())
            path = os.path.join(self.raw_cr_dir, tr_pipelinerun + "-" + tr_name + "-" + safe_now)
            self._dump_json(data=tr, path=path)

            try:
                tr_conditions = tr["status"]["conditions"]
                tr_creationTimestamp = str2date(tr["metadata"]["creationTimestamp"])
                tr_completionTime = str2date(tr["status"]["completionTime"])
                tr_startTime = str2date(tr["status"]["startTime"])
                tr_podName = tr["status"]["podName"]
                tr_namespace = tr["metadata"]["namespace"]
            except KeyError as e:
                logging.warning(f"TaskRun {tr_pipelinerun}/{tr_name} missing some fields, skipping: {e}")
                self.tr_skips += 1
                continue

            tr_condition_ok = False
            for c in tr_conditions:
                if c["type"] == "Succeeded":
                    if c["status"] == "True":
                        tr_condition_ok = True
                    break
            if not tr_condition_ok:
                logging.warning(f"TaskRun {tr_pipelinerun}/{tr_name} is not in right condition, skipping")
                self.tr_skips += 1
                continue

            if tr_pipelinerun not in self.data:
                logging.warning(f"TaskRun {tr_pipelinerun}/{tr_name} do not have it's PipelineRun tracked, skipping")
                self.tr_skips += 1
                continue

            self.data[tr_pipelinerun]["taskRuns"][tr_name] = {
                "creationTimestamp": tr_creationTimestamp,
                "completionTime": tr_completionTime,
                "start_time": tr_startTime,
                "podName": tr_podName,
                "namespace": tr_namespace,
            }

    def _populate_pods(self, api_instance, namespace):
        """Load Nodes for TaskRuns Pod."""
        for pr_name, pr_data in self.data.items():
            for tr_name, tr_data in pr_data["taskRuns"].items():
                pod_name = tr_data["podName"]
                tr_namespace = tr_data["namespace"]

                if tr_namespace != namespace:
                    continue

                try:
                    api_response = api_instance.read_namespaced_pod(
                        name=pod_name,
                        namespace=tr_namespace,
                    ).to_dict()
                except kubernetes.client.exceptions.ApiException as e:
                    logging.warning(f"Pod '{pod_name}' can not be obtained, skipping: {e}")
                    self.pod_skips += 1
                    continue

                safe_now = re.sub(r'[^a-zA-Z0-9_-]', '-', datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).isoformat())
                path = os.path.join(self.raw_cr_dir, pr_name + "-" + tr_name + "-" + pod_name + "-" + safe_now)
                self._dump_json(data=api_response, path=path)

                try:
                    pod_node_name = api_response["spec"]["node_name"]
                except KeyError as e:
                    logging.warning(f"Pod {pod_name} for {pr_name}/{tr_name} missing node name filed, skipping: {e}")
                    self.pod_skips += 1
                    continue

                tr_data["node_name"] = pod_node_name

    def _dump_json(self, data, path):
        with open(path, "w") as fp:
            json.dump(data, fp, cls=DateTimeEncoder, sort_keys=True, indent=4)

    def _load_json(self, path):
        with open(path, "r") as fp:
            return json.load(fp, cls=DateTimeDecoder)

    def _compute_lanes(self):
        """
        Based on loaded PipelineRun and TaskRun data, compute lanes for a graph.

        Visualizing overlapping intervals:
        https://www.nxn.se/valent/visualizing-overlapping-intervals
        """
        def fits_into_lane(entity, lane):
            start = "creationTimestamp"
            end = "completionTime"
            logging.debug(f"Checking if entity ({entity[start]} - {entity[end]}) fits into lane with {len(lane)} members")
            for member in lane:
                if member[start] <= entity[start] <= member[end] \
                   or member[start] <= entity[end] <= member[end] \
                   or entity[start] <= member[start] <= entity[end]:
                    logging.debug(f"Entity ({entity[start]} - {entity[end]}) does not fit because of lane member ({member[start]} - {member[end]})")
                    return False
            logging.debug(f"Entity ({entity[start]} - {entity[end]}) fits")
            return True

        for pr_name, pr_times in self.data.items():
            pr = copy.deepcopy(pr_times)
            pr["name"] = pr_name

            # How do we organize it's TRs?
            tr_lanes = []

            for tr_name, tr_times in pr["taskRuns"].items():
                tr = copy.deepcopy(tr_times)
                tr["name"] = tr_name
                for lane in tr_lanes:
                    # Is there a lane without colnflict?
                    if fits_into_lane(tr, lane):
                        lane.append(tr)
                        break
                else:
                    # Adding new lane
                    tr_lanes.append([tr])

            pr["tr_lanes"] = tr_lanes
            del pr["taskRuns"]

            # Where it fits in a list of PRs?
            for lane in self.pr_lanes:
                # Is there a lane without colnflict?
                if fits_into_lane(pr, lane):
                    lane.append(pr)
                    break
            else:
                # Adding new lane
                self.pr_lanes.append([pr])

        self.pr_lanes.sort(key=lambda k: min([i["creationTimestamp"] for i in k]))

        self._dump_json(data=self.pr_lanes, path=self.lanes_path)

    def _compute_times(self):
        """
        Based on computed lanes, compute some statistical measures for the run.
        """

        def add_time_interval(existing, new):
            """
            Merge the new interval with first overlaping existing interval or add new one to list.
            """
            start = "creationTimestamp"
            end = "completionTime"
            processed = False

            for t in existing:
                # If both ends are inside of existing interval, we ignore it
                if t[start] <= new[start] <= t[end] \
                   and t[start] <= new[end] <= t[end]:
                    processed = True
                    continue

                # If start is inside existing interval, but end is outside of it,
                # we extend existing interval
                if t[start] <= new[start] <= t[end]:
                    if new[end] > t[end]:
                        t[end] = new[end]
                        processed = True
                        continue

                # If end is inside existing interval, but start is outside of it,
                # we extend existing interval
                if t[start] <= new[end] <= t[end]:
                    if new[start] < t[start]:
                        t[start] = new[start]
                        processed = True
                        continue

            if not processed:
                existing.append(new)

        start = "creationTimestamp"
        end = "completionTime"

        self.pr_count = len(self.data)
        self.tr_count = sum([len(i["taskRuns"]) for i in self.data.values()])

        for pr_name, pr_times in self.data.items():
            pr_duration = pr_times[end] - pr_times[start]
            self.pr_duration += pr_duration

            # Combine TaskRuns so they do not overlap
            trs = []
            for tr_name, tr_times in pr_times["taskRuns"].items():
                self.tr_duration += tr_times[end] - tr_times[start]
                add_time_interval(trs, tr_times)

            # Combine new intervals so they do not overlap
            trs_no_overlap = []
            for interval in trs:
                add_time_interval(trs_no_overlap, interval)

            tr_simple_duration = datetime.timedelta(0)
            for interval in trs_no_overlap:
                tr_simple_duration += interval[end] - interval[start]

            self.pr_idle_duration += pr_duration - tr_simple_duration

        print(f"There was {self.pr_count} PipelineRuns and {self.tr_count} TaskRuns")
        print(f"In total PipelineRuns took {self.pr_duration} and TaskRuns took {self.tr_duration}, PipelineRuns were idle for {self.pr_idle_duration}")
        pr_duration_avg = (self.pr_duration / self.pr_count).total_seconds() if self.pr_count != 0 else None
        tr_duration_avg = (self.tr_duration / self.tr_count).total_seconds() if self.tr_count != 0 else None
        pr_idle_duration_avg = (self.pr_idle_duration / self.pr_count).total_seconds() if self.pr_count != 0 else None
        print(f"In average PipelineRuns took {pr_duration_avg} and TaskRuns took {tr_duration_avg}, PipelineRuns were idle for {pr_idle_duration_avg} seconds")

        self.status_data.set("results.show_pipelineruns.pr_count", self.pr_count)
        self.status_data.set("results.show_pipelineruns.tr_count", self.tr_count)
        self.status_data.set("results.show_pipelineruns.pr_duration_sum", self.pr_duration.total_seconds())
        self.status_data.set("results.show_pipelineruns.tr_duration_sum", self.tr_duration.total_seconds())
        self.status_data.set("results.show_pipelineruns.pr_idle_duration_sum", self.pr_idle_duration.total_seconds())
        self.status_data.set("results.show_pipelineruns.pr_duration_avg", pr_duration_avg)
        self.status_data.set("results.show_pipelineruns.tr_duration_avg", tr_duration_avg)
        self.status_data.set("results.show_pipelineruns.pr_idle_duration_avg", pr_idle_duration_avg)

    def _compute_nodes(self):
        """
        Based on loaded data, compute how many TaskRuns run on what nodes.
        """
        nodes = {}
        for pr_name, pr_data in self.data.items():
            for tr_name, tr_data in pr_data["taskRuns"].items():
                try:
                    node_name = tr_data["node_name"]
                except KeyError:
                    logging.warning(f"TaskRun {tr_name} missing node_name field, skipping.")
                    continue
                if node_name not in nodes:
                    nodes[node_name] = 1
                else:
                    nodes[node_name] += 1

        print("\nNumber of TaskRuns per node:")
        for node, count in sorted(nodes.items(), key=lambda item: item[1]):
            print(f"    {node}: {count}")

        self.status_data.set("results.count_by_node.stats", opl.data.data_stats(list(nodes.values())))
        self.status_data.set("results.count_by_node.detail", [{k: v} for k, v in nodes.items()])

    def _show_pr_tr_nodes(self):
        """
        Show which PipelineRuns and TaskRuns were running on which node
        """
        table = []
        stats = {}
        for pr_name, pr_data in self.data.items():
            pr_tr_nodes = {}
            for tr_name, tr_data in pr_data["taskRuns"].items():
                try:
                    node_name = tr_data["node_name"]
                except KeyError:
                    logging.warning(f"TaskRun {tr_name} missing node_name field, skipping.")
                    continue
                table.append([pr_name, tr_name, node_name])
                pr_tr_nodes[tr_name] = node_name

            # Compile stats of whoch tasks ran on same node (in one PR) most often
            for tr1 in pr_tr_nodes:
                for tr2 in pr_tr_nodes:
                    if pr_tr_nodes[tr1] == pr_tr_nodes[tr2]:
                        if tr1 not in stats:
                            stats[tr1] = {}
                        if tr2 not in stats[tr1]:
                            stats[tr1][tr2] = 0
                        stats[tr1][tr2] += 1

        # Transform the stats to the form tabulate can handle
        table_keys = sorted(list(stats.keys()))
        table_data = []
        for tr1 in table_keys:
            table_row = []
            for tr2 in table_keys:
                table_row.append(stats[tr1][tr2])
            table_data.append([tr1] + table_row)

        print("\nWhich PipelineRuns and TaskRuns ran on which node:")
        print(tabulate.tabulate(
            table,
            headers=["PipelineRun", "TaskRun", "Node"],
        ))

        print("\nWhich TaskRuns inside of one PipelineRun were sharing node most often:")
        print(tabulate.tabulate(
            table_data,
            headers=["TaskRun"] + table_keys,
        ))


    def _plot_graph(self):
        """
        Based on computed lanes, plot a graph.

        Horizontal bar plot with gaps:
        https://matplotlib.org/stable/gallery/lines_bars_and_markers/broken_barh.html#sphx-glr-gallery-lines-bars-and-markers-broken-barh-py
        """

        def entity_to_coords(entity):
            start = "creationTimestamp"
            end = "completionTime"
            return (entity[start].timestamp(), (entity[end] - entity[start]).total_seconds())

        def get_min(entity, current_min):
            start = "creationTimestamp"
            return min(entity[start].timestamp(), current_min)

        def get_max(entity, current_max):
            end = "completionTime"
            return max(entity[end].timestamp(), current_max)

        size = max(5, self.pr_count / 2)
        fig, ax = matplotlib.pyplot.subplots(figsize=(size, size))

        fig_x_min = sys.maxsize
        fig_x_max = 0

        tr_height = 10
        fig_pr_y_pos = 0
        colors = sorted(matplotlib.colors.TABLEAU_COLORS, key=lambda c: tuple(matplotlib.colors.rgb_to_hsv(matplotlib.colors.to_rgb(c))))
        colors = ['tab:gray', 'tab:brown', 'tab:orange', 'tab:olive', 'tab:green', 'tab:cyan', 'tab:blue', 'tab:purple', 'tab:pink', 'tab:red']

        for pr_lane in self.pr_lanes:
            for pr in pr_lane:
                pr_coords = entity_to_coords(pr)
                ax.broken_barh([[pr_coords[0] - 1, pr_coords[1] + 2]], (fig_pr_y_pos + 1, tr_height * len(pr["tr_lanes"]) - 2), facecolors="white", edgecolor="black")
                txt = ax.text(x=pr_coords[0] + 4, y=fig_pr_y_pos + tr_height * len(pr["tr_lanes"]) - tr_height * 0.5, s=pr["name"], fontsize=8, horizontalalignment='left', verticalalignment='center', color="darkgray", rotation=-10, rotation_mode="anchor")
                ax.add_artist(txt)
                c_index = 0
                fig_tr_y_pos = fig_pr_y_pos
                for tr_lane in pr["tr_lanes"]:
                    for tr in tr_lane:
                        fig_x_min = get_min(tr, fig_x_min)
                        fig_x_max = get_max(tr, fig_x_max)
                        tr_coords = entity_to_coords(tr)
                        ax.broken_barh([tr_coords], (fig_tr_y_pos + 2, tr_height - 4), facecolors=colors[c_index])
                        txt = ax.text(x=tr_coords[0] + 2, y=fig_tr_y_pos + tr_height / 2, s=tr["name"], fontsize=8, horizontalalignment='left', verticalalignment='center', color="lightgray", rotation=30, rotation_mode="anchor")
                        ax.add_artist(txt)
                        c_index += 1
                        if c_index == len(colors):
                            c_index = 0
                    fig_tr_y_pos += tr_height
            fig_pr_y_pos += tr_height * max([len(pr["tr_lanes"]) for pr in pr_lane])
        ax.set_ylim(0, fig_pr_y_pos)
        ax.set_xlim(fig_x_min - 10, fig_x_max + 10)
        ax.set_xlabel('timestamps [s]')
        ax.grid(True)

        # matplotlib.pyplot.show()
        matplotlib.pyplot.savefig(self.fig_path)

    def doit(self):
        self.data = {}
        self.pr_lanes = []

        if os.path.isfile(self.raw_data_path):
            self.data = self._load_json(path=self.raw_data_path)
        else:
            for user in reversed(self.users_list):
                namespace = f"{user['username'].replace('_', '-')}-tenant"
                logging.info(f"Processing user {user}, namespace {namespace}")
                api_client = self._client_for_user(user)
                api_instance = kubernetes.client.CustomObjectsApi(api_client)

                self._populate_pipelineruns(api_instance, namespace)
                self._populate_taskruns(api_instance, namespace)

                api_instance = kubernetes.client.CoreV1Api(api_client)
                self._populate_pods(api_instance, namespace)

            print(f"Skipped {self.pr_skips} PipelineRuns and {self.tr_skips} TaskRuns and {self.pod_skips} Pods for various reasons")

            self._dump_json(data=self.data, path=self.raw_data_path)

        self._compute_lanes()
        self._compute_times()
        self._plot_graph()
        self._show_pr_tr_nodes()
        self._compute_nodes()


def doit(args, status_data):
    # Load list of users
    users_list = utils_users.load_approved_users(args.users_list)

    something = Something(
        status_data=status_data,
        users_list=users_list,
        info_dir=args.info_dir,
    )
    return something.doit()


def main():
    parser = argparse.ArgumentParser(
        description="Show PipelineRuns and TaskRuns",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--test-insecure",
        action="store_true",
        help="Use if you want to hide InsecureRequestWarning and other urllib3 warnings",
    )
    parser.add_argument(
        "--users-list",
        type=argparse.FileType('r'),
        required=True,
        help="File with list of users",
    )
    parser.add_argument(
        "--info-dir",
        default=f"show_pipelineruns-{re.sub(r'[^a-zA-Z0-9_-]', '-', datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).isoformat())}",
        help="Directory where to put all the debugging data",
    )
    with opl.skelet.test_setup(parser) as (args, status_data):
        if args.test_insecure:
            logging.warning("Disabling InsecureRequestWarning and other urllib3 warnings")
            urllib3.disable_warnings()
        return doit(args, status_data)


if __name__ == "__main__":
    sys.exit(main())
