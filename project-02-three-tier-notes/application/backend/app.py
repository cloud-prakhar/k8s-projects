"""notes-api — the middle tier of the Notes Platform.

Unlike Project 01's API, this one keeps NOTHING in memory. Every note lives in
PostgreSQL. That is the entire point of this project: the moment state leaves
the process, you have to answer "where does the data actually live, and what
happens when the pod that holds it is deleted?"

Everything this process needs comes from the environment:

    POSTGRES_HOST / PORT / DB / USER   ← hardcoded (stage 03) → ConfigMap (stage 05)
    POSTGRES_PASSWORD                  ← hardcoded (stage 03) → Secret    (stage 06)
    POD_NAME                           ← Downward API, so you can see WHICH pod answered

The image never changes between stages. Only the environment does — which is
exactly what makes ConfigMaps and Secrets teachable rather than theoretical.
"""

import logging
import os
import time

import psycopg
from flask import Flask, jsonify, request


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


APP_ENV = env("APP_ENV", "development")
LOG_LEVEL = env("LOG_LEVEL", "info")

DB_HOST = env("POSTGRES_HOST", "127.0.0.1")
DB_PORT = env("POSTGRES_PORT", "5432")
DB_NAME = env("POSTGRES_DB", "notes")
DB_USER = env("POSTGRES_USER", "notes")
DB_PASSWORD = env("POSTGRES_PASSWORD", "")

POD_NAME = env("POD_NAME", "unknown")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format="level=%(levelname)s pod=" + POD_NAME + " msg=%(message)s",
)
log = logging.getLogger("notes-api")

app = Flask(__name__)

# Built once. libpq reads it per connection; nothing is cached across restarts,
# so a pod that starts before Postgres is reachable simply fails and is retried.
DSN = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD} connect_timeout=3"
)


def connect():
    """One short-lived connection per request.

    A real service would use a pool. Short-lived connections are used here on
    purpose: they mean every single request re-resolves the database Service by
    DNS and re-connects, so when you delete the Postgres pod you SEE the
    failure immediately instead of watching a stale pooled socket hang.
    """
    return psycopg.connect(DSN)


SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    id         SERIAL PRIMARY KEY,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def ensure_schema(attempts: int = 30, delay: float = 2.0) -> bool:
    """Create the table if it isn't there yet, retrying while Postgres boots.

    Postgres takes a few seconds to accept connections. Without this retry the
    API would crash on a cold start and land in CrashLoopBackOff — which is
    precisely the failure that motivates the init container in stage 11. The
    retry here is deliberately SHORT so that a genuinely unreachable database
    still fails loudly rather than hanging forever.
    """
    for attempt in range(1, attempts + 1):
        try:
            with connect() as conn, conn.cursor() as cur:
                cur.execute(SCHEMA)
                conn.commit()
            log.info("schema ready host=%s db=%s", DB_HOST, DB_NAME)
            return True
        except Exception as exc:  # noqa: BLE001 — any driver error means "not yet"
            log.warning(
                "database not ready attempt=%s/%s host=%s err=%s",
                attempt, attempts, DB_HOST, exc,
            )
            time.sleep(delay)
    log.error("giving up waiting for the database at %s:%s", DB_HOST, DB_PORT)
    return False


# --- health endpoints ------------------------------------------------------
# Two SEPARATE endpoints, and the difference matters more here than in a
# stateless app (stage 11 explains it in full):
#
#   /livez   — "is this PROCESS alive?"     Deliberately does NOT touch the DB.
#   /healthz — "can I serve requests NOW?"  Requires a working DB connection.
#
# Putting the database check in the liveness probe is the classic self-inflicted
# outage: Postgres blips, every API pod is declared dead and restarted, and the
# restart storm outlives the blip.
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return "ready\n", 200
    except Exception as exc:  # noqa: BLE001
        log.warning("readiness failing: %s", exc)
        return f"database unreachable: {exc}\n", 503


# --- info: proves which pod answered, and where its data lives -------------
@app.get("/api/info")
def info():
    note_count, db_ok, db_error = None, False, None
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM notes")
            note_count = cur.fetchone()[0]
        db_ok = True
    except Exception as exc:  # noqa: BLE001
        db_error = str(exc).strip().splitlines()[0] if str(exc).strip() else "unknown"
    return jsonify(
        pod=POD_NAME,
        app_env=APP_ENV,
        log_level=LOG_LEVEL,
        db_host=DB_HOST,
        db_name=DB_NAME,
        db_user=DB_USER,
        db_connected=db_ok,
        db_error=db_error,
        note_count=note_count,
    )


# --- notes -----------------------------------------------------------------
def db_error_response(exc: Exception):
    """Say WHICH database could not be reached.

    Half of Kubernetes debugging is discovering what the app was actually
    trying to connect to. A bare "500 Internal Server Error" tells you nothing.
    """
    log.error("database error host=%s err=%s", DB_HOST, exc)
    return jsonify(error=f"cannot reach postgres at {DB_HOST}:{DB_PORT}", detail=str(exc)), 503


@app.get("/api/notes")
def list_notes():
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, body, created_at FROM notes ORDER BY id")
            rows = cur.fetchall()
    except Exception as exc:  # noqa: BLE001
        return db_error_response(exc)
    return jsonify([
        {"id": r[0], "body": r[1], "created_at": r[2].isoformat()} for r in rows
    ])


@app.post("/api/notes")
def create_note():
    payload = request.get_json(silent=True) or {}
    body = (payload.get("body") or "").strip()
    if not body:
        return jsonify(error="body is required"), 400
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO notes (body) VALUES (%s) RETURNING id, created_at",
                (body,),
            )
            note_id, created_at = cur.fetchone()
            conn.commit()
    except Exception as exc:  # noqa: BLE001
        return db_error_response(exc)
    log.debug("note created id=%s", note_id)
    return jsonify(id=note_id, body=body, created_at=created_at.isoformat()), 201


@app.delete("/api/notes")
def delete_note():
    try:
        note_id = int(request.args.get("id", ""))
    except ValueError:
        return jsonify(error="no such note"), 404
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("DELETE FROM notes WHERE id = %s", (note_id,))
            deleted = cur.rowcount
            conn.commit()
    except Exception as exc:  # noqa: BLE001
        return db_error_response(exc)
    return ("", 204) if deleted else (jsonify(error="no such note"), 404)


log.info("notes-api starting env=%s db=%s@%s:%s/%s",
         APP_ENV, DB_USER, DB_HOST, DB_PORT, DB_NAME)
ensure_schema()

if __name__ == "__main__":
    # Development only. In the container gunicorn serves this app — Flask's
    # built-in server is single-threaded and explicitly not for production.
    # 0.0.0.0, NOT 127.0.0.1: a container bound to loopback is unreachable from
    # anywhere else in the cluster, and the failure is completely silent.
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
