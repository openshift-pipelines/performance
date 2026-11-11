from results_auth import configure_results_auth
import os
from time import monotonic
from gevent import sleep
import urllib3
from random import choice
from urllib3.exceptions import InsecureRequestWarning
from locust import HttpUser, task
from gevent.lock import Semaphore

urllib3.disable_warnings(InsecureRequestWarning)

# Spread load across many TaskRun logs (old test pinned every user to the oldest TR).
LOG_POOL_SIZE = 200
RECORDS_PAGE_SIZE = 200

# Shared pool so 100 users don't each paginate records at startup.
_log_ids = None
_log_ids_lock = Semaphore()


class FetchResultLogTest(HttpUser):
    """Fetch TaskRun log content via Results API (Loki-backed)."""

    # Locust defaults are ~10s; /log via Loki often needs longer under load.
    # Per-request timeout= on client.get() is ignored for these in Locust 2.x.
    network_timeout = 60.0
    connection_timeout = 30.0

    def on_start(self):
        self.client.verify = False
        configure_results_auth(self.client)
        global _log_ids
        with _log_ids_lock:
            if _log_ids is None:
                concurrent = os.environ.get("LOCUST_RUN_PHASE") == "concurrent"
                deadline = monotonic() + 300
                while True:
                    pool = self._collect_log_ids()
                    if pool or not concurrent:
                        _log_ids = pool
                        break
                    if monotonic() >= deadline:
                        raise RuntimeError("No TaskRun log IDs available for GetLog")
                    sleep(2)
        self.log_ids = _log_ids or []

    def _collect_log_ids(self):
        """Build a pool of /logs paths from TaskRun records (multi-page)."""
        log_ids = []
        page_token = ""
        while len(log_ids) < LOG_POOL_SIZE:
            params = f"page_size={RECORDS_PAGE_SIZE}"
            if page_token:
                params += f"&page_token={page_token}"
            response = self.client.get(
                f"/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records?{params}",
                name="fetch_id",
                **({"timeout": 10} if os.environ.get("LOCUST_RUN_PHASE") == "concurrent" else {}),
            )
            payload = response.json()
            for record in payload.get("records") or []:
                data = record.get("data") or {}
                if not str(data.get("type", "")).endswith(".TaskRun"):
                    continue
                name = record.get("name")
                if name and "/records/" in name:
                    log_ids.append(name.replace("/records", "/logs", 1))
                if len(log_ids) >= LOG_POOL_SIZE:
                    break
            page_token = payload.get("next_page_token") or ""
            if not page_token:
                break
        return log_ids

    def validate_response(self, response):
        if response.status_code == 200 and len(response.text) > 0:
            return True
        return False

    @task
    def get_log(self) -> None:
        """GET log for a randomly chosen TaskRun from the pool."""
        if not self.log_ids:
            return
        log_id = choice(self.log_ids)
        with self.client.get(
            f"/apis/results.tekton.dev/v1alpha2/parents/{log_id}",
            name="/log",
            catch_response=True,
        ) as response:
            if self.validate_response(response):
                response.success()
            else:
                err = getattr(response, "error", None)
                response.failure(
                    f"status={response.status_code} bytes={len(response.text or '')} err={err}"
                )
