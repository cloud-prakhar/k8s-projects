"""task-api — the backend of the Task Tracker.

Deliberately in-memory and dependency-light. Project 01 is about Kubernetes
workloads and networking; a database would be noise here (it arrives in
Project 02, where losing data is the whole lesson).

Everything this process needs comes from the environment. That is what makes
ConfigMaps and Secrets teachable later: the image never changes, only the env.
"""

import logging
import os
import threading

from flask import Flask, jsonify, request


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


APP_ENV = env("APP_ENV", "development")
LOG_LEVEL = env("LOG_LEVEL", "info")
# API_TOKEN arrives from a Secret in stage 06. Until then it is empty and auth
# is disabled — which is exactly the insecure state that stage fixes.
API_TOKEN = env("API_TOKEN")
# Every pod reports its own name so you can SEE load balancing across replicas.
# The Downward API supplies this in the manifest — nothing at build time can.
POD_NAME = env("POD_NAME", "unknown")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format="level=%(levelname)s pod=" + POD_NAME + " msg=%(message)s",
)
log = logging.getLogger("task-api")

app = Flask(__name__)

_lock = threading.Lock()
_tasks: list[dict] = [
    {"id": 1, "title": "Learn what a Pod is", "done": False},
    {"id": 2, "title": "Find out why Pods are not enough", "done": False},
]
_next_id = 3

# Failure-lab switch: lets you fail the readiness probe WITHOUT killing the
# process, so you can watch a Running pod get removed from the Service.
_ready = True


# --- health endpoints ------------------------------------------------------
# Two SEPARATE endpoints on purpose (stage 11 explains why):
#   /livez   — "is this process alive?"          failing => restart me
#   /healthz — "can I serve traffic right now?"  failing => stop sending me traffic
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    if not _ready:
        return "not ready\n", 503
    return "ready\n", 200


@app.post("/debug/toggle-ready")
@app.get("/debug/toggle-ready")
def toggle_ready():
    global _ready
    _ready = not _ready
    log.warning("readiness toggled ready=%s", _ready)
    return f"ready={_ready}\n", 200


# --- info: proves which pod served you, and what config it has -------------
@app.get("/api/info")
def info():
    return jsonify(
        pod=POD_NAME,
        app_env=APP_ENV,
        log_level=LOG_LEVEL,
        auth_enabled=bool(API_TOKEN),
    )


# --- tasks -----------------------------------------------------------------
def _authorized() -> bool:
    # Auth is enforced only once a token is injected (stage 06).
    if not API_TOKEN:
        return True
    return request.headers.get("X-API-Token") == API_TOKEN


@app.get("/api/tasks")
def list_tasks():
    if not _authorized():
        return jsonify(error="invalid or missing X-API-Token"), 401
    with _lock:
        return jsonify(list(_tasks))


@app.post("/api/tasks")
def create_task():
    if not _authorized():
        return jsonify(error="invalid or missing X-API-Token"), 401
    global _next_id
    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or "").strip()
    if not title:
        return jsonify(error="title is required"), 400
    with _lock:
        task = {"id": _next_id, "title": title, "done": False}
        _next_id += 1
        _tasks.append(task)
    log.debug("task created id=%s", task["id"])
    return jsonify(task), 201


@app.delete("/api/tasks")
def delete_task():
    if not _authorized():
        return jsonify(error="invalid or missing X-API-Token"), 401
    try:
        task_id = int(request.args.get("id", ""))
    except ValueError:
        return jsonify(error="no such task"), 404
    with _lock:
        for i, t in enumerate(_tasks):
            if t["id"] == task_id:
                del _tasks[i]
                return "", 204
    return jsonify(error="no such task"), 404


log.info("task-api starting env=%s auth=%s", APP_ENV, bool(API_TOKEN))

if __name__ == "__main__":
    # Development only. In the container, gunicorn serves this app —
    # Flask's built-in server is single-threaded and explicitly not for production.
    # 0.0.0.0, NOT 127.0.0.1: a container bound to loopback is unreachable from
    # anywhere else in the cluster, and the failure is completely silent.
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
