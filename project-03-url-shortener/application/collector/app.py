"""analytics-collector — a stand-in for "somebody else's analytics service".

In a real company this is another team's system, often not in your cluster at
all: a SaaS endpoint, a managed service, a database in another VPC. Here it runs
in its OWN namespace (`analytics`) so that reaching it from `url-shortener` is a
genuine cross-namespace, other-owner dependency — the situation an ExternalName
Service exists for (stage 04).

It counts click events in memory. That is fine for a stand-in and exactly why
gunicorn runs a single worker: two workers would each keep their own counts.
"""

import logging
import os
import threading
from collections import Counter
from datetime import datetime, timezone

from flask import Flask, jsonify, request

POD_NAME = os.environ.get("POD_NAME", "unknown")
logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " logger=%(name)s msg=%(message)s",
)
log = logging.getLogger("analytics-collector")

app = Flask(__name__)
_lock = threading.Lock()
_by_code: Counter = Counter()
_hosts: Counter = Counter()
_last = {"at": None}


@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    return "ready\n", 200


@app.post("/events")
def ingest():
    event = request.get_json(silent=True) or {}
    code = str(event.get("code", "unknown"))[:32]
    with _lock:
        _by_code[code] += 1
        # Record the Host header the caller used. Through an ExternalName
        # Service it is the ALIAS (`analytics`), not this Service's real name —
        # ExternalName is DNS only and never rewrites anything (stage 04 §9).
        _hosts[request.host] += 1
        _last["at"] = datetime.now(timezone.utc).isoformat()
    log.info("event type=%s code=%s from_pod=%s host=%s",
             event.get("type"), code, event.get("pod"), request.host)
    return jsonify(accepted=True), 202


@app.get("/events")
def summary():
    with _lock:
        return jsonify(
            pod=POD_NAME,
            total=sum(_by_code.values()),
            by_code=dict(_by_code.most_common(20)),
            host_headers_seen=dict(_hosts),
            last_event_at=_last["at"],
        )


log.info("analytics-collector starting")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
