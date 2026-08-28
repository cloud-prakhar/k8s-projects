# Solutions — Beginner

[⬅ Exercises](../beginner.md)

---

## 1. Scale the API tier

```bash
# Imperative — fast, and the cluster now differs from your YAML
kubectl scale deployment/notes-api --replicas=4 -n notes-platform

# Declarative — what you would commit
kubectl patch deployment notes-api -n notes-platform -p '{"spec":{"replicas":4}}'

kubectl rollout status deployment/notes-api -n notes-platform
kubectl get endpointslices -n notes-platform -l kubernetes.io/service-name=notes-api \
  -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
```

**Confirm all four serve traffic:**

```bash
for i in $(seq 1 20); do
  curl -s -H 'Host: notes.local' http://localhost/api/info \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["pod"])'
done | sort | uniq -c
```

```
      5 notes-api-6f4d8c9b7-2xnvq
      6 notes-api-6f4d8c9b7-8xk2m
      4 notes-api-6f4d8c9b7-mz3vq
      5 notes-api-6f4d8c9b7-q5wtn
```

**Why it works:** scaling changes `spec.replicas`, the ReplicaSet controller
creates pods, and the EndpointSlice controller adds each one **once its readiness
probe passes**. Nothing edits the Service.

**Common wrong answer:** editing the ReplicaSet's replica count. The Deployment
controller reconciles it straight back — the ReplicaSet is owned, not authored.

```bash
kubectl scale deployment/notes-api --replicas=2 -n notes-platform
```

> **Follow-up:** why do you sometimes see only one pod name, even at 4 replicas?
> *(Keep-alive: load balancing is per connection, not per request.)*

---

## 2. Prove the data is shared

```bash
curl -sX POST -H 'Host: notes.local' http://localhost/api/notes \
  -H 'Content-Type: application/json' -d '{"body":"shared state"}'

for i in $(seq 1 10); do
  curl -s -H 'Host: notes.local' http://localhost/api/info \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["pod"], d["note_count"])'
done
```

```
notes-api-6f4d8c9b7-8xk2m 4
notes-api-6f4d8c9b7-q5wtn 4
notes-api-6f4d8c9b7-8xk2m 4
…
```

**The sentence:** in Project 01 each replica held its own tasks *in process
memory*, so scaling changed the answer; here every replica reads one PostgreSQL
database, so the pod name varies and the data does not.

**Why it matters:** this is the definition of a stateless tier. It is what makes
`replicas: 4`, rolling updates and autoscaling safe.

> **Follow-up:** what would break if `notes-api` cached notes in memory for 30
> seconds? *(Different replicas would disagree — the same bug as Project 01, now
> intermittent and much harder to find.)*

---

## 3. Find where the data physically lives

```bash
kubectl get pvc postgres-data-postgres-0 -n notes-platform
PV=$(kubectl get pvc postgres-data-postgres-0 -n notes-platform -o jsonpath='{.spec.volumeName}')
echo "PV: $PV"

kubectl get pv "$PV" -o jsonpath='{.spec.local.path}{"\n"}'
NODE=$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
echo "node: $NODE"

PATH_ON_NODE=$(kubectl get pv "$PV" -o jsonpath='{.spec.local.path}')
docker exec "$NODE" ls -la "$PATH_ON_NODE"
docker exec "$NODE" ls "$PATH_ON_NODE/pgdata" | head
```

```
PG_VERSION  base  global  pg_wal  postgresql.conf  …
```

**Why it works:** `local-path-provisioner` creates a directory on one node and
describes it as a PV with **node affinity**, which is how the scheduler knows the
pod must go back to that node.

**The lesson hiding in `nodeAffinity`:** this data is pinned to one machine. Lose
the node, lose the database. That single field is why `local-path` is not
production storage.

> **Follow-up:** what would this command show on EKS? *(An EBS volume id, and
> zone affinity instead of node affinity — a volume cannot cross availability
> zones.)*

---

## 4. Read the config out of a running container

```bash
# 1. Which host?
kubectl exec deployment/notes-api -n notes-platform -- env | grep POSTGRES_HOST
# POSTGRES_HOST=postgres.notes-platform.svc.cluster.local

# 2. Where did it come from?
kubectl get deployment notes-api -n notes-platform \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom}' | python3 -m json.tool
# [{"configMapRef": {"name": "notes-config"}}]
kubectl get configmap notes-config -n notes-platform -o jsonpath='{.data.POSTGRES_HOST}'; echo

# 3. Is the password visible?
kubectl exec deployment/notes-api -n notes-platform -- env | grep POSTGRES_PASSWORD
# POSTGRES_PASSWORD=dev-password-not-for-production
```

**Why it matters:** yes, it is plainly visible. Anyone with `pods/exec` in this
namespace has your database password. `exec` is a **privileged verb**, not a
debugging convenience — Project 07 is about exactly this.

**Note the honest answer to (2):** with `envFrom` you cannot tell from the
Deployment *which variables* the container receives, only which ConfigMap. That
is the trade-off for the convenience.

> **Follow-up:** how would a volume-mounted Secret be better here? *(It lands in
> a tmpfs, is not in `/proc/<pid>/environ`, is not inherited by child processes,
> and can be re-read after rotation without a restart.)*

---

## 5. Delete the database pod and time the outage

```bash
# Watch in one terminal
while true; do
  printf '%s %s\n' "$(date +%T)" \
    "$(curl -s -o /dev/null -w '%{http_code}' -m 2 -H 'Host: notes.local' http://localhost/api/notes)"
  sleep 1
done

# In another
kubectl delete pod postgres-0 -n notes-platform
```

Typical shape: a few seconds of `503`, then `200` again — roughly 20–40 seconds
in total on a warm cluster.

**The two mechanisms:**

1. **The StatefulSet controller** recreates `postgres-0` and reattaches its
   volume. How fast depends on the image being cached and on PostgreSQL's crash
   recovery.
2. **The probes.** The database's readiness probe (`periodSeconds: 10`,
   `failureThreshold: 3`) decides when it rejoins its Service; the API's
   readiness probe (`periodSeconds: 5`, `failureThreshold: 3`) decides when the
   API pods leave and rejoin theirs.

**Why the API pods did not restart:** their liveness probe points at `/livez`,
which never touches the database. They went `0/1 Running` with `RESTARTS 0` and
recovered on their own.

> **Follow-up:** halve the API's `periodSeconds`. What improves, and what does it
> cost? *(Faster withdrawal and recovery; twice the probe traffic, and more
> sensitivity to a single slow response.)*

---

## 6. Connect to PostgreSQL directly

```bash
kubectl exec -it postgres-0 -n notes-platform -- psql -U notes -d notes
```

```sql
\dt
\d notes
INSERT INTO notes (body) VALUES ('written straight into the database');
SELECT * FROM notes ORDER BY id;
\q
```

Refresh the UI — the note is there, because the API is only ever reading this
table.

**Bonus:** `notes_created_at_idx`. The application's `CREATE TABLE IF NOT EXISTS`
never creates an index; only `init.sql` does. Seeing it is proof the
ConfigMap-mounted file was executed on first initialisation.

```bash
kubectl exec postgres-0 -n notes-platform -- \
  psql -U notes -d notes -c "SELECT indexname FROM pg_indexes WHERE tablename='notes'"
```

> **Follow-up:** edit `init.sql` in the ConfigMap and restart the pod. Why does
> nothing change? *(`/docker-entrypoint-initdb.d/` runs only on an empty data
> directory — and a `subPath` mount is never refreshed either.)*

---

## 7. Change a config value and make it take effect

```bash
kubectl patch configmap notes-config -n notes-platform -p '{"data":{"LOG_LEVEL":"debug"}}'

# Nothing changed in the running pods:
kubectl exec deployment/notes-api -n notes-platform -- env | grep LOG_LEVEL
# LOG_LEVEL=info

kubectl rollout restart deployment/notes-api -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform
kubectl exec deployment/notes-api -n notes-platform -- env | grep LOG_LEVEL
# LOG_LEVEL=debug

kubectl logs deployment/notes-api -n notes-platform --tail=10
```

**Why it works:** `rollout restart` adds a `kubectl.kubernetes.io/restartedAt`
annotation to the **pod template**. A template change means a new ReplicaSet,
which means a normal rolling update — zero downtime, and it respects
`maxUnavailable: 0`.

**Common wrong answer:** `kubectl delete pod`. It gets new environment variables
too, but it is not a rolling update — you drop capacity, and with one replica you
take an outage.

**Why env vars do not update:** the Linux process environment is fixed at
`exec()`. Nothing in Kubernetes can change a running process's environment.

Restore:

```bash
kubectl apply -f manifests/05-configmaps/configmap.yaml
kubectl rollout restart deployment/notes-api -n notes-platform
```

> **Follow-up:** how do you make a config change trigger the rollout by itself?
> *(A `checksum/config` annotation on the pod template — intermediate exercise 7.)*

---

## 8. Route a new path through the Ingress

```bash
kubectl patch ingress notes-ingress -n notes-platform --type=json -p='[
  {"op":"add","path":"/spec/rules/0/http/paths/0","value":{
    "path":"/whoami","pathType":"Exact",
    "backend":{"service":{"name":"notes-web","port":{"number":80}}}}}
]'
curl -s -H 'Host: notes.local' http://localhost/whoami
```

```
pod=notes-web-7b9c5d8f6-mz3vq
api=http://notes-api.notes-platform.svc.cluster.local:8080
```

**Why `Exact` here:** `/whoami` is a single endpoint, not a subtree. `Prefix`
would work too — it matches whole **path segments**, so it covers `/whoami` and
`/whoami/x` but never `/whoamiXYZ` — but `Exact` states the intent precisely.

**Note it already worked** without this rule, because `/` is a `Prefix` rule to
`notes-web`. The exercise is really about seeing that adding a rule takes effect
in seconds, with no restart:

```bash
POD=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl logs -n ingress-nginx "$POD" --tail=5 | grep -i "configuration changes detected"
```

Restore:

```bash
kubectl apply -f manifests/09-ingress/02-notes-ingress.yaml
```

> **Follow-up:** what happens if two rules match the same request? *(nginx picks
> the longest matching path. Two rules with the same path and host is undefined
> across controllers — do not rely on ordering.)*

---

## 9. Namespace hygiene

```bash
# The lie:
kubectl get all -n notes-platform

# The truth:
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl get --show-kind --ignore-not-found -n notes-platform
```

Expected inventory:

| Kind | Count |
|---|---|
| ConfigMap | 3 (`notes-config`, `postgres-init`, `kube-root-ca.crt`) |
| Secret | 1 |
| Service | 4 (6 with the stage 10 exhibits) |
| EndpointSlice | one per Service |
| Deployment / ReplicaSet | 2 / 2+ |
| StatefulSet | 1 |
| Pod | 5 |
| PersistentVolumeClaim | 1 |
| Ingress | 1 |
| ControllerRevision | 1+ (the StatefulSet's history) |
| ServiceAccount | 1 (`default`) |

**Why `get all` is a lie:** it queries a fixed, short list of kinds. It shows no
ConfigMaps, Secrets, PVCs or Ingresses — the four kinds this project spent most
of its time on.

**Note `kube-root-ca.crt` and the `default` ServiceAccount**: every namespace
gets them automatically. Every pod mounts that ServiceAccount's token by default,
which is a credential you did not ask for (Project 07).

> **Follow-up:** which objects here would survive `kubectl delete namespace`?
> *(None of these — but the PV behind the PVC does, until its reclaim policy acts,
> and the StorageClass and any hostPath PV are cluster-scoped.)*

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Beginner exercises](../beginner.md)** | [Project 02](../../README.md) | **[Intermediate solutions](intermediate.md)** ▶ |
