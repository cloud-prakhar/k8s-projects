"""payment — authorises payments. Simulated, stateless, and deliberately fragile.

This service exists to be PROTECTED. It holds no data and talks to nothing, so
the only interesting question about it is *who is allowed to call it* — which is
exactly the question a flat pod network cannot answer. Stage 15's
`allow-order-to-payment` policy is the point of this whole project.

Two dials make it a teaching tool:

  PAYMENT_LATENCY_MS  — make it slow without making it fail. One slow dependency
                        is how a whole storefront degrades, and it is far more
                        realistic (and harder to diagnose) than an outage.
  PAYMENT_FAIL_RATE   — decline a fraction of authorisations, so `order` has to
                        have an opinion about upstream failure.
"""

import logging
import os
import random
import threading
import time
import uuid

from flask import Flask, jsonify, request


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
SERVICE = "payment"

# Read once at start-up, like every env var. Changing it is a rollout — which is
# itself the lesson of stage 05.
PAYMENT_LATENCY_MS = int(env("PAYMENT_LATENCY_MS", "0"))
PAYMENT_FAIL_RATE = float(env("PAYMENT_FAIL_RATE", "0"))

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " svc=" + SERVICE + " msg=%(message)s",
)
log = logging.getLogger(SERVICE)

app = Flask(__name__)

_lock = threading.Lock()
STATS = {"authorized": 0, "declined": 0, "callers_seen": {}}


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """No dependencies, so readiness is trivially true.

    Note what this does NOT do: it does not get slower when PAYMENT_LATENCY_MS
    is set. A slow service that still passes its health checks is precisely the
    failure that is hard to find — nothing is 'down', everything is late.
    """
    return "ready\n", 200


@app.get("/whoami")
def whoami():
    with _lock:
        stats = {**STATS, "callers_seen": dict(STATS["callers_seen"])}
    return jsonify(
        service=SERVICE,
        pod=POD_NAME,
        dependencies={},
        latency_ms=PAYMENT_LATENCY_MS,
        fail_rate=PAYMENT_FAIL_RATE,
        stats=stats,
    )


# --- the product ----------------------------------------------------------------
@app.post("/api/payments/authorize")
def authorize():
    payload = request.get_json(silent=True) or {}
    try:
        amount = int(payload.get("amount_cents"))
    except (TypeError, ValueError):
        return jsonify(error="amount_cents must be an integer"), 400
    if amount <= 0:
        return jsonify(error="amount_cents must be positive"), 400

    # Record who called. After stage 15 this should only ever be `order` — and
    # this counter is how you PROVE the policy works, rather than trusting it.
    caller = request.headers.get("X-Calling-Service", "unknown")
    with _lock:
        STATS["callers_seen"][caller] = STATS["callers_seen"].get(caller, 0) + 1

    if PAYMENT_LATENCY_MS:
        time.sleep(PAYMENT_LATENCY_MS / 1000.0)

    if PAYMENT_FAIL_RATE and random.random() < PAYMENT_FAIL_RATE:
        with _lock:
            STATS["declined"] += 1
        log.warning("payment declined amount=%s caller=%s", amount, caller)
        return (
            jsonify(
                authorized=False,
                reason="card declined",
                amount_cents=amount,
                served_by=POD_NAME,
            ),
            402,
        )

    with _lock:
        STATS["authorized"] += 1
    reference = f"pay_{uuid.uuid4().hex[:12]}"
    log.info("payment authorized amount=%s ref=%s caller=%s", amount, reference, caller)
    return (
        jsonify(
            authorized=True,
            reference=reference,
            amount_cents=amount,
            served_by=POD_NAME,
        ),
        201,
    )


log.info("payment starting latency_ms=%s fail_rate=%s", PAYMENT_LATENCY_MS, PAYMENT_FAIL_RATE)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
