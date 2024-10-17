from locust import HttpUser, task
from urllib3.exceptions import InsecureRequestWarning
import urllib3

urllib3.disable_warnings(InsecureRequestWarning)


class FetchResultLogTest(HttpUser):
    '''
    Fetch Log content for specific PipelineRun or TaskRun
    '''
    def on_start(self):
        self.client.verify = False

        # Fetch all records and extract one id
        records = self.client.get(
            "/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records",
            name='fetch_id').json()['records']

        self.log_id = None

        # Look for TaskRun/PipelineRun object to fetch logs
        for record in records:
            if "data" in record and 'type' in record['data'] and (
                record['data']['type'].endswith(".PipelineRun") or
                record['data']['type'].endswith(".TaskRun")
            ):
                self.log_id = record['name']
                break

        # Replace /records with /logs endpoint to fetch the log data for the PipelineRun or TaskRun
        if self.log_id:
            self.log_id = self.log_id.replace("/records", "/logs")

    @task
    def get_log(self) -> None:
        """Get Log content for a result"""
        if self.log_id:
            self.client.get(
                f"/apis/results.tekton.dev/v1alpha2/parents/{self.log_id}",
                name="/log"
            )
