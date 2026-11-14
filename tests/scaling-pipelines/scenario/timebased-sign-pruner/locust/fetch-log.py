from results_auth import configure_results_auth
from results_log_diagnostics import sanitize_text, utc_now
import json
import logging
import os
from time import monotonic
from gevent import sleep
import urllib3
from random import choice
from urllib3.exceptions import InsecureRequestWarning
from locust import HttpUser, events, task
from locust.runners import MasterRunner, WorkerRunner
from gevent.lock import Semaphore

urllib3.disable_warnings(InsecureRequestWarning)

# Spread load across many TaskRun logs (old test pinned every user to the oldest TR).
LOG_POOL_SIZE = 200
RECORDS_PAGE_SIZE = 200

# Shared pool so 100 users don't each paginate records at startup.
_log_ids = None
_log_ids_lock = Semaphore()
_failure_samples = 0
FAILURE_SAMPLE_LIMIT = 50  # Per worker and window; Locust still counts every failure.
logger = logging.getLogger(__name__)
DIAGNOSTIC_MESSAGE = "results_log_diagnostic"
_relay_warning_logged = False


def write_diagnostic(sample):
    level = logging.INFO if sample.get('event') == 'log_pool' else logging.WARNING
    logger.log(level, 'RESULTS_LOG_DIAGNOSTIC %s', json.dumps(sample))


def receive_diagnostic(environment, msg, **kwargs):
    sample = dict(msg.data, worker_id=msg.node_id)
    write_diagnostic(sample)


@events.init.add_listener
def configure_diagnostic_relay(environment, **kwargs):
    if isinstance(environment.runner, MasterRunner):
        environment.runner.register_message(DIAGNOSTIC_MESSAGE, receive_diagnostic)


def emit_diagnostic(environment, sample):
    """Persist worker samples in the streamed master log while pods are alive."""
    write_diagnostic(sample)
    if isinstance(environment.runner, WorkerRunner):
        try:
            environment.runner.send_message(DIAGNOSTIC_MESSAGE, sample)
        except Exception as exc:
            # A diagnostic transport failure must not mask a measured HTTP failure.
            global _relay_warning_logged
            if not _relay_warning_logged:
                logger.warning('Results log diagnostic relay failed (%s); samples remain in worker logs',
                               type(exc).__name__)
                _relay_warning_logged = True


class FetchResultLogTest(HttpUser):
    """Fetch TaskRun log content via Results API (Loki-backed)."""

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
                        emit_diagnostic(self.environment, dict(
                            event='log_pool', timestamp=utc_now(), worker=os.environ.get('HOSTNAME'),
                            log_ids=pool))
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
        started_at = utc_now()
        started = monotonic()
        with self.client.get(
            f"/apis/results.tekton.dev/v1alpha2/parents/{log_id}",
            name="/log",
            catch_response=True,
            timeout=(30, 60),
        ) as response:
            if self.validate_response(response):
                response.success()
            else:
                err = getattr(response, "error", None)
                global _failure_samples
                _failure_samples += 1
                if _failure_samples <= FAILURE_SAMPLE_LIMIT:
                    body = sanitize_text(response.text or '')
                    emit_diagnostic(self.environment, dict(
                        event='log_failure', timestamp=started_at, ended_at=utc_now(),
                        worker=os.environ.get('HOSTNAME'), log_id=log_id,
                        elapsed_ms=round((monotonic() - started) * 1000, 2),
                        status=response.status_code, body_bytes=len(response.content or b''),
                        body_sample=body[:1024], body_truncated=len(body) > 1024,
                        error=sanitize_text(err)))
                elif _failure_samples == FAILURE_SAMPLE_LIMIT + 1:
                    emit_diagnostic(self.environment, dict(
                        event='failure_sample_limit', timestamp=utc_now(),
                        worker=os.environ.get('HOSTNAME'), limit=FAILURE_SAMPLE_LIMIT))
                response.failure(
                    f"status={response.status_code} bytes={len(response.text or '')} err={sanitize_text(err)}"
                )
