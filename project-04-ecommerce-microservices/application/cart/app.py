"""cart — session baskets, held in Redis with a TTL.

The only service allowed to reach Redis. That is not an arbitrary rule for the
lab: a cart is ephemeral, per-session state that nothing else owns, so a
NetworkPolicy naming exactly one client is easy to justify and easy to verify.

Redis is a HARD dependency here, unlike the cache in Project 03 — losing it
means losing the basket, so `/healthz` checks it and the pod leaves the load
balancer when it is gone. Compare that with `storefront`, whose readiness
deliberately checks nothing.
"""

import json
import logging
import os

import redis
from flask import Flask, jsonify, request


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
SERVICE = "cart"

REDIS_HOST = env("REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(env("REDIS_PORT", "6379"))
REDIS_PASSWORD = env("REDIS_PASSWORD", "")
CART_TTL_SECONDS = int(env("CART_TTL_SECONDS", "1800"))

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " svc=" + SERVICE + " msg=%(message)s",
)
log = logging.getLogger(SERVICE)

app = Flask(__name__)


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


def r() -> redis.Redis:
    # One connection per call, and a one-second budget. Short-lived connections
    # mean every request re-resolves DNS and re-crosses the policy boundary, so
    # a NetworkPolicy you just applied shows up on the very next request.
    return redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        password=REDIS_PASSWORD or None,
        socket_connect_timeout=1,
        socket_timeout=1,
        decode_responses=True,
    )


def redis_error(exc: Exception):
    log.error("redis error host=%s err=%s", REDIS_HOST, first_line(exc))
    return (
        jsonify(
            error=f"cannot reach redis at {REDIS_HOST}:{REDIS_PORT}",
            detail=first_line(exc),
            service=SERVICE,
            pod=POD_NAME,
        ),
        503,
    )


def key(session: str) -> str:
    return f"cart:{session}"


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Readiness: Redis IS the cart. Without it this pod cannot serve, so it
    should leave the Service's endpoints until Redis returns."""
    try:
        with r() as c:
            c.ping()
        return "ready\n", 200
    except redis.RedisError as exc:
        log.warning("readiness failing: %s", first_line(exc))
        return f"redis unreachable: {first_line(exc)}\n", 503


@app.get("/whoami")
def whoami():
    reachable, err = True, None
    try:
        with r() as c:
            c.ping()
    except redis.RedisError as exc:
        reachable, err = False, first_line(exc)
    return jsonify(
        service=SERVICE,
        pod=POD_NAME,
        dependencies={
            "redis": {"host": REDIS_HOST, "reachable": reachable, "error": err},
        },
        cart_ttl_seconds=CART_TTL_SECONDS,
    )


# --- the product ----------------------------------------------------------------
@app.get("/api/cart/<session>")
def get_cart(session: str):
    try:
        with r() as c:
            raw = c.get(key(session))
            ttl = c.ttl(key(session))
    except redis.RedisError as exc:
        return redis_error(exc)
    items = json.loads(raw) if raw else []
    return jsonify(
        session=session,
        items=items,
        total_cents=sum(i["price_cents"] * i["quantity"] for i in items),
        expires_in_seconds=ttl if ttl and ttl >= 0 else None,
        served_by=POD_NAME,
    )


@app.post("/api/cart/<session>")
def add_item(session: str):
    payload = request.get_json(silent=True) or {}
    sku = str(payload.get("sku", "")).strip()
    name = str(payload.get("name", "")).strip() or sku
    try:
        price = int(payload.get("price_cents"))
        quantity = int(payload.get("quantity", 1))
    except (TypeError, ValueError):
        return jsonify(error="price_cents and quantity must be integers"), 400
    if not sku or price < 0 or quantity < 1:
        return jsonify(error="sku, a non-negative price_cents and quantity >= 1 are required"), 400

    try:
        with r() as c:
            raw = c.get(key(session))
            items = json.loads(raw) if raw else []
            for item in items:
                if item["sku"] == sku:
                    item["quantity"] += quantity
                    break
            else:
                items.append(
                    {"sku": sku, "name": name, "price_cents": price, "quantity": quantity}
                )
            # SETEX: every write refreshes the TTL, so an active basket does not
            # expire under the shopper.
            c.set(key(session), json.dumps(items), ex=CART_TTL_SECONDS)
    except redis.RedisError as exc:
        return redis_error(exc)

    log.info("cart updated session=%s sku=%s qty=%s", session, sku, quantity)
    return jsonify(session=session, items=items, served_by=POD_NAME), 201


@app.delete("/api/cart/<session>")
def clear_cart(session: str):
    try:
        with r() as c:
            c.delete(key(session))
    except redis.RedisError as exc:
        return redis_error(exc)
    return jsonify(session=session, items=[], served_by=POD_NAME)


log.info("cart starting redis=%s ttl=%ss", REDIS_HOST, CART_TTL_SECONDS)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
