import urllib3
from random import shuffle
from datetime import datetime
from urllib3.exceptions import InsecureRequestWarning
from locust import HttpUser, task

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

        # Small Randomness in picking first taskrun for fetching log
        # shuffle(records)

        # Filter for only TR records
        taskruns = []
        for record in records:
            if "data" in record and 'type' in record['data'] and (record['data']['type'].endswith(".TaskRun")):
                taskruns.append(record)

        # Sort the TRs by date
        taskruns = sorted(taskruns, key=lambda tr: datetime.fromisoformat(tr["createTime"].replace("Z", "")))

        # Pick the oldest TR reocrd
        self.log_id = taskruns[0]['name']

        # Look for TaskRun object to fetch logs
        # for record in taskruns:
        #     if "data" in record and 'type' in record['data'] and (
        #         record['data']['type'].endswith(".TaskRun")
        #         # Uncomment below to include PipelineRun for search
        #         # or record['data']['type'].endswith(".PipelineRun")
        #     ):
        #         self.log_id = record['name']
        #         break

        # Replace /records with /logs endpoint to fetch the log data for the TaskRun
        if self.log_id:
            self.log_id = self.log_id.replace("/records", "/logs")

    def validate_response(self, response):
        '''Check whether the log response contains actual data when returning 200 status code'''
        if response.status_code == 200 and len(response.text) > 0:
            return True
        return False

    @task
    def get_log(self) -> None:
        """Get Log content for a result"""
        if self.log_id:
            with self.client.get(
                f"/apis/results.tekton.dev/v1alpha2/parents/{self.log_id}",
                name="/log",
                catch_response=True
            ) as response:
                if self.validate_response(response):
                    response.success()
                else:
                    response.failure("Response validation failed")
