# Solutions — Intermediate

[⬅ Exercises](../intermediate.md)

---

## 1. Survive a StatefulSet deletion

```bash
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "INSERT INTO notes (body) VALUES ('survives deletion')"

kubectl delete statefulset postgres -n notes-platform
kubectl get pvc -n notes-platform          # postgres-data-postgres-0 still Bound

kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "SELECT body FROM notes ORDER BY id DESC LIMIT 1"
```

**Which object:** `PersistentVolumeClaim/postgres-data-postgres-0`, and the PV
behind it.

**Why it was not garbage-collected:**

```bash
kubectl get pvc postgres-data-postgres-0 -n notes-platform \
  -o jsonpath='{.metadata.ownerReferences}'; echo      # empty
```

Kubernetes' garbage collector deletes objects whose **owner references** all
point at deleted objects. PVCs created from a `volumeClaimTemplate` are given
**no** owner reference to the StatefulSet, deliberately — so deleting a workload
never destroys data.

**And why the pod found its own volume again:** the claim name is derived from
the ordinal (`<template>-<sts>-<ordinal>`), so `postgres-0` computes the same
name and reattaches.

> **Follow-up:** what changes with `persistentVolumeClaimRetentionPolicy:
> {whenDeleted: Delete}` (1.27+)? *(The PVCs do get owner references and are
> deleted with the StatefulSet — convenient for a cache, dangerous for a
> database.)*

---

## 2. Migrate the data to a new volume

The honest answer is that **Kubernetes does not move data** — you do, with the
database's own tools.

```bash
# 1. Dump from the running database
kubectl exec statefulset/postgres -n notes-platform -- \
  pg_dump -U notes -d notes --data-only --table=notes > /tmp/notes-data.sql
wc -l /tmp/notes-data.sql

# 2. A second StatefulSet with its own claim template
kubectl get statefulset postgres -n notes-platform -o yaml \
  | sed -e 's/name: postgres$/name: postgres-new/' \
        -e 's/serviceName: postgres-headless/serviceName: postgres-headless/' \
  > /tmp/postgres-new.yaml
# (edit /tmp/postgres-new.yaml: remove status/resourceVersion/uid, and give the
#  volumeClaimTemplate a distinct name so it provisions a fresh volume)

# 3. Load the dump into the new instance
kubectl exec -i postgres-new-0 -n notes-platform -- psql -U notes -d notes < /tmp/notes-data.sql

# 4. Verify BEFORE switching
kubectl exec postgres-new-0 -n notes-platform -- psql -U notes -d notes -c 'SELECT count(*) FROM notes'

# 5. Switch the Service selector, or rename, then retire the old one
```

**Why you cannot just edit the template:**

```bash
kubectl patch statefulset postgres -n notes-platform \
  -p '{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"postgres-data-v2"}}]}}'
# The StatefulSet "postgres" is invalid: spec: Forbidden: updates to statefulset spec for
# fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', … are forbidden
```

Claim templates are immutable, because existing PVCs were stamped from the old
one and Kubernetes will not leave them inconsistent with the spec.

**The alternatives worth knowing:**

| Approach | When |
|---|---|
| `pg_dump` / `pg_restore` | Small databases, and the only fully portable option |
| Logical replication | Large databases, near-zero downtime |
| VolumeSnapshot → restore into a new PVC | Same storage backend, block-level, fastest |
| Pre-create the PVC with the name the new StatefulSet will compute | Reuse an existing volume — works because the name is derived, not random |

> **Follow-up:** how would you do this with no downtime at all? *(Logical
> replication to the new instance, then cut over the Service selector once
> replication lag is zero.)*

---

## 3. Make `type: LoadBalancer` actually work

```bash
# In a separate terminal, left running:
go install sigs.k8s.io/cloud-provider-kind@latest
sudo ~/go/bin/cloud-provider-kind

# Back here:
kubectl get svc notes-web-lb -n notes-platform -w
```

Within seconds `EXTERNAL-IP` changes from `<pending>` to a routable address:

```bash
IP=$(kubectl get svc notes-web-lb -n notes-platform -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w '%{http_code}\n' "http://${IP}/"
```

**What changed:** a **cloud controller manager** now exists. It watched for
Services of type `LoadBalancer`, created a load balancer (here, a container
running envoy), and wrote the address into `.status.loadBalancer.ingress`.

**What did not change: your YAML.** Not one character. The manifest was correct
all along; the platform was missing.

**The interview answer:** `<pending>` means no cloud provider integration is
running. `type: LoadBalancer` is a *request*; Kubernetes itself creates nothing.

> **Follow-up:** on EKS, which component fulfils it, and what does it create?
> *(The AWS cloud controller manager — an NLB by default; the AWS Load Balancer
> Controller creates an ALB for Ingress objects instead.)*

---

## 4. Host-based routing

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: notes-api-ingress
  namespace: notes-platform
  annotations:
    kubernetes.io/description: "Host-based route sending everything on api.notes.local to the API"
spec:
  ingressClassName: nginx
  rules:
    - host: api.notes.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: notes-api
                port:
                  number: 8080
EOF

curl -s -H 'Host: api.notes.local' http://localhost/api/info | head -c 120; echo
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.notes.local' http://localhost/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: notes.local' http://localhost/
```

```
{"app_env":"development","db_connected":true,…}
404      ← the API's own 404, not the web UI
200      ← notes.local is untouched
```

**Why a separate Ingress object works:** the controller merges **all** Ingresses
of its class into one configuration. Host rules are independent, so two objects
in one namespace is a perfectly normal way to organise routes — and it keeps
ownership clear when different teams own different hostnames.

**The 404 is the point:** `/` on `api.notes.local` reaches `notes-api`, which has
no route for `/`. That proves routing went where you intended.

```bash
kubectl delete ingress notes-api-ingress -n notes-platform
```

> **Follow-up:** what happens if two Ingresses declare the same host **and** the
> same path? *(Undefined and controller-specific; ingress-nginx picks the older
> object and logs a conflict. Do not rely on it.)*

---

## 5. Prove the readiness/liveness distinction with numbers

**Correct configuration (liveness on `/livez`):**

```bash
date +%T; kubectl scale statefulset/postgres --replicas=0 -n notes-platform
while true; do
  n=$(kubectl get endpointslices -n notes-platform -l kubernetes.io/service-name=notes-api \
      -o jsonpath='{.items[*].endpoints[*].addresses[*]}' | wc -w)
  echo "$(date +%T) endpoints=$n"
  [ "$n" -eq 0 ] && break
  sleep 1
done
sleep 60
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
```

| Measurement | Result |
|---|---|
| Time to leave the EndpointSlice | ~15 s = `failureThreshold 3` × `periodSeconds 5` |
| Restarts after 60 s | **0** |
| Pod status | `0/1 Running` |

**Broken configuration (liveness on `/healthz`):**

```bash
kubectl scale statefulset/postgres --replicas=1 -n notes-platform
kubectl wait --for=condition=Ready pod/postgres-0 -n notes-platform --timeout=180s
kubectl patch deployment notes-api -n notes-platform --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}]'
kubectl rollout status deployment/notes-api -n notes-platform

kubectl scale statefulset/postgres --replicas=0 -n notes-platform
sleep 90
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
```

| Measurement | Result |
|---|---|
| Time to leave the EndpointSlice | ~15 s (unchanged) |
| Restarts after 90 s | **3+ and climbing** |
| Pod status | `CrashLoopBackOff`, exit code 137 |

**The explanation, in probe fields only:** liveness has
`failureThreshold: 3 × periodSeconds: 10` = 30 s to a SIGKILL. Because
`/healthz` reports the *database's* state, that timer starts the moment the
database goes away, and every restart resets a container that was never faulty.
CrashLoopBackOff then adds exponential backoff, so recovery lags the actual
outage by minutes.

Restore:

```bash
kubectl scale statefulset/postgres --replicas=1 -n notes-platform
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
```

> **Follow-up:** when *is* a liveness probe worth having? *(For processes that
> genuinely wedge — a deadlocked thread pool, an event loop that stops
> progressing. Point it at something that only fails when the process itself is
> stuck.)*

---

## 6. A StorageClass with Retain

```bash
kubectl get storageclass notes-platform-retain    # created in stage 07

# A StatefulSet cannot have its claim template edited, so this needs a new object.
kubectl get statefulset postgres -n notes-platform -o yaml > /tmp/sts.yaml
# edit: metadata.name → postgres-retain
#       volumeClaimTemplates[0].spec.storageClassName → notes-platform-retain
#       remove status, uid, resourceVersion, creationTimestamp
kubectl apply -f /tmp/sts.yaml
kubectl rollout status statefulset/postgres-retain -n notes-platform --timeout=300s

kubectl exec postgres-retain-0 -n notes-platform -- \
  psql -U notes -d notes -c "INSERT INTO notes (body) VALUES ('on a Retain volume')"

# Now delete the claim and watch what does NOT happen
kubectl delete statefulset postgres-retain -n notes-platform
kubectl delete pvc postgres-data-postgres-retain-0 -n notes-platform
kubectl get pv
```

```
NAME        CAPACITY   RECLAIM POLICY   STATUS     CLAIM                             STORAGECLASS
pvc-9a2f…   1Gi        Retain           Released   notes-platform/postgres-data-…    notes-platform-retain
```

**Phase `Released`, not deleted.** The data is still on the node:

```bash
NODE=$(kubectl get pv <name> -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
docker exec "$NODE" ls "$(kubectl get pv <name> -o jsonpath='{.spec.local.path}')/pgdata" | head -3
```

**Why `Released` cannot simply be reused:** the PV still records its old
`claimRef`. Binding it to a new claim requires clearing that field by hand —
Kubernetes refuses to hand somebody else's data to a new claimant automatically.

**Clean up properly:**

```bash
kubectl delete pv <name>
```

> **Follow-up:** what is the operational cost of `Retain` at scale? *(Somebody has
> to reap `Released` volumes, or you pay for orphaned disks forever. That is a
> runbook item, not an afterthought.)*

---

## 7. Force a rollout when a ConfigMap changes

```bash
CHECKSUM=$(kubectl get configmap notes-config -n notes-platform -o yaml | sha256sum | cut -d' ' -f1)
kubectl patch deployment notes-api -n notes-platform -p "{
  \"spec\": {\"template\": {\"metadata\": {\"annotations\": {\"checksum/config\": \"${CHECKSUM}\"}}}}
}"
kubectl rollout status deployment/notes-api -n notes-platform
```

Now change the ConfigMap and recompute:

```bash
kubectl patch configmap notes-config -n notes-platform -p '{"data":{"LOG_LEVEL":"debug"}}'
CHECKSUM=$(kubectl get configmap notes-config -n notes-platform -o yaml | sha256sum | cut -d' ' -f1)
kubectl patch deployment notes-api -n notes-platform -p "{
  \"spec\": {\"template\": {\"metadata\": {\"annotations\": {\"checksum/config\": \"${CHECKSUM}\"}}}}
}"
kubectl exec deployment/notes-api -n notes-platform -- env | grep LOG_LEVEL
# LOG_LEVEL=debug
```

**Why it works:** the annotation lives on the **pod template**. Changing it
changes the template hash, which creates a new ReplicaSet, which is an ordinary
rolling update. The annotation's *value* is never read by anything — it exists
purely to make the template differ.

**Where this belongs:** in the tool that renders your manifests, so nobody has to
remember. Helm does it with `{{ include … | sha256sum }}`; Kustomize does it
better with `configMapGenerator`, which appends a content hash to the **name**:

```yaml
configMapGenerator:
  - name: notes-config
    literals: [LOG_LEVEL=debug]
# → notes-config-7d9f2b4c8k, and the Deployment reference is rewritten to match
```

That is strictly better — the old ConfigMap still exists, so a rollback rolls
back the *config* too.

Restore:

```bash
kubectl apply -f manifests/05-configmaps/configmap.yaml
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
```

> **Follow-up:** why is `configMapGenerator` safer than the checksum annotation?
> *(`rollout undo` restores the pod template, which points at the old, still-present
> ConfigMap. With a checksum, the old template points at a ConfigMap whose
> contents have already changed.)*

---

## 8. Scale the StatefulSet and explain the result

```bash
kubectl scale statefulset/postgres --replicas=3 -n notes-platform
kubectl rollout status statefulset/postgres -n notes-platform --timeout=600s
kubectl get pods,pvc -n notes-platform

for i in 0 1 2; do
  echo -n "postgres-$i: "
  kubectl exec "postgres-$i" -n notes-platform -- psql -U notes -d notes -tAc 'SELECT count(*) FROM notes'
done
```

```
postgres-0: 6
postgres-1: 2
postgres-2: 2
```

**Three separate databases.** Pods 1 and 2 got brand-new empty volumes and ran
`init.sql`, so they hold only the seed rows. And because the ClusterIP Service
selects all three, your application now returns different data depending on which
pod answered:

```bash
for i in $(seq 1 10); do
  kubectl run q-$i --rm -i --restart=Never --quiet --image=curlimages/curl:8.10.1 \
    -n notes-platform -- curl -s http://notes-web/api/info 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["note_count"])'
done
```

**The three sentences:**

1. A StatefulSet gives each pod a stable name, a stable DNS record and its own
   PersistentVolumeClaim, and it creates, updates and deletes them in ordinal
   order.
2. It gives you **nothing** about replication, leader election, failover or
   consistency — those live inside the software being run.
3. Making this real replication means configuring PostgreSQL streaming
   replication (a primary, standbys, WAL shipping, and a way to promote on
   failure), which in practice means an operator such as CloudNativePG or a
   managed service.

**Clean up — note the PVCs do not go on their own:**

```bash
kubectl scale statefulset/postgres --replicas=1 -n notes-platform
kubectl get pvc -n notes-platform          # three claims still there
kubectl delete pvc postgres-data-postgres-1 postgres-data-postgres-2 -n notes-platform
```

> **Follow-up:** why did `postgres-1` start *before* `postgres-2`, and what would
> `podManagementPolicy: Parallel` change? *(`OrderedReady` creates them one at a
> time, each waiting for Ready. `Parallel` starts them together — correct for
> members that do not bootstrap from each other, and it is immutable after
> creation.)*

---

## 9. Find every place the database password exists

| Location | Command | The control in production |
|---|---|---|
| The Secret object | `kubectl get secret postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' \| base64 -d` | **RBAC** — `get secrets` should be rare and audited |
| The API pod's environment | `kubectl exec deployment/notes-api -- env \| grep PASSWORD` | RBAC on `pods/exec`, which is a privileged verb |
| The database pod's environment | `kubectl exec postgres-0 -- env \| grep PASSWORD` | Same |
| `/proc/<pid>/environ` inside either container | `kubectl exec … -- cat /proc/1/environ \| tr '\0' '\n'` | Mount secrets as **files**, not env vars |
| etcd on disk | *(node access)* | **Encryption at rest** — `EncryptionConfiguration`, ideally KMS-backed |
| **Git** | `grep -r POSTGRES_PASSWORD manifests/` | External Secrets / Sealed Secrets / SOPS — commit a *reference*, not a credential |
| An etcd backup | — | Encrypt the backup too; an unencrypted etcd snapshot is a credential dump |
| Any pod that can mount it | `kubectl auth can-i create pods -n notes-platform` | **`create pods` in a namespace ⇒ read any Secret in it.** This surprises people |

**The summary sentence:** base64 protects nothing. RBAC, encryption at rest, and
not committing the value are the controls — Project 07 implements all three.

```bash
kubectl auth can-i get secrets -n notes-platform \
  --as=system:serviceaccount:notes-platform:default
# no    ← the difference between you and the app's identity
```

> **Follow-up:** what is the strongest available answer? *(No long-lived password
> at all — short-lived credentials issued per pod, via Vault dynamic secrets or
> cloud IAM database authentication.)*

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Beginner solutions](beginner.md)** | [Project 02](../../README.md) | **[Advanced solutions](advanced.md)** ▶ |
