from results_auth import configure_results_auth
import os
from time import monotonic
from gevent import sleep
from locust import HttpUser, task
from urllib3.exceptions import InsecureRequestWarning
import urllib3

urllib3.disable_warnings(InsecureRequestWarning)


class FetchRecordsTest(HttpUser):
    '''
    User scenario to fetch a specific record
    '''
    def on_start(self):
        self.client.verify = False
        configure_results_auth(self.client)

        self.record_id = None
        concurrent = os.environ.get("LOCUST_RUN_PHASE") == "concurrent"
        deadline = monotonic() + 300
        while True:
            # A new ingestion run may not have persisted any TaskRuns yet.
            response = self.client.get(
                "/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records",
                name="fetch_id", **({"timeout": 10} if concurrent else {}),
            )
            records = response.json().get("records") or []
            for record in records:
                if str((record.get("data") or {}).get("type", "")).endswith(".TaskRun"):
                    self.record_id = record["name"]
                    return
            if not concurrent or monotonic() >= deadline:
                raise RuntimeError("No TaskRun record available for GetRecord")
            sleep(2)

    @task
    def get_record(self) -> None:
        """Get Record for a particular result"""
        self.client.get(
            f"/apis/results.tekton.dev/v1alpha2/parents/{self.record_id}",
            name="/record"
        )
