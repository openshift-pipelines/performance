from locust import HttpUser, task
from urllib3.exceptions import InsecureRequestWarning
import urllib3

urllib3.disable_warnings(InsecureRequestWarning)


class FetchRecordsTest(HttpUser):
    '''
    User scenario fetches a specific record
    '''
    def on_start(self):
        self.client.verify = False

        # Extract UID and Path for a Record
        response = self.client.get(
            "/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records",
            name='fetch_id').json()['records']
        self.record_id = response[0]['name']

    @task
    def get_records(self) -> None:
        """Get Records for a particular result"""
        self.client.get(
            f"/apis/results.tekton.dev/v1alpha2/parents/{self.record_id}",
            name="/records"
        )
