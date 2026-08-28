"""notes-web — the presentation tier of the Notes Platform.

It does two things:
  1. serves the static UI
  2. proxies /api/* to notes-api, server-side

WHY proxy instead of letting the browser call the API directly?
Because that makes this process a REAL in-cluster consumer of notes-api: it
resolves the API by DNS and connects over the cluster network. If the browser
called the API directly, everything this project teaches about Services and
Ingress would be a claim you read instead of a failure you watch happen.

It also gives the Ingress something honest to route: `/` to this tier and
`/api` straight to the API tier, which is the path-based routing lesson in
stage 09.
"""

import logging
import os

import requests
from flask import Flask, Response, request, send_from_directory


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
APP_ENV = env("APP_ENV", "development")

# STAGE 03: hardcoded to a Pod IP, and it breaks the moment that pod restarts.
# STAGE 04: becomes a Service DNS name.
# STAGE 05: moves out of the manifest and into a ConfigMap.
NOTES_API_URL = env("NOTES_API_URL", "http://127.0.0.1:8080").rstrip("/")

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " msg=%(message)s",
)
log = logging.getLogger("notes-web")

app = Flask(__name__, static_folder="/static")


# This tier has no database, so BOTH probes are trivial. Readiness here means
# "gunicorn is accepting connections", nothing more. Do not be tempted to make
# this endpoint check the API — see stage 11 on cascading readiness failures.
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    return "ready\n", 200


@app.get("/whoami")
def whoami():
    return f"pod={POD_NAME}\napi={NOTES_API_URL}\n", 200


@app.route("/api/<path:subpath>", methods=["GET", "POST", "DELETE"])
def proxy(subpath: str):
    url = f"{NOTES_API_URL}/api/{subpath}"
    headers = {"Content-Type": request.headers.get("Content-Type", "application/json")}
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
        # Name the URL that failed. An unexplained 502 sends people hunting in
        # the wrong tier for twenty minutes.
        log.error("api unreachable url=%s err=%s", url, exc)
        return (
            f"502 — cannot reach the notes API at {NOTES_API_URL}\n\n{exc}\n",
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


log.info("notes-web starting api=%s env=%s", NOTES_API_URL, APP_ENV)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
