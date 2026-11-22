"""webapp — a traffic-serving web app whose capacity you can SEE.

Project 05 is about resources, autoscaling, disruption and rollouts. Those are
abstract until the application gives you dials that make them visible:

  GET /api/work?ms=N      burn N ms of CPU in this request     → requests/limits,
                                                                  throttling, HPA
  GET /api/memory?mb=N    allocate and HOLD N MiB in this worker → memory limits,
                                                                  OOMKilled
  GET /api/memory/release free it again
  GET /api/slow?seconds=N hold a request open N s (no CPU)     → graceful shutdown,
                                                                  terminationGracePeriodSeconds
  STARTUP_DELAY_SECONDS   sleep before serving at all          → startup probes

and three endpoints for Kubernetes itself:

  GET /livez     liveness — the process answers. Nothing else, ever.
  GET /healthz   readiness — startup finished, and not shutting down
  GET /metrics   Prometheus text format: requests by code, in-flight, CPU work

The image VERSION is baked in at build time (1.0.0 vs 2.0.0), so a rollout is a
real change of image, and every response says which version and which pod
served it — which is how you watch a rolling update, a canary, or a blue/green
switch happen request by request.
"""

import logging
import os
import socket
import threading
import time

from flask import Flask, Response, jsonify, request


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


VERSION = env("APP_VERSION", "dev")          # baked into the image via build-arg
COLOR = env("APP_COLOR", "")                  # optional visual marker (canary/blue-green)
POD_NAME = env("POD_NAME", socket.gethostname())
NODE_NAME = env("NODE_NAME", "unknown")       # Downward API: spec.nodeName
STARTUP_DELAY_SECONDS = float(env("STARTUP_DELAY_SECONDS", "0"))
MAX_WORK_MS = int(env("MAX_WORK_MS", "2000"))
MAX_MEMORY_MB = int(env("MAX_MEMORY_MB", "1024"))

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " pid=%(process)d msg=%(message)s",
)
log = logging.getLogger("webapp")

app = Flask(__name__)

_lock = threading.Lock()
STARTED_AT = time.time()
READY_AT = STARTED_AT + STARTUP_DELAY_SECONDS
STATS = {"requests": {}, "in_flight": 0, "cpu_work_ms": 0}
_held_memory: list = []   # per worker process — gunicorn workers do not share memory


def ready() -> bool:
    return time.time() >= READY_AT


# Probes and metrics must answer during warm-up; everything else must not.
ALWAYS_SERVED = {"/livez", "/healthz", "/metrics"}


@app.before_request
def _count_in():
    with _lock:
        STATS["in_flight"] += 1
    # A warming-up app cannot do real work yet (caches empty, pools not open).
    # Returning 503 until READY_AT is what makes "traffic sent before the pod is
    # ready" VISIBLE: without a readiness probe, a Service or ALB will route real
    # requests here during these seconds, and the client sees the 503s.
    if not ready() and request.path not in ALWAYS_SERVED:
        return Response(f"503 — warming up, ready in {READY_AT - time.time():.1f}s\n",
                        status=503, content_type="text/plain")


@app.after_request
def _count_out(resp):
    with _lock:
        STATS["in_flight"] -= 1
        key = str(resp.status_code)
        STATS["requests"][key] = STATS["requests"].get(key, 0) + 1
    resp.headers["X-Served-By"] = POD_NAME
    resp.headers["X-App-Version"] = VERSION
    return resp


# --- health -------------------------------------------------------------------
@app.get("/livez")
def livez():
    """Liveness: the process answers. It must NOT depend on load, startup or
    anything downstream — a liveness failure restarts the container."""
    return "alive\n", 200


@app.get("/healthz")
def healthz():
    """Readiness: have we finished starting? Before READY_AT this returns 503,
    which is what a slow-starting app looks like to Kubernetes."""
    if not ready():
        return f"starting — ready in {READY_AT - time.time():.1f}s\n", 503
    return "ready\n", 200


# --- the dials ------------------------------------------------------------------
@app.get("/api/work")
def work():
    """Burn CPU for `ms` milliseconds of WALL time in a tight loop.

    Under a CPU limit the kernel THROTTLES the container: the loop still runs
    for `ms` of wall time, but gets fewer CPU cycles in it — so `iterations`
    drops. Compare `iterations` with and without a limit to see throttling.
    """
    ms = max(0, min(int(request.args.get("ms", "100")), MAX_WORK_MS))
    deadline = time.perf_counter() + ms / 1000.0
    cpu_start = time.process_time()
    iterations = 0
    while time.perf_counter() < deadline:
        iterations += 1
        _ = iterations * iterations % 7
    cpu_used_ms = (time.process_time() - cpu_start) * 1000
    with _lock:
        STATS["cpu_work_ms"] += int(cpu_used_ms)
    return jsonify(
        version=VERSION, pod=POD_NAME, node=NODE_NAME,
        wall_ms=ms, cpu_ms=round(cpu_used_ms, 1), iterations=iterations,
    )


@app.get("/api/memory")
def memory():
    """Allocate and HOLD `mb` MiB in this worker process until released.

    Exceed the container's memory limit and the kernel's OOM killer ends the
    process: the pod shows `OOMKilled`, exit code 137, and restarts.
    """
    mb = max(1, min(int(request.args.get("mb", "50")), MAX_MEMORY_MB))
    block = bytearray(mb * 1024 * 1024)
    # Touch every page so the memory is actually RESIDENT, not just reserved.
    for i in range(0, len(block), 4096):
        block[i] = 1
    _held_memory.append(block)
    held = sum(len(b) for b in _held_memory) // (1024 * 1024)
    log.info("holding memory mb=%s total_held_mb=%s", mb, held)
    return jsonify(version=VERSION, pod=POD_NAME, pid=os.getpid(), allocated_mb=mb, held_mb=held)


@app.get("/api/memory/release")
def memory_release():
    _held_memory.clear()
    return jsonify(pod=POD_NAME, pid=os.getpid(), held_mb=0)


@app.get("/api/slow")
def slow():
    """Hold a request open for `seconds` without using CPU.

    During a rollout this is an IN-FLIGHT request. Whether it completes depends
    on the pod's shutdown budget: gunicorn's --graceful-timeout, the preStop
    hook, and terminationGracePeriodSeconds. Too short, and it is cut off.
    """
    seconds = max(0.0, min(float(request.args.get("seconds", "5")), 120.0))
    time.sleep(seconds)
    return jsonify(version=VERSION, pod=POD_NAME, slept_seconds=seconds)


@app.get("/api/info")
def info():
    with _lock:
        stats = {"requests": dict(STATS["requests"]), "in_flight": STATS["in_flight"],
                 "cpu_work_ms": STATS["cpu_work_ms"]}
    return jsonify(
        version=VERSION, color=COLOR or None, pod=POD_NAME, node=NODE_NAME, pid=os.getpid(),
        uptime_seconds=round(time.time() - STARTED_AT, 1), ready=ready(),
        held_memory_mb=sum(len(b) for b in _held_memory) // (1024 * 1024),
        stats=stats,
    )


@app.get("/metrics")
def metrics():
    """Prometheus text exposition. Counters are PER WORKER PROCESS (label pid) —
    gunicorn workers share no memory. A scraper sums them."""
    with _lock:
        lines = [
            "# HELP webapp_requests_total Requests served, by HTTP status code.",
            "# TYPE webapp_requests_total counter",
        ]
        for code, n in sorted(STATS["requests"].items()):
            lines.append(f'webapp_requests_total{{code="{code}",pid="{os.getpid()}"}} {n}')
        lines += [
            "# HELP webapp_in_flight_requests Requests currently being served.",
            "# TYPE webapp_in_flight_requests gauge",
            f'webapp_in_flight_requests{{pid="{os.getpid()}"}} {STATS["in_flight"]}',
            "# HELP webapp_cpu_work_ms_total CPU time spent in /api/work.",
            "# TYPE webapp_cpu_work_ms_total counter",
            f'webapp_cpu_work_ms_total{{pid="{os.getpid()}"}} {STATS["cpu_work_ms"]}',
            "# HELP webapp_info Build information.",
            "# TYPE webapp_info gauge",
            f'webapp_info{{version="{VERSION}",pod="{POD_NAME}"}} 1',
        ]
    return Response("\n".join(lines) + "\n", content_type="text/plain; version=0.0.4")


@app.get("/")
def index():
    swatch = COLOR or {"1.0.0": "#2563eb", "2.0.0": "#16a34a"}.get(VERSION, "#64748b")
    return f"""<!doctype html><meta charset="utf-8"><title>Web Platform — Kubernetes Project Lab</title>
<style>:root{{color-scheme:light dark}}body{{font-family:ui-sans-serif,system-ui,sans-serif;max-width:720px;margin:3rem auto;padding:0 1rem}}
.v{{display:inline-block;padding:.2rem .6rem;border-radius:6px;background:{swatch};color:#fff;font-weight:600}}
code{{font-family:ui-monospace,monospace}}pre{{background:#f1f5f9;color:#0f172a;padding:.75rem;border-radius:6px}}</style>
<h1>🌐 Web Platform <span class="v">v{VERSION}</span></h1>
<p>Served by <code>{POD_NAME}</code> on node <code>{NODE_NAME}</code>. Reload to watch the load balancer choose.</p>
<pre>/api/work?ms=200        burn CPU
/api/memory?mb=100      hold memory (release: /api/memory/release)
/api/slow?seconds=10    an in-flight request that outlives a rollout
/api/info · /metrics    what this pod has seen</pre>"""


log.info("webapp starting version=%s startup_delay=%ss", VERSION, STARTUP_DELAY_SECONDS)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(env("PORT", "8080")))
