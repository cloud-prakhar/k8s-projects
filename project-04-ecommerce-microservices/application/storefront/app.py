"""storefront — the UI tier, and the fan-out point of the call graph.

It serves the shop at `/` and proxies `/api/catalog`, `/api/cart` and
`/api/orders` to three separate services, server-side.

WHY proxy instead of letting the browser call each API directly? Because it
makes this process a REAL in-cluster client of three other services: it resolves
each one by DNS name and connects over the pod network. In stage 03 none of
those names exist and you watch the lookups fail; in stage 04 Services make them
resolvable; in stage 15 a NetworkPolicy decides which of them it may still
reach. None of that would be visible if the browser did the calling.

Once the Ingress exists (stage 09) the ALB routes `/api/*` straight to the
backend services by path, and only `/` comes here. The proxy stays for
`kubectl port-forward` sessions and for the east-west traffic it generates.
"""

import logging
import os

import requests
from flask import Flask, Response, jsonify, request, send_from_directory


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
SERVICE = "storefront"

CATALOG_URL = env("CATALOG_URL", "http://127.0.0.1:8080").rstrip("/")
CART_URL = env("CART_URL", "http://127.0.0.1:8080").rstrip("/")
ORDER_URL = env("ORDER_URL", "http://127.0.0.1:8080").rstrip("/")
UPSTREAM_TIMEOUT_SECONDS = float(env("UPSTREAM_TIMEOUT_SECONDS", "3"))

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " svc=" + SERVICE + " msg=%(message)s",
)
log = logging.getLogger(SERVICE)

app = Flask(__name__, static_folder="/static")

UPSTREAMS = {"catalog": CATALOG_URL, "cart": CART_URL, "orders": ORDER_URL}


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Deliberately shallow: it checks NOTHING downstream.

    Make readiness here call the three APIs and one slow catalogue takes the
    entire storefront out of the ALB — a cascading readiness failure, where a
    partial outage becomes a total one. The UI can still render and still report
    which dependency is broken, so it is genuinely ready even when they are not.
    """
    return "ready\n", 200


@app.get("/whoami")
def whoami():
    """Ask every upstream whether it is reachable FROM THIS POD.

    This is the single most useful endpoint in the project once NetworkPolicies
    exist: it answers "which hop is blocked" without exec-ing into anything.
    """
    deps = {}
    for name, url in UPSTREAMS.items():
        ok, err = True, None
        try:
            resp = requests.get(f"{url}/healthz", timeout=UPSTREAM_TIMEOUT_SECONDS)
            ok = resp.ok
            if not resp.ok:
                err = f"HTTP {resp.status_code}"
        except requests.RequestException as exc:
            ok, err = False, first_line(exc)
        deps[name] = {"url": url, "reachable": ok, "error": err}
    return jsonify(service=SERVICE, pod=POD_NAME, dependencies=deps)


# --- proxy ----------------------------------------------------------------------
def forward(base: str, path: str):
    url = f"{base}/{path}"
    try:
        upstream = requests.request(
            method=request.method,
            url=url,
            params=request.args,
            data=request.get_data(),
            headers={
                "Content-Type": request.headers.get("Content-Type", "application/json"),
                "X-Calling-Service": SERVICE,
            },
            timeout=UPSTREAM_TIMEOUT_SECONDS,
            allow_redirects=False,
        )
    except requests.RequestException as exc:
        # Name the URL that failed. In stage 03 this message contains the DNS
        # error — "Name or service not known" — which is the whole lesson. After
        # stage 15 it contains a timeout, which is what a DENIED policy looks
        # like: packets dropped, no reset, no error code.
        log.error("upstream unreachable url=%s err=%s", url, first_line(exc))
        return (
            jsonify(
                error=f"cannot reach {base}",
                detail=first_line(exc),
                service=SERVICE,
                pod=POD_NAME,
            ),
            502,
        )
    return Response(
        upstream.content,
        status=upstream.status_code,
        content_type=upstream.headers.get("Content-Type", "application/json"),
    )


@app.route("/api/catalog/<path:subpath>", methods=["GET"])
def proxy_catalog(subpath: str):
    return forward(CATALOG_URL, f"api/catalog/{subpath}")


@app.route("/api/cart/<path:subpath>", methods=["GET", "POST", "DELETE"])
def proxy_cart(subpath: str):
    return forward(CART_URL, f"api/cart/{subpath}")


@app.route("/api/orders", methods=["GET", "POST"])
def proxy_orders():
    return forward(ORDER_URL, "api/orders")


@app.get("/")
def index():
    return send_from_directory("/static", "index.html")


log.info(
    "storefront starting catalog=%s cart=%s order=%s timeout=%ss",
    CATALOG_URL, CART_URL, ORDER_URL, UPSTREAM_TIMEOUT_SECONDS,
)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
