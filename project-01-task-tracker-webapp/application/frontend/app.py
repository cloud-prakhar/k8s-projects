"""task-web — the frontend tier of the Task Tracker.

It does two things:
  1. serves the static UI
  2. proxies /api/* to the backend, server-side

WHY proxy instead of letting the browser call the backend directly?
Because that makes this process a REAL in-cluster consumer of the backend: it
resolves the backend by DNS and connects to it over the cluster network, which
is exactly the problem a Service solves. If the browser called the backend
directly, "Pod IPs are unstable" would be an abstract claim instead of
something you watch break.
"""

import logging
import os

import requests
from flask import Flask, Response, request, send_from_directory


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")

# STAGE 03: hardcoded to a Pod IP, and it breaks constantly.
# STAGE 04: becomes a Service DNS name.
# STAGE 05: moves out of the manifest into a ConfigMap.
TASK_API_URL = env("TASK_API_URL", "http://127.0.0.1:8080").rstrip("/")

# STAGE 06: injected from a Secret. Empty until then.
API_TOKEN = env("API_TOKEN")

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " msg=%(message)s",
)
log = logging.getLogger("task-web")

app = Flask(__name__, static_folder="/static")


@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    return "ready\n", 200


@app.get("/whoami")
def whoami():
    return f"pod={POD_NAME}\napi={TASK_API_URL}\n", 200


@app.route("/api/<path:subpath>", methods=["GET", "POST", "DELETE"])
def proxy(subpath: str):
    url = f"{TASK_API_URL}/api/{subpath}"
    headers = {"Content-Type": request.headers.get("Content-Type", "application/json")}
    if API_TOKEN:
        headers["X-API-Token"] = API_TOKEN
    try:
        upstream = requests.request(
            method=request.method,
            url=url,
            params=request.args,
            data=request.get_data(),
            headers=headers,
            timeout=5,
        )
    except requests.RequestException as exc:
        # Without this, an unreachable backend produces an unhelpful 502 with no
        # explanation. Say plainly WHICH url failed — half of Kubernetes
        # debugging is discovering what the app was actually trying to reach.
        log.error("backend unreachable url=%s err=%s", url, exc)
        return (
            f"502 — cannot reach the task API at {TASK_API_URL}\n\n{exc}\n",
            502,
            {"Content-Type": "text/plain"},
        )
    return Response(
        upstream.content,
        status=upstream.status_code,
        content_type=upstream.headers.get("Content-Type", "application/json"),
    )


@app.get("/")
def index():
    return send_from_directory("/static", "index.html")


log.info("task-web starting api=%s", TASK_API_URL)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
