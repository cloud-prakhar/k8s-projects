# Solutions — Advanced

[⬅ Exercises](../advanced.md)

---

## 1. Manual Redis failover

```bash
NS=url-shortener
# 1. Promote redis-1 (it stops replicating and accepts writes)
kubectl exec -n $NS redis-1 -- redis-cli replicaof no one

# 2. Point writes at it — a config change, so a new generated ConfigMap and a rollout
sed -i 's/^REDIS_WRITE_HOST=.*/REDIS_WRITE_HOST=redis-1.redis-headless.url-shortener.svc.cluster.local/' manifests/19-final/config/shortener.env
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32#" | kubectl apply -f -
kubectl rollout status deployment/shortener-api -n $NS

# 3. Make the old primary a replica of the new one (runtime only)
kubectl exec -n $NS redis-0 -- redis-cli replicaof redis-1.redis-headless.url-shortener.svc.cluster.local 6379
kubectl exec -n $NS redis-0 -- redis-cli info replication | grep -E 'role|master_host|master_link_status'
```

**Why this design makes it hard:** the role is derived from the **ordinal at start-up**. Restart `redis-0` and its
script makes it a primary again — now two primaries, split brain. `replicaof` at runtime is not persisted to the
rendered config. Every client also needs a config rollout to learn the new primary.

**What does it properly:** Redis **Sentinel** (monitors, elects, and clients ask Sentinel for the current primary),
a Redis/Valkey **operator** that updates a "primary" Service's selector on failover, or **ElastiCache** with a stable
primary endpoint and automatic Multi-AZ failover.

**Revert:** restore `shortener.env`, re-apply, then `kubectl delete pod redis-0 redis-1 -n $NS` so both rebuild
their roles from ordinals (and check for lost writes — this is exactly how failover loses data).

---

## 2. Fix cache invalidation

Design:

1. The update endpoint writes PostgreSQL **first**, then `DEL link:<code>` on the **primary**.
2. Reads that hit the **replica** may still see the key for the replication lag — so either read the cache from the
   primary for redirects (simplest), or store a version: `SET link:<code> "<version>|<url>"` and have the API compare
   the version with `links.updated_at` on a small fraction of hits.
3. Shorten the TTL for mutable links; keep it long for immutable ones.

Sketch in `app.py`:

```python
@app.put("/api/links/<code>")
def update_link(code):
    url = (request.get_json(silent=True) or {}).get("url", "").strip()
    # … validate …
    with pg() as conn:
        n = conn.execute("UPDATE links SET target_url=%s WHERE code=%s", (url, code)).rowcount
    if not n:
        return jsonify(error="no such link"), 404
    redis_write(lambda r: r.delete(f"link:{code}"))       # primary
    return jsonify(code=code, target_url=url)
```

**Why reads from the replica still matter:** replication is asynchronous. Deleting on the primary does not delete on
the replica at the same instant; a redirect served from the replica in that window returns the old URL.

---

## 3. Point `postgres` at a "managed" database

```bash
# 1. The stand-in for RDS
kubectl create namespace shared-db
# (apply a PostgreSQL StatefulSet + Service named `pg` in shared-db — adapt stage 08's manifests)

# 2. Migrate data with the app still running (brief write freeze in real life)
kubectl exec -n url-shortener postgres-0 -- pg_dump -U shortener -d shortener \
  | kubectl exec -i -n shared-db pg-0 -- psql -U shortener -d shortener

# 3. Replace the ClusterIP Service `postgres` with an ExternalName of the same name
kubectl delete service postgres -n url-shortener
kubectl create service externalname postgres -n url-shortener --external-name pg.shared-db.svc.cluster.local
kubectl rollout restart deployment/shortener-api -n url-shortener     # drop existing connections

# 4. Retire the old one
kubectl scale statefulset/postgres -n url-shortener --replicas=0
```

**Why it works:** the API connects to `postgres.url-shortener.svc.cluster.local`; that name is now a CNAME to the new
database. PostgreSQL is a TCP protocol, so ExternalName's lack of Host/SNI rewriting does not matter (unlike HTTPS).
On AWS the `external-name` would be the RDS endpoint.

**Common wrong answer:** changing `POSTGRES_HOST` — works, but it is a config change and a rollout of every
consumer; the point is that the alias lets the platform move the dependency.

---

## 4. Zero-error rollouts behind the ALB

Add to the API container, and lengthen the grace period:

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: shortener-api
          lifecycle:
            preStop:
              exec:
                command: ["python", "-c", "import time; time.sleep(25)"]
```

(The image has no `sleep` binary guarantee in every base; `python` is always present. Kubernetes 1.30+ also supports
`preStop: sleep: {seconds: 25}` natively.)

| Value | Why |
|---|---|
| `preStop` 25 s | On termination the pod is removed from EndpointSlices and the controller starts deregistering it; the ALB takes several seconds to stop sending. Sleeping keeps gunicorn serving through that window. |
| `deregistration_delay` 20 s (already set) | In-flight requests to a draining target get 20 s to finish. |
| `terminationGracePeriodSeconds` 45 | Must exceed preStop (25) + gunicorn's graceful shutdown (25 `--graceful-timeout` worst case) or the kubelet SIGKILLs mid-request. |
| readiness gate (already on) | Protects the *start* of the pod's life. |

**Verify:**

```bash
ALB=$(kubectl get ingress url-shortener-ingress -n url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
CODE=$(kubectl exec -n url-shortener postgres-0 -- psql -U shortener -d shortener -tAc 'SELECT code FROM links LIMIT 1')
( for i in $(seq 1 120); do curl -s -o /dev/null -m 3 -w '%{http_code}\n' "http://$ALB/r/$CODE"; sleep 1; done ) > codes.txt &
kubectl rollout restart deployment/shortener-api -n url-shortener
wait; sort codes.txt | uniq -c
```

> **Follow-up:** why is a readiness gate alone not enough? *(It orders the start of new pods; the old pod's SIGTERM
> still races the ALB's deregistration.)*
