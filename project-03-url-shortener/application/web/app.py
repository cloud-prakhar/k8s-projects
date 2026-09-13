"""shortener-web — the UI tier of the URL Shortener.

It does three things:
  1. serves the static UI at /
  2. proxies /api/* to shortener-api, server-side
  3. proxies /r/<code> to shortener-api, passing the redirect straight back

WHY proxy instead of the browser calling the API directly? It makes this process
a REAL in-cluster client of shortener-api: it resolves the API by DNS name and
connects over the pod network. In stage 03 that name does not exist yet and you
watch the lookup fail; in stage 04 a Service makes it resolvable. Neither would
be visible if the browser did the calling.

Once the Ingress exists (stage 09) the ALB sends /api and /r straight to the API
and only / comes here. The proxy remains for `kubectl port-forward` sessions.
"""

import logging
import os

import requests
from flask import Flask, Response, request, send_from_directory


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


POD_NAME = env("POD_NAME", "unknown")
APP_ENV = env("APP_ENV", "development")
SHORTENER_API_URL = env("SHORTENER_API_URL", "http://127.0.0.1:8080").rstrip("/")

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " logger=%(name)s msg=%(message)s",
)
log = logging.getLogger("shortener-web")

app = Flask(__name__, static_folder="/static")


# No datastores here, so both probes are trivial on purpose. Do NOT make
# readiness call the API: one slow API would take the whole UI out of service
# with it — a cascading readiness failure.
@app.get("/livez")
def livez():
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    return "ready\n", 200


@app.get("/whoami")
def whoami():
    return f"pod={POD_NAME}\napi={SHORTENER_API_URL}\n", 200


def forward(path: str):
    url = f"{SHORTENER_API_URL}/{path}"
    headers = {
        "Content-Type": request.headers.get("Content-Type", "application/json"),
        # Tell the API which address the USER used, so short URLs point there
        # and not at an in-cluster Service name.
        "X-Forwarded-Host": request.headers.get("X-Forwarded-Host", request.host),
        "X-Forwarded-Proto": request.headers.get("X-Forwarded-Proto", request.scheme),
    }
    try:
        upstream = requests.request(
            method=request.method,
            url=url,
            params=request.args,
            data=request.get_data(),
            headers=headers,
            timeout=5,
            allow_redirects=False,  # a 302 is the answer, not something to follow
        )
    except requests.RequestException as exc:
        # Name the URL that failed. In stage 03 this message contains the DNS
        # error — "Name or service not known" — which is the whole lesson.
        log.error("api unreachable url=%s err=%s", url, exc)
        return Response(
            f"502 — cannot reach the shortener API at {SHORTENER_API_URL}\n\n{exc}\n",
            status=502,
            content_type="text/plain",
        )
    passthrough = {
        k: v
        for k, v in upstream.headers.items()
        if k.lower() in ("location", "x-served-by", "x-cache", "x-click-counted", "x-click-error")
    }
    return Response(
        upstream.content,
        status=upstream.status_code,
        content_type=upstream.headers.get("Content-Type", "application/json"),
        headers=passthrough,
    )


@app.route("/api/<path:subpath>", methods=["GET", "POST"])
def proxy_api(subpath: str):
    return forward(f"api/{subpath}")


@app.get("/r/<code>")
def proxy_redirect(code: str):
    return forward(f"r/{code}")


@app.get("/")
def index():
    return send_from_directory("/static", "index.html")


log.info("shortener-web starting api=%s env=%s", SHORTENER_API_URL, APP_ENV)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
