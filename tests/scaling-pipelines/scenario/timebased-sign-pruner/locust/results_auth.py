"""Results credentials from the pod's rotating, projected service-account token."""

import os
from pathlib import Path
from requests.auth import AuthBase

TOKEN_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")


class ServiceAccountAuth(AuthBase):
    def __call__(self, request):
        try:
            token = TOKEN_PATH.read_text().strip()
        except OSError:
            raise RuntimeError("Results authentication requires a mounted service-account token") from None
        if not token:
            raise RuntimeError("Results service-account token is empty")
        request.headers["Authorization"] = f"Bearer {token}"
        return request


def configure_results_auth(client):
    if os.environ.get("RESULTS_AUTH_ENABLED", "false").lower() == "true":
        client.auth = ServiceAccountAuth()

