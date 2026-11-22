"""order — places orders. The only service that may call `payment`.

It is the busiest node in the call graph, which makes it the best place to watch
east-west traffic behave:

  * it owns the `orders` database (its own database inside the shared
    PostgreSQL — no service reads another's tables);
  * it calls `payment` over cluster DNS, and is the ONLY service permitted to;
  * it copies the price it was quoted onto the order row instead of joining into
    the catalogue, because that data belongs to another service.

It is also where the cascading failure shows up. When `payment` is slow, every
request here blocks — which is why UPSTREAM_TIMEOUT_SECONDS exists, and why a
bounded timeout is the difference between "checkout is slow" and "the site is
down".
"""

import logging
import os
import json
import threading

import psycopg
import requests
from flask import Flask, jsonify, request

import migrations


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
SERVICE = "order"

POSTGRES_HOST = env("POSTGRES_HOST", "127.0.0.1")
POSTGRES_PORT = env("POSTGRES_PORT", "5432")
POSTGRES_DB = env("POSTGRES_DB", "orders")
POSTGRES_USER = env("POSTGRES_USER", "ecommerce")
POSTGRES_PASSWORD = env("POSTGRES_PASSWORD", "")

PAYMENT_URL = env("PAYMENT_URL", "http://127.0.0.1:8080").rstrip("/")
UPSTREAM_TIMEOUT_SECONDS = float(env("UPSTREAM_TIMEOUT_SECONDS", "3"))

DSN = (
    f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
    f"user={POSTGRES_USER} password={POSTGRES_PASSWORD} connect_timeout=3"
)

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " svc=" + SERVICE + " msg=%(message)s",
)
log = logging.getLogger(SERVICE)

app = Flask(__name__)

_lock = threading.Lock()
STATS = {"payment_failures": 0, "payment_last_error": None}


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


def pg():
    return psycopg.connect(DSN)


def db_error(exc: Exception):
    log.error("database error host=%s err=%s", POSTGRES_HOST, first_line(exc))
    return (
        jsonify(
            error=f"cannot reach postgres at {POSTGRES_HOST}:{POSTGRES_PORT}",
            detail=first_line(exc),
            service=SERVICE,
            pod=POD_NAME,
        ),
        503,
    )


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Readiness gates on PostgreSQL only — NOT on `payment`.

    If readiness called `payment`, then a payment outage would pull every order
    pod out of the ALB and turn a broken checkout button into a hard 503 for
    every order request. Readiness must reflect what this pod cannot work
    without, not everything it ever talks to.
    """
    try:
        with pg() as conn:
            conn.execute("SELECT 1")
        return "ready\n", 200
    except psycopg.Error as exc:
        log.warning("readiness failing: %s", first_line(exc))
        return f"database unreachable: {first_line(exc)}\n", 503


@app.get("/whoami")
def whoami():
    db_ok, db_err = True, None
    try:
        with pg() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error as exc:
        db_ok, db_err = False, first_line(exc)

    # Probe payment with a HEAD-ish health call so `/whoami` reports the whole
    # dependency chain. This is the endpoint you curl when a NetworkPolicy has
    # broken something and you need to know WHICH hop.
    pay_ok, pay_err = True, None
    try:
        resp = requests.get(f"{PAYMENT_URL}/healthz", timeout=UPSTREAM_TIMEOUT_SECONDS)
        pay_ok = resp.ok
        if not resp.ok:
            pay_err = f"HTTP {resp.status_code}"
    except requests.RequestException as exc:
        pay_ok, pay_err = False, first_line(exc)

    with _lock:
        stats = dict(STATS)
    return jsonify(
        service=SERVICE,
        pod=POD_NAME,
        dependencies={
            "postgres": {
                "host": POSTGRES_HOST,
                "db": POSTGRES_DB,
                "reachable": db_ok,
                "error": db_err,
            },
            "payment": {"url": PAYMENT_URL, "reachable": pay_ok, "error": pay_err},
        },
        upstream_timeout_seconds=UPSTREAM_TIMEOUT_SECONDS,
        stats=stats,
    )


# --- the product ----------------------------------------------------------------
@app.post("/api/orders")
def create_order():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session", "")).strip()
    items = payload.get("items") or []
    if not session or not isinstance(items, list) or not items:
        return jsonify(error="session and a non-empty items array are required"), 400

    try:
        total = sum(int(i["price_cents"]) * int(i["quantity"]) for i in items)
    except (KeyError, TypeError, ValueError):
        return jsonify(error="each item needs integer price_cents and quantity"), 400
    if total <= 0:
        return jsonify(error="order total must be positive"), 400

    # Call payment. The timeout is the whole defence against a slow upstream:
    # without it this request blocks for as long as payment feels like taking,
    # and every storefront request waiting on it blocks too.
    try:
        resp = requests.post(
            f"{PAYMENT_URL}/api/payments/authorize",
            json={"amount_cents": total},
            headers={"X-Calling-Service": SERVICE},
            timeout=UPSTREAM_TIMEOUT_SECONDS,
        )
    except requests.RequestException as exc:
        with _lock:
            STATS["payment_failures"] += 1
            STATS["payment_last_error"] = first_line(exc)
        log.error("payment unreachable url=%s err=%s", PAYMENT_URL, first_line(exc))
        return (
            jsonify(
                error=f"cannot reach payment at {PAYMENT_URL}",
                detail=first_line(exc),
                service=SERVICE,
                pod=POD_NAME,
            ),
            502,
        )

    if resp.status_code != 201:
        body = resp.json() if resp.headers.get("Content-Type", "").startswith("application/json") else {}
        with _lock:
            STATS["payment_failures"] += 1
            STATS["payment_last_error"] = body.get("reason", f"HTTP {resp.status_code}")
        return (
            jsonify(
                error="payment was not authorized",
                reason=body.get("reason", f"HTTP {resp.status_code}"),
                service=SERVICE,
                pod=POD_NAME,
            ),
            402,
        )

    reference = resp.json().get("reference", "unknown")

    try:
        with pg() as conn:
            row = conn.execute(
                "INSERT INTO orders (session, total_cents, payment_ref, items) "
                "VALUES (%s, %s, %s, %s) RETURNING id, created_at",
                (session, total, reference, json.dumps(items)),
            ).fetchone()
    except psycopg.Error as exc:
        # The payment succeeded and the order did not persist. Say so loudly —
        # silently swallowing this is how real money goes missing.
        log.error("ORDER LOST after successful payment ref=%s err=%s", reference, first_line(exc))
        return db_error(exc)

    log.info("order created id=%s total=%s ref=%s", row[0], total, reference)
    return (
        jsonify(
            id=row[0],
            session=session,
            total_cents=total,
            payment_ref=reference,
            created_at=row[1].isoformat(),
            served_by=POD_NAME,
        ),
        201,
    )


@app.get("/api/orders")
def list_orders():
    try:
        with pg() as conn:
            rows = conn.execute(
                "SELECT id, session, total_cents, payment_ref, created_at "
                "FROM orders ORDER BY created_at DESC LIMIT 20"
            ).fetchall()
    except psycopg.Error as exc:
        return db_error(exc)
    return jsonify(
        [
            {
                "id": i,
                "session": s,
                "total_cents": t,
                "payment_ref": p,
                "created_at": c.isoformat(),
            }
            for i, s, t, p, c in rows
        ]
    )


log.info(
    "order starting postgres=%s db=%s payment=%s timeout=%ss",
    POSTGRES_HOST, POSTGRES_DB, PAYMENT_URL, UPSTREAM_TIMEOUT_SECONDS,
)

# Stages 03–09: every replica migrates on start-up (the advisory lock makes it
# safe). Stage 11 moves it into an init container and sets RUN_MIGRATIONS=false.
if env("RUN_MIGRATIONS", "true").lower() == "true":
    threading.Thread(target=migrations.run, args=(DSN,), daemon=True).start()
else:
    log.info("RUN_MIGRATIONS=false — the schema is owned by the init container")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
