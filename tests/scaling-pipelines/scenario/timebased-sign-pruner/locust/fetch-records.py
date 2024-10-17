from locust import HttpUser, task
from urllib3.exceptions import InsecureRequestWarning
import urllib3

urllib3.disable_warnings(InsecureRequestWarning)

class FetchRecordsTest(HttpUser):
    def on_start(self):
        self.client.verify = False

        # Extract UID and Path for a Result
        response = self.client.get("/apis/results.tekton.dev/v1alpha2/parents/-/results", name='fetch_id').json()['records']
        self.result_id = response[0]['name']

    @task
    def get_records(self) -> None:
        """Get Records for a particular result"""
        self.client.get(f"/apis/results.tekton.dev/v1alpha2/parents/{self.result_id}/records", name="/records")
