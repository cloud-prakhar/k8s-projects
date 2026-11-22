"""loadgen — a tiny, dependency-free HTTP load generator that REPORTS.

Every lesson in Project 05 is a claim about what happens to real traffic —
"the rollout dropped requests", "the HPA added pods", "the drain was absorbed".
This prints, once per second, how many requests got which status code, how many
failed at the connection level, the p50/p95 latency, and which versions/pods
answered. A claim you can read off a table is a claim you can check.

  loadgen --url http://webapp:8080/api/work?ms=50 --concurrency 20 --duration 120

Status "ERR" means no HTTP response at all (refused, reset, timed out) — the
signature of traffic sent to a pod that already stopped listening.
"""

import argparse
import threading
import time
import urllib.error
import urllib.request
from collections import Counter


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", required=True)
    p.add_argument("--concurrency", "-c", type=int, default=10)
    p.add_argument("--duration", "-d", type=int, default=60, help="seconds")
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--host", default=None, help="override the Host header")
    a = p.parse_args()

    lock = threading.Lock()
    window = {"codes": Counter(), "lat": [], "served": Counter()}
    total = Counter()
    stop = time.time() + a.duration

    def worker() -> None:
        while time.time() < stop:
            req = urllib.request.Request(a.url, headers={"Host": a.host} if a.host else {})
            t0 = time.perf_counter()
            code, served = "ERR", None
            try:
                with urllib.request.urlopen(req, timeout=a.timeout) as r:
                    r.read()
                    code = str(r.status)
                    served = r.headers.get("X-App-Version")
            except urllib.error.HTTPError as e:
                code = str(e.code)
                served = e.headers.get("X-App-Version") if e.headers else None
            except Exception:
                code = "ERR"
            dt = (time.perf_counter() - t0) * 1000
            with lock:
                window["codes"][code] += 1
                window["lat"].append(dt)
                if served:
                    window["served"][served] += 1
                total[code] += 1

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(a.concurrency)]
    for t in threads:
        t.start()

    print(f"loadgen url={a.url} concurrency={a.concurrency} duration={a.duration}s", flush=True)
    start = time.time()
    while time.time() < stop:
        time.sleep(1)
        with lock:
            codes, lat, served = window["codes"], sorted(window["lat"]), window["served"]
            window.update(codes=Counter(), lat=[], served=Counter())
        n = sum(codes.values())
        p50 = lat[len(lat) // 2] if lat else 0
        p95 = lat[int(len(lat) * 0.95) - 1] if len(lat) >= 20 else (lat[-1] if lat else 0)
        codes_s = " ".join(f"{k}:{v}" for k, v in sorted(codes.items()))
        served_s = " ".join(f"v{k}:{v}" for k, v in sorted(served.items()))
        print(f"t={time.time() - start:5.0f}s rps={n:4d} p50={p50:6.0f}ms p95={p95:6.0f}ms  {codes_s:30s} {served_s}", flush=True)
    for t in threads:
        t.join(timeout=a.timeout + 1)
    ok = sum(v for k, v in total.items() if k.startswith("2"))
    print(f"TOTAL {dict(sorted(total.items()))}  success={ok}/{sum(total.values())}", flush=True)


if __name__ == "__main__":
    main()
