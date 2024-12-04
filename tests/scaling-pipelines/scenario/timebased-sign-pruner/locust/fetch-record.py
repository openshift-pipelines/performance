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

        # Extract UID and Path for a Record
        records = self.client.get(
            "/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records",
            name='fetch_id').json()['records']

        self.record_id = None

        # Look for TaskRun objects
        # In v1.15 there exists additional category type - results.tekton.dev/v1alpha2.Log
        # We are mainly interested to compare API performance for /record endpoint of specific type
        for record in records:
            if "data" in record and 'type' in record['data'] and (
                record['data']['type'].endswith(".TaskRun")
            ):
                self.record_id = record['name']
                break

    @task
    def get_record(self) -> None:
        """Get Record for a particular result"""
        self.client.get(
            f"/apis/results.tekton.dev/v1alpha2/parents/{self.record_id}",
            name="/record"
        )
