"""shortener-api — turns long URLs into short codes, and short codes back into redirects.

Two datastores, with genuinely different jobs:

    PostgreSQL — the SOURCE OF TRUTH. Every link is a row. Lose Redis and every
                 link still works.
    Redis      — the FAST PATH. A cache of code → URL in front of PostgreSQL,
                 and the click counters. Lose Redis and redirects still work,
                 just slower and uncounted.

That asymmetry is designed in, and it decides the Kubernetes objects: readiness
depends on PostgreSQL only, and every Redis call is allowed to fail.

Every Redis and PostgreSQL call opens a NEW connection. A real service would
pool. Here, short-lived connections mean every request re-resolves DNS and goes
back through the Service's load balancing — so when a Service points at the
wrong pods, you see it on the very next request instead of never.
"""

import logging
import secrets
import string
import threading
from urllib.parse import urlparse

import psycopg
import redis
import requests
from flask import Flask, jsonify, redirect, request

import migrations
import settings as S

logging.basicConfig(
    level=getattr(logging, S.LOG_LEVEL.upper(), logging.INFO),
    format="level=%(levelname)s pod=" + S.POD_NAME + " logger=%(name)s msg=%(message)s",
)
log = logging.getLogger("shortener-api")

app = Flask(__name__)

ALPHABET = string.ascii_letters + string.digits

# Diagnostics only — held per process, reset on restart. gunicorn runs ONE worker
# in this image precisely so these numbers mean something when you read them.
_lock = threading.Lock()
STATS = {
    "redis_write_errors": 0,
    "redis_last_write_error": None,
    "analytics_sent": 0,
    "analytics_failed": 0,
    "analytics_last_status": None,
    "analytics_last_error": None,
}


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


# --- datastore helpers --------------------------------------------------------
def pg():
    return psycopg.connect(S.DSN)


def redis_client(host: str) -> redis.Redis:
    # Timeouts of one second: a cache that is slow is a cache that is down.
    return redis.Redis(
        host=host,
        port=S.REDIS_PORT,
        password=S.REDIS_PASSWORD or None,
        socket_connect_timeout=1,
        socket_timeout=1,
        decode_responses=True,
    )


def redis_read(fn):
    """Run fn against the READ host. Returns (value, error)."""
    try:
        with redis_client(S.REDIS_READ_HOST) as r:
            return fn(r), None
    except redis.RedisError as exc:
        log.warning("redis read failed host=%s err=%s", S.REDIS_READ_HOST, first_line(exc))
        return None, exc


def redis_write(fn):
    """Run fn against the WRITE host. Returns (value, error).

    A write that lands on a replica fails with `ReadOnlyError: You can't write
    against a read only replica`. That is the error stage 08 produces on purpose
    by pointing writes at a load-balanced Service in front of a primary AND a
    replica.
    """
    try:
        with redis_client(S.REDIS_WRITE_HOST) as r:
            return fn(r), None
    except redis.RedisError as exc:
        with _lock:
            STATS["redis_write_errors"] += 1
            STATS["redis_last_write_error"] = first_line(exc)
        log.warning("redis write failed host=%s err=%s", S.REDIS_WRITE_HOST, first_line(exc))
        return None, exc


def db_error_response(exc: Exception):
    """Say WHICH database could not be reached — half of debugging is finding out."""
    log.error("database error host=%s err=%s", S.POSTGRES_HOST, first_line(exc))
    return (
        jsonify(
            error=f"cannot reach postgres at {S.POSTGRES_HOST}:{S.POSTGRES_PORT}",
            detail=first_line(exc),
            pod=S.POD_NAME,
        ),
        503,
    )


def base_url() -> str:
    if S.PUBLIC_BASE_URL:
        return S.PUBLIC_BASE_URL
    # X-Forwarded-* are set by the web tier's proxy and by the ALB, so the short
    # URL uses the address the USER typed, not an in-cluster Service name.
    proto = request.headers.get("X-Forwarded-Proto", request.scheme)
    host = request.headers.get("X-Forwarded-Host", request.host)
    return f"{proto}://{host}"


def valid_code(code: str) -> bool:
    return len(code) == S.CODE_LENGTH and all(c in ALPHABET for c in code)


# --- analytics: fire-and-forget, never allowed to slow a redirect -------------
def send_click_event(code: str) -> None:
    if not S.ANALYTICS_URL:
        return

    def _post():
        try:
            resp = requests.post(
                S.ANALYTICS_URL,
                json={"type": "click", "code": code, "pod": S.POD_NAME},
                timeout=2,
            )
            with _lock:
                STATS["analytics_sent"] += 1
                STATS["analytics_last_status"] = resp.status_code
        except requests.RequestException as exc:
            with _lock:
                STATS["analytics_failed"] += 1
                STATS["analytics_last_error"] = first_line(exc)
            log.warning("analytics unreachable url=%s err=%s", S.ANALYTICS_URL, first_line(exc))

    threading.Thread(target=_post, daemon=True).start()


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    """Liveness: is this PROCESS answering? Touches nothing else, ever."""
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Readiness: can this pod do its job right now?

    PostgreSQL only. Redis is deliberately NOT checked: the API works without
    it, so a Redis outage must not pull every API pod out of the Service and
    turn a degraded service into a total outage. Readiness should gate on HARD
    dependencies only.
    """
    try:
        with pg() as conn:
            conn.execute("SELECT 1")
        return "ready\n", 200
    except psycopg.Error as exc:
        log.warning("readiness failing: %s", first_line(exc))
        return f"database unreachable: {first_line(exc)}\n", 503


# --- the product ----------------------------------------------------------------
@app.post("/api/links")
def create_link():
    payload = request.get_json(silent=True) or {}
    url = (payload.get("url") or "").strip()
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return jsonify(error="url must be an absolute http(s) URL"), 400

    row, code = None, None
    try:
        with pg() as conn:
            for _ in range(5):  # collisions are astronomically rare; retry anyway
                code = "".join(secrets.choice(ALPHABET) for _ in range(S.CODE_LENGTH))
                row = conn.execute(
                    "INSERT INTO links (code, target_url) VALUES (%s, %s) "
                    "ON CONFLICT (code) DO NOTHING RETURNING created_at",
                    (code, url),
                ).fetchone()
                if row:
                    break
    except psycopg.Error as exc:
        return db_error_response(exc)
    if not row:
        return jsonify(error="could not allocate a unique code"), 503

    # Warm the cache. If Redis is down the link still exists — that is the point.
    redis_write(lambda r: r.set(f"link:{code}", url, ex=S.CACHE_TTL_SECONDS))
    log.info("link created code=%s", code)
    return (
        jsonify(
            code=code,
            short_url=f"{base_url()}/r/{code}",
            target_url=url,
            created_at=row[0].isoformat(),
            pod=S.POD_NAME,
        ),
        201,
    )


@app.get("/api/links")
def list_links():
    try:
        with pg() as conn:
            rows = conn.execute(
                "SELECT code, target_url, created_at FROM links ORDER BY created_at DESC LIMIT 20"
            ).fetchall()
    except psycopg.Error as exc:
        return db_error_response(exc)

    clicks = [None] * len(rows)
    if rows:
        values, _ = redis_read(lambda r: r.mget([f"clicks:{c}" for c, _, _ in rows]))
        if values is not None:
            clicks = [int(v) if v is not None else 0 for v in values]
    return jsonify(
        [
            {
                "code": c,
                "short_url": f"{base_url()}/r/{c}",
                "target_url": t,
                "created_at": created.isoformat(),
                "clicks": n,  # null = Redis unreachable, not zero
            }
            for (c, t, created), n in zip(rows, clicks)
        ]
    )


@app.get("/api/links/<code>")
def link_stats(code: str):
    try:
        with pg() as conn:
            row = conn.execute(
                "SELECT target_url, created_at FROM links WHERE code = %s", (code,)
            ).fetchone()
    except psycopg.Error as exc:
        return db_error_response(exc)
    if row is None:
        return jsonify(error="no such link", code=code), 404
    stats, err = redis_read(lambda r: (r.get(f"clicks:{code}"), r.ttl(f"link:{code}")))
    clicks, ttl = stats if stats else (None, None)
    return jsonify(
        code=code,
        target_url=row[0],
        created_at=row[1].isoformat(),
        clicks=int(clicks) if clicks is not None else (0 if err is None else None),
        cache_ttl_remaining=ttl if ttl is not None and ttl >= 0 else None,
        redis_error=first_line(err) if err else None,
        pod=S.POD_NAME,
    )


@app.get("/r/<code>")
def follow(code: str):
    # Reject anything that is not a well-formed code BEFORE touching a
    # datastore. It also means replicas with different CODE_LENGTH values
    # reject each other's links — stage 05's config-drift outage.
    if not valid_code(code):
        return (
            jsonify(
                error=f"'{code}' is not a valid code",
                expected_length=S.CODE_LENGTH,
                pod=S.POD_NAME,
            ),
            404,
        )

    target, _ = redis_read(lambda r: r.get(f"link:{code}"))
    cache = "HIT"
    if target is None:
        cache = "MISS"
        try:
            with pg() as conn:
                row = conn.execute(
                    "SELECT target_url FROM links WHERE code = %s", (code,)
                ).fetchone()
        except psycopg.Error as exc:
            return db_error_response(exc)
        if row is None:
            return jsonify(error="no such link", code=code, pod=S.POD_NAME), 404
        target = row[0]
        redis_write(lambda r: r.set(f"link:{code}", target, ex=S.CACHE_TTL_SECONDS))

    _, click_err = redis_write(lambda r: r.incr(f"clicks:{code}"))
    send_click_event(code)

    resp = redirect(target, code=302)
    # Headers you can read with `curl -sI` — the whole data path of one request.
    resp.headers["X-Served-By"] = S.POD_NAME
    resp.headers["X-Cache"] = cache
    resp.headers["X-Click-Counted"] = "false" if click_err else "true"
    if click_err:
        resp.headers["X-Click-Error"] = first_line(click_err).replace("\n", " ")[:150]
    return resp


# --- introspection: which pod, which config, which Redis member ---------------
def redis_member(host: str) -> dict:
    def probe(r):
        repl = r.info("replication")
        return {
            "role": repl.get("role"),  # "master" or "slave" (Redis's own words)
            "primary_host": repl.get("master_host"),
            "connected_replicas": repl.get("connected_slaves"),
        }

    try:
        with redis_client(host) as r:
            return {"host": host, "reachable": True, **probe(r)}
    except redis.RedisError as exc:
        return {"host": host, "reachable": False, "error": first_line(exc)}


@app.get("/api/info")
def info():
    link_count, db_ok, db_error = None, False, None
    try:
        with pg() as conn:
            link_count = conn.execute("SELECT count(*) FROM links").fetchone()[0]
        db_ok = True
    except psycopg.Error as exc:
        db_error = first_line(exc)
    with _lock:
        stats = dict(STATS)
    return jsonify(
        pod=S.POD_NAME,
        app_env=S.APP_ENV,
        config_version=S.CONFIG_VERSION,
        code_length=S.CODE_LENGTH,
        cache_ttl_seconds=S.CACHE_TTL_SECONDS,
        postgres={
            "host": S.POSTGRES_HOST,
            "db": S.POSTGRES_DB,
            "connected": db_ok,
            "error": db_error,
            "link_count": link_count,
        },
        redis_write=redis_member(S.REDIS_WRITE_HOST),
        redis_read=redis_member(S.REDIS_READ_HOST),
        analytics_url=S.ANALYTICS_URL or None,
        stats=stats,
    )


log.info(
    "shortener-api starting env=%s config=%s code_length=%s postgres=%s redis_write=%s redis_read=%s analytics=%s",
    S.APP_ENV, S.CONFIG_VERSION, S.CODE_LENGTH, S.POSTGRES_HOST,
    S.REDIS_WRITE_HOST, S.REDIS_READ_HOST, S.ANALYTICS_URL or "-",
)

if S.RUN_MIGRATIONS:
    # Stages 03–09: every replica migrates its own schema on start-up. The
    # advisory lock keeps that safe; stage 11 explains why it is still the
    # wrong place, and moves it into an init container.
    migrations.run(S.DSN, attempts=30)
else:
    log.info("RUN_MIGRATIONS=false — the schema is owned by the init container")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(S.env("PORT", "8080")))
