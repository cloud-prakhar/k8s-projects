"""catalog — the product catalogue.

Owns the `catalog` database and nothing else. No other service reads its tables;
`order` copies the price it was quoted onto the order row rather than joining
across a boundary it does not own.

This service is one of only two that may reach PostgreSQL. Stage 15 enforces
that with a NetworkPolicy; until then, any pod in the cluster can connect to the
database, which is the problem that stage exists to solve.
"""

import logging
import os
import threading

import psycopg
from flask import Flask, jsonify

import migrations


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
SERVICE = "catalog"

POSTGRES_HOST = env("POSTGRES_HOST", "127.0.0.1")
POSTGRES_PORT = env("POSTGRES_PORT", "5432")
POSTGRES_DB = env("POSTGRES_DB", "catalog")
POSTGRES_USER = env("POSTGRES_USER", "ecommerce")
POSTGRES_PASSWORD = env("POSTGRES_PASSWORD", "")

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


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


def pg():
    # One connection per call. A pool would pin to one backend and hide both
    # load balancing and policy changes; this way a NetworkPolicy you just
    # applied shows up on the very next request.
    return psycopg.connect(DSN)


def db_error(exc: Exception):
    """Name the dependency that failed. With five services, 'something 500'd' is
    useless — every tier here says what IT could not reach."""
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
    """Liveness: is this PROCESS answering? Touches no dependency, ever — a
    database blip must never restart every catalog pod at once."""
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Readiness: can this pod do its job right now? PostgreSQL is a HARD
    dependency of the catalogue, so it belongs here."""
    try:
        with pg() as conn:
            conn.execute("SELECT 1")
        return "ready\n", 200
    except psycopg.Error as exc:
        log.warning("readiness failing: %s", first_line(exc))
        return f"database unreachable: {first_line(exc)}\n", 503


@app.get("/whoami")
def whoami():
    """Who am I and what can I see? With five services and a default-deny
    NetworkPolicy, this is the fastest way to find which hop is blocked."""
    reachable, err = True, None
    try:
        with pg() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error as exc:
        reachable, err = False, first_line(exc)
    return jsonify(
        service=SERVICE,
        pod=POD_NAME,
        dependencies={
            "postgres": {
                "host": POSTGRES_HOST,
                "db": POSTGRES_DB,
                "reachable": reachable,
                "error": err,
            }
        },
    )


# --- the product ----------------------------------------------------------------
@app.get("/api/catalog/products")
def list_products():
    try:
        with pg() as conn:
            rows = conn.execute(
                "SELECT sku, name, price_cents FROM products ORDER BY sku"
            ).fetchall()
    except psycopg.Error as exc:
        return db_error(exc)
    return jsonify([{"sku": s, "name": n, "price_cents": p} for s, n, p in rows])


@app.get("/api/catalog/products/<sku>")
def get_product(sku: str):
    try:
        with pg() as conn:
            row = conn.execute(
                "SELECT sku, name, price_cents FROM products WHERE sku = %s", (sku,)
            ).fetchone()
    except psycopg.Error as exc:
        return db_error(exc)
    if row is None:
        return jsonify(error="no such product", sku=sku, service=SERVICE), 404
    return jsonify(sku=row[0], name=row[1], price_cents=row[2], served_by=POD_NAME)


log.info("catalog starting postgres=%s db=%s", POSTGRES_HOST, POSTGRES_DB)

# Stages 03–09: every replica migrates on start-up; the advisory lock makes that
# safe. Stage 11 moves it into an init container and sets RUN_MIGRATIONS=false.
# In a background thread so a missing database delays readiness, not start-up.
if env("RUN_MIGRATIONS", "true").lower() == "true":
    threading.Thread(target=migrations.run, args=(DSN,), daemon=True).start()
else:
    log.info("RUN_MIGRATIONS=false — the schema is owned by the init container")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
