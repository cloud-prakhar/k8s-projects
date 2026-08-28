# Solutions — Advanced

[⬅ Exercises](../advanced.md)

Several of these have more than one defensible answer. What follows is one
worked approach plus the reasoning you should be able to defend.

---

## 1. Zero-downtime rollout, measured

```bash
# Terminal 1 — count outcomes
: > /tmp/codes.txt
while true; do
  curl -s -o /dev/null -w '%{http_code}\n' -m 2 -H 'Host: notes.local' \
    http://localhost/api/notes >> /tmp/codes.txt
  sleep 0.2
done

# Terminal 2
kubectl rollout restart deployment/notes-api -n notes-platform
kubectl rollout status  deployment/notes-api -n notes-platform

# Terminal 1: Ctrl-C, then
sort /tmp/codes.txt | uniq -c
```

**With probes:**

```
    412 200
```

**Without a readiness probe:**

```bash
kubectl patch deployment notes-api -n notes-platform --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]'
# repeat the measurement
```

```
    380 200
     17 502
      6 503
```

**The mechanism, in one sentence:** without a readiness probe a pod is
"available" the instant it is `Running`, so the Deployment removes an old pod and
the EndpointSlice admits a new one before that pod can serve — `maxUnavailable: 0`
becomes a promise about a word that no longer means anything.

**Honest caveat:** even *with* probes you can drop requests, because endpoint
removal and container termination race. The fix is a `preStop` sleep of 5–10
seconds so the pod leaves EndpointSlices before SIGTERM arrives — Project 05.

```bash
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
```

---

## 2. A backup and a restore you have actually tested

```yaml
# backup-pvc.yaml + backup-cronjob.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-backups
  namespace: notes-platform
spec:
  storageClassName: standard
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: notes-platform
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid          # never two dumps at once
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: pg-dump
              image: postgres:17.5-alpine
              command:
                - sh
                - -c
                - |
                  set -euo pipefail
                  f=/backups/notes-$(date +%Y%m%d-%H%M%S).sql.gz
                  pg_dump -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                    | gzip > "$f"
                  echo "wrote $f ($(stat -c%s "$f") bytes)"
                  ls -t /backups/*.sql.gz | tail -n +8 | xargs -r rm    # keep 7
              envFrom:
                - configMapRef:
                    name: notes-config
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: postgres-secret
                      key: POSTGRES_PASSWORD
              volumeMounts:
                - name: backups
                  mountPath: /backups
          volumes:
            - name: backups
              persistentVolumeClaim:
                claimName: postgres-backups
```

**Test it — and this is the part people skip:**

```bash
kubectl create job --from=cronjob/postgres-backup manual-backup-1 -n notes-platform
kubectl wait --for=condition=complete job/manual-backup-1 -n notes-platform --timeout=300s
kubectl logs job/manual-backup-1 -n notes-platform

# Destroy the data
kubectl exec statefulset/postgres -n notes-platform -- psql -U notes -d notes -c 'DROP TABLE notes'
curl -s -H 'Host: notes.local' http://localhost/api/notes    # 503

# Restore
kubectl run restore --rm -i --restart=Never --image=postgres:17.5-alpine -n notes-platform \
  --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backups"}}],
  "containers":[{"name":"restore","image":"postgres:17.5-alpine","stdin":true,"tty":false,
  "volumeMounts":[{"name":"b","mountPath":"/backups"}],
  "command":["sh","-c","gunzip -c $(ls -t /backups/*.sql.gz | head -1) | psql -h postgres -U notes -d notes"],
  "env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"postgres-secret","key":"POSTGRES_PASSWORD"}}}]}]}}'

curl -s -H 'Host: notes.local' http://localhost/api/notes    # the notes are back
```

**What this does and does not give you:**

| Protects against | Does not protect against |
|---|---|
| `DROP TABLE`, application bugs, bad migrations | The node dying — the backup PVC is on the same node |
| Accidental namespace deletion *(if the PVC survives)* | Losing the cluster |

**The production version** ships dumps to object storage (S3/GCS) with
versioning and a lifecycle policy, uses WAL archiving for point-in-time recovery,
alerts when a backup does not complete, and **restores into a scratch environment
on a schedule** — because an untested backup is a hope, not a control.

> The `ReadWriteOnce` backup PVC also means the CronJob pod must land on the same
> node as the volume. That is fine here and wrong in production; use object
> storage.

---

## 3. Kustomize overlays for two environments

```
manifests/19-final/
├── base/
│   ├── kustomization.yaml
│   └── complete-production-manifest.yaml
└── overlays/
    ├── dev/kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        ├── api-replicas-patch.yaml
        └── storage-patch.yaml
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: notes-platform
resources:
  - complete-production-manifest.yaml
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: notes-platform
resources:
  - ../../base
labels:
  - pairs:
      app.kubernetes.io/managed-by: kustomize
    includeSelectors: false
replicas:
  - name: notes-api
    count: 4
patches:
  - path: storage-patch.yaml
configMapGenerator:
  - name: notes-config
    behavior: merge
    literals:
      - APP_ENV=production
      - LOG_LEVEL=warn
images:
  - name: notes-api
    newTag: "1.0.0"
```

```yaml
# overlays/prod/storage-patch.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        storageClassName: standard
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 5Gi
```

```bash
kubectl kustomize manifests/19-final/overlays/prod | grep -E 'replicas:|storage:|APP_ENV'
kubectl kustomize manifests/19-final/overlays/dev  | grep -E 'replicas:|storage:'
```

**Two things that will bite you:**

1. `configMapGenerator` with `behavior: merge` renames the ConfigMap to
   `notes-config-<hash>` and rewrites every reference. That is a **feature** —
   config changes now trigger rollouts automatically and roll back correctly.
2. `includeSelectors: false` is mandatory. `true` rewrites the immutable
   `spec.selector`, and every subsequent apply is rejected.

**Honest limitation:** the `volumeClaimTemplate` patch only affects a **new**
StatefulSet. On an existing one the API server rejects it — exercise 2 in the
intermediate set is why.

---

## 4. Make the database unreachable from everything except the API

```yaml
# default-deny plus one explicit allow
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-to-postgres
  namespace: notes-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  policyTypes: [Ingress]
  ingress: []                       # nothing is allowed
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-postgres
  namespace: notes-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: notes-api
      ports:
        - protocol: TCP
          port: 5432
```

**Verify — and expect to be disappointed on Kind:**

```bash
kubectl run netpol-test --rm -it --restart=Never --image=postgres:17.5-alpine -n notes-platform -- \
  pg_isready -h postgres -p 5432 -U notes
```

**On Kind's default CNI (kindnet), this still succeeds.** NetworkPolicy objects
are accepted by the API server and **enforced by the CNI plugin** — and kindnet
does not implement them. Nothing warns you. You have written a security control
that does nothing.

**How to verify enforcement rather than assume it:**

1. Check the CNI: `kubectl get pods -n kube-system | grep -Ei 'calico|cilium|weave|kindnet'`
2. Consult its documentation for NetworkPolicy support.
3. **Test empirically** — a deny policy that does not deny is the whole point of
   the test above.
4. Recreate the cluster with `--disable-default-cni` and install Calico or
   Cilium, then re-run the test and watch it fail to connect.

**Do not forget egress DNS.** A default-deny **egress** policy that omits UDP/TCP
53 to `kube-system` breaks every name lookup in the namespace, and the symptom
("could not translate host name") looks nothing like a network policy. That is
the classic mistake, and Project 04 makes you commit it deliberately.

---

## 5. Survive a node failure

**The honest answer: with `local-path` storage, you cannot.**

```bash
PV=$(kubectl get pvc postgres-data-postgres-0 -n notes-platform -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity}' | python3 -m json.tool
```

The PV has **node affinity** to exactly one node. If that node is lost:

- the volume is unreachable
- the scheduler cannot place `postgres-0` anywhere else, because the PV pins it
- the pod stays `Pending` with `node(s) had volume node affinity conflict`

Simulate it:

```bash
NODE=$(kubectl get pod postgres-0 -n notes-platform -o jsonpath='{.spec.nodeName}')
kubectl cordon "$NODE"
kubectl delete pod postgres-0 -n notes-platform
kubectl get pod postgres-0 -n notes-platform          # Pending
kubectl describe pod postgres-0 -n notes-platform | grep -A3 Events
kubectl uncordon "$NODE"
```

**What actually survives node loss, in increasing order of cost:**

| Approach | Protects against | Cost |
|---|---|---|
| Backups to object storage | Node loss, with data loss up to the last backup | Cheap; RPO = backup interval |
| Network-attached storage (EBS, PD, Ceph) | Node loss with zero data loss — the volume reattaches elsewhere | The storage bill; still single-AZ for EBS |
| Streaming replication across nodes/zones | Node **and** zone loss, seconds of RPO | An operator, and real complexity |
| A managed database | All of the above, plus somebody else's pager | Money |

**What you would change on a real cluster:** a CSI StorageClass backed by
network storage, a PDB so `drain` cannot take the last replica, anti-affinity or
topology spread across zones, an operator for failover, and backups you have
restored from.

---

## 6. Add a read-through cache

Sketch — full implementation is Project 03's subject.

```yaml
# Redis as a StatefulSet with a headless Service
apiVersion: v1
kind: Service
metadata:
  name: redis-headless
  namespace: notes-platform
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app.kubernetes.io/name: redis
  ports:
    - name: redis
      port: 6379
      targetPort: redis
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: notes-platform
spec:
  serviceName: redis-headless
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: redis
  template:
    metadata:
      labels:
        app.kubernetes.io/name: redis
        app.kubernetes.io/component: cache
    spec:
      containers:
        - name: redis
          image: redis:7.4.1-alpine
          ports:
            - name: redis
              containerPort: 6379
          readinessProbe:
            exec:
              command: [redis-cli, ping]
  volumeClaimTemplates:
    - metadata:
        name: redis-data
      spec:
        storageClassName: standard
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 512Mi
```

**Address a specific member:**

```bash
kubectl run redis-test --rm -it --restart=Never --image=redis:7.4.1-alpine -n notes-platform -- \
  redis-cli -h redis-0.redis-headless.notes-platform.svc.cluster.local ping
```

**The new failure modes, which are the real answer:**

| Failure | Detection |
|---|---|
| **Stale cache** — a note is deleted but still served | A cache-hit metric alongside a data-version check; short TTLs |
| **Cache stampede** — the cache empties and every request hits the database at once | Request-coalescing, jittered TTLs, database connection metrics |
| **Two Redis members with different data** — a StatefulSet is not a Redis cluster | Compare `DBSIZE` across members; use Redis Cluster or Sentinel if you need real clustering |
| **A cache that is now a dependency** — Redis down takes the app down | Fail *open*: on a Redis error, read the database. Test that path deliberately |

**Detecting staleness in practice:** emit `cache_hit`/`cache_miss` counters and a
`cache_age_seconds` histogram, and alert when the hit ratio moves sharply in
either direction — a sudden rise is as suspicious as a fall.

---

## 7. Connection pooling

```bash
# Before
kubectl run bench --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n notes-platform -- \
  sh -c 'time (for i in $(seq 1 200); do curl -s -o /dev/null http://notes-api:8080/api/notes; done)'

kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "SELECT count(*) FROM pg_stat_activity WHERE datname='notes'"
```

Add PgBouncer as a Deployment in `transaction` pooling mode, point
`POSTGRES_HOST` at it, and repeat.

**What you should observe:** lower and much more stable latency, and a small,
constant number of backend connections regardless of API replica count.

**Why it matters at scale:** each PostgreSQL connection costs a backend process
and several MB. `replicas × workers × threads` grows fast, and
`max_connections` is a hard wall — a wall you hit as a total outage, not as
gradual slowness.

**What a pool changes about the failure behaviour you relied on:** in stage 07,
deleting the database pod produced an *immediate* error because every request
opened a fresh connection. With a pool, requests can hang on stale pooled sockets
until a timeout fires, and the failure becomes slow and confusing instead of
loud. **That is why this project deliberately does not pool** — and it is also
why production systems need explicit connection timeouts and health-checked
pools.

---

## 8. TLS on the Ingress

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=notes.local/O=notes-platform" \
  -addext "subjectAltName=DNS:notes.local"

kubectl create secret tls notes-tls -n notes-platform \
  --cert=/tmp/tls.crt --key=/tmp/tls.key

kubectl patch ingress notes-ingress -n notes-platform --type=json -p='[
  {"op":"add","path":"/spec/tls","value":[{"hosts":["notes.local"],"secretName":"notes-tls"}]}
]'

curl -sk -o /dev/null -w '%{http_code}\n' https://notes.local/api/notes    # 200
curl -s  -o /dev/null -w '%{http_code}\n' http://notes.local/              # 308 — auto-redirect
```

**Note two things:**

- `kubectl create secret tls` produces `type: kubernetes.io/tls`, which
  **requires** the keys `tls.crt` and `tls.key`. A typed Secret validates its
  contents; `Opaque` does not.
- The HTTP→HTTPS redirect appeared **without configuration**. ingress-nginx
  enables `ssl-redirect` automatically once a host has TLS.

**With cert-manager and a real domain,** what changes:

| Now | With cert-manager |
|---|---|
| `openssl` by hand, browser warnings | An ACME `Issuer`/`ClusterIssuer` (Let's Encrypt) |
| Expires in 365 days, silently | Renewed automatically at ~2/3 of the lifetime |
| One `kubectl create secret` per host | One annotation: `cert-manager.io/cluster-issuer: letsencrypt-prod` |
| `/etc/hosts` | A real DNS record, for the HTTP-01 or DNS-01 challenge |

Project 10 does this against ACM and Route53 on EKS.

---

## 9. Design review

A model answer. Yours should be *specific* in the same way.

> ### Notes Platform — production readiness review
>
> **Recommendation: do not ship.** Five blocking findings.
>
> **1. Total data loss on node failure (blocker).**
> The database's PersistentVolume uses `local-path`, which pins the volume to one
> node via `nodeAffinity`. If that node fails, the volume is unreachable,
> `postgres-0` cannot be scheduled anywhere else, and the data is gone. There are
> no backups, so recovery is impossible, not merely slow.
> **Fix:** a CSI StorageClass backed by network storage (`gp3`), plus a
> `pg_dump` CronJob to object storage with a restore procedure tested on a
> schedule.
>
> **2. The database password is committed to Git (blocker).**
> `manifests/06-secrets/secret.yaml` contains the plaintext password in
> `stringData`. It is in the repository history, in the built artefacts, and in
> every clone. Encryption at rest is not enabled, so it is also plaintext in etcd
> and in any etcd backup.
> **Fix:** External Secrets Operator sourcing from a secret manager; enable
> `EncryptionConfiguration`; rotate the password, which means treating the
> current one as compromised.
>
> **3. Single database instance with no failover (blocker for the stated SLO).**
> One `postgres-0`. Any node maintenance, eviction or pod deletion is a full
> write outage of 20–40 seconds; a node failure is unbounded. There is no PDB, so
> `kubectl drain` will take it down without warning.
> **Fix:** CloudNativePG (primary + standby with automatic failover) or a managed
> database. At minimum, a PodDisruptionBudget and a documented maintenance
> procedure.
>
> **4. No resource limits — one pod can starve the node (high).**
> Containers set `requests` but no `limits`, so every pod is `Burstable` and a
> memory leak in `notes-api` can consume the node and evict PostgreSQL. There is
> no LimitRange to supply defaults for pods that forget.
> **Fix:** limits on every container, a LimitRange on the namespace, and a
> ResourceQuota. Confirm the QoS class you land in.
>
> **5. The database is reachable from every pod in the cluster (high).**
> No NetworkPolicy exists. Any compromised or careless workload — in this
> namespace or any other — can open a TCP connection to port 5432 and try the
> password from finding 2.
> **Fix:** default-deny ingress on the database, one explicit allow from
> `notes-api`. **Verify the CNI enforces NetworkPolicy** — several do not, and
> an unenforced policy is worse than none because it looks like a control.
>
> **Also noted, non-blocking:** no TLS on the Ingress (finding 6); no metrics,
> dashboards or alerts, so the first three findings would be discovered by users
> (7); no `preStop` hook, so rollouts drop a small number of in-flight requests
> (8); no connection pooling, which caps API scaling at PostgreSQL's
> `max_connections` (9); `initdb`-time schema management with no migration tool,
> so the schema cannot evolve after day one (10).

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Intermediate solutions](intermediate.md)** | [Project 02](../../README.md) | **[Interview questions](../../interview-questions/questions.md)** ▶ |
