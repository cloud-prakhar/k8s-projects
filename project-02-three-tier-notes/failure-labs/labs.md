# Failure Labs — Project 02

[⬅ Project 02](../README.md)

Twelve deliberate breakages. Each one: **break → observe → investigate → root
cause → fix → what you learned.**

> **Do these on a working deployment.** Run `./scripts/validate.sh` first, and
> again after each fix — it exits non-zero when something is genuinely broken, so
> it is also how you confirm a repair.

Every lab is reversible. The fix is always in the lab.

| # | You break | You should see | You learn |
|---|---|---|---|
| [1](#lab-1--imagepullbackoff) | The image tag | `ImagePullBackOff` | Kind nodes have their own image store |
| [2](#lab-2--the-database-pod-loses-its-data) | Storage (revert to `emptyDir`) | Notes vanish on pod deletion | Container filesystems are ephemeral |
| [3](#lab-3--a-pvc-that-never-binds) | The StorageClass name | PVC `Pending`, pod `Pending` | Chase storage failures backwards |
| [4](#lab-4--two-writers-one-volume) | Scale the database to 2 | `postmaster.pid` exists / Multi-Attach | Why Deployments cannot run databases |
| [5](#lab-5--a-service-with-no-endpoints) | The Service selector | 502, empty EndpointSlice | Selectors are the wiring |
| [6](#lab-6--the-secret-and-the-database-disagree) | The password | `password authentication failed` | Green pods, broken app |
| [7](#lab-7--ingress-404-vs-502-vs-503) | Host, port, replicas | Three different codes | One-command ingress diagnosis |
| [8](#lab-8--liveness-pointed-at-a-dependency) | The liveness path | `CrashLoopBackOff`, exit 137 | The classic self-inflicted outage |
| [9](#lab-9--readiness-that-never-passes) | The readiness path | Rollout stalls at `0/1` | Readiness gates rollouts |
| [10](#lab-10--the-init-container-that-waits-forever) | The init command | `Init:0/1` forever | A different failure from a crash |
| [11](#lab-11--per-pod-dns-that-does-not-resolve) | `serviceName` | NXDOMAIN on a healthy pod | StatefulSet identity is not automatic |
| [12](#lab-12--the-statefulset-is-deleted-and-the-disk-is-not) | Delete the StatefulSet | PVC still `Bound` | Data outlives workloads |

---

## Lab 1 — ImagePullBackOff

**Break:**

```bash
kubectl set image deployment/notes-api notes-api=notes-api:9.9.9 -n notes-platform
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
```

**Symptom:**

```
NAME                         READY   STATUS             RESTARTS   AGE
notes-api-6f4d8c9b7-8xk2m    1/1     Running            0          20m
notes-api-84f7d9c6b-p2vnl    0/1     ImagePullBackOff   0          25s
```

**Investigate:**

```bash
kubectl describe pod -n notes-platform -l app.kubernetes.io/name=notes-api | grep -A6 Events
```

```
Warning  Failed  kubelet  Failed to pull image "notes-api:9.9.9": failed to resolve reference
Warning  Failed  kubelet  Error: ErrImagePull
Normal   BackOff kubelet  Back-off pulling image "notes-api:9.9.9"
```

**Root cause:** `notes-api:9.9.9` was never built or loaded into the cluster, so
the kubelet tried to pull it from Docker Hub — where it does not exist.
`ErrImagePull` is the first attempt; `ImagePullBackOff` is the retry with
exponential backoff.

▸ **Note the old pod is still `1/1 Running` and still serving.**
`maxUnavailable: 0` meant the rollout stalled instead of taking the API down.

**Fix:**

```bash
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
kubectl rollout status deployment/notes-api -n notes-platform
```

**What you learned:** `ImagePullBackOff` is a *name resolution* problem for
images: the kubelet asked a registry for a name and did not get it. The usual
causes are a tag that was never pushed, a typo in the repository name, or a
private repository with no `imagePullSecret` on the pod.

---

## Lab 2 — The database pod loses its data

**Break** — go back to the stage 07 `emptyDir` version:

```bash
kubectl port-forward svc/notes-web 8080:80 -n notes-platform &
sleep 2
curl -sX POST localhost:8080/api/notes -H 'Content-Type: application/json' \
  -d '{"body":"about to be lost"}'
kill %1

kubectl delete statefulset postgres -n notes-platform
kubectl apply -f manifests/07-storage/01-postgres-deployment-emptydir.yaml
kubectl rollout status deployment/postgres -n notes-platform
```

**Symptom:** the new database is empty except for the two seed rows — your note
never existed in *this* volume.

```bash
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c 'SELECT count(*) FROM notes'
```

**Now delete the pod and watch it happen again:**

```bash
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c "INSERT INTO notes (body) VALUES ('also about to be lost')"
kubectl delete pod -n notes-platform -l app.kubernetes.io/name=postgres
kubectl rollout status deployment/postgres -n notes-platform
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c 'SELECT count(*) FROM notes'
```

**Investigate:**

```bash
kubectl get deployment postgres -n notes-platform \
  -o jsonpath='{.spec.template.spec.volumes}' | python3 -m json.tool
```

```json
[{"emptyDir": {}, "name": "data"}, …]
```

**Root cause:** an `emptyDir` is created when the pod is assigned to a node and
**deleted when the pod leaves that node**. It survives a *container* restart, not
a *pod* deletion. And the seed rows return every time because the data directory
is empty on every start, so `/docker-entrypoint-initdb.d/` runs again.

**Fix:**

```bash
kubectl delete deployment postgres -n notes-platform
kubectl apply -f manifests/08-statefulsets/01-postgres-headless-service.yaml
kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
```

**What you learned:** "it worked when I restarted the container" is not evidence
of persistence. Test by deleting the **pod**.

---

## Lab 3 — A PVC that never binds

**Break:**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-claim
  namespace: notes-platform
spec:
  storageClassName: fast-ssd
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: uses-broken-claim
  namespace: notes-platform
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: broken-claim
EOF

kubectl get pod uses-broken-claim -n notes-platform
```

**Symptom:**

```
NAME                READY   STATUS    RESTARTS   AGE
uses-broken-claim   0/1     Pending   0          30s
```

**Investigate — and note that the pod's error points somewhere else:**

```bash
kubectl describe pod uses-broken-claim -n notes-platform | grep -A4 Events
```

```
Warning  FailedScheduling  default-scheduler  0/2 nodes are available: pod has unbound
immediate PersistentVolumeClaims.
```

```bash
kubectl describe pvc broken-claim -n notes-platform | tail -4
```

```
Warning  ProvisioningFailed  persistentvolume-controller
storageclass.storage.k8s.io "fast-ssd" not found
```

**Root cause:** no such StorageClass ⇒ no provisioner ⇒ no PV ⇒ nothing to bind
⇒ the pod cannot be scheduled.

**Fix:**

```bash
kubectl delete pod uses-broken-claim -n notes-platform
kubectl delete pvc broken-claim -n notes-platform
kubectl get storageclass          # use a name that exists
```

**What you learned:** **chase storage failures backwards.** Pod → PVC → PV →
StorageClass. The pod's message names the PVC; the PVC's message names the real
cause. And remember `Pending` on a `WaitForFirstConsumer` PVC with **no pod yet**
is correct, not broken.

---

## Lab 4 — Two writers, one volume

**Break:**

```bash
kubectl scale statefulset/postgres --replicas=0 -n notes-platform
kubectl apply -f manifests/07-storage/06-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n notes-platform

kubectl patch deployment postgres -n notes-platform \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
kubectl scale deployment/postgres --replicas=2 -n notes-platform
sleep 20
kubectl get pods -n notes-platform -l app.kubernetes.io/name=postgres
```

**Symptom (single node — both pods on one node, RWO permits it):**

```bash
kubectl logs -n notes-platform -l app.kubernetes.io/name=postgres --tail=5 --prefix
```

```
FATAL:  lock file "postmaster.pid" already exists
HINT:  Is another postmaster (PID 1) running in data directory "/var/lib/postgresql/data/pgdata"?
```

**Symptom (multi-node — the pods land apart):**

```
Warning  FailedAttachVolume  attachdetach-controller  Multi-Attach error for volume "pvc-…"
```
…and the second pod sits in `ContainerCreating` forever.

**Investigate:**

```bash
kubectl get pods -n notes-platform -l app.kubernetes.io/name=postgres -o wide
kubectl get pvc postgres-data -n notes-platform -o jsonpath='{.spec.accessModes}'; echo
```

**Root cause:** every replica of a Deployment shares **one** PVC, because a
Deployment has one pod template naming one claim. `ReadWriteOnce` allows
attachment on one node — so on a single node two Postgres processes reach the
same data directory and the second refuses to start; across nodes, the attach
itself is rejected.

▸ **Note what would have happened without the lock file:** two PostgreSQL
processes writing one data directory corrupts it. The lock is PostgreSQL
protecting you, not Kubernetes.

**Fix:**

```bash
kubectl delete deployment postgres -n notes-platform
kubectl delete pvc postgres-data -n notes-platform
kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
```

**What you learned:** this is not a configuration mistake — it is the structural
limit of Deployments for stateful workloads, and the reason `volumeClaimTemplates`
exists.

---

## Lab 5 — A Service with no endpoints

**Break:**

```bash
kubectl patch service postgres -n notes-platform \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"postgress"}}}'
```

**Symptom:** the UI shows *"Cannot load notes"*, and within ~15 seconds the API
pods go to `0/1` — their readiness probe cannot reach the database. Every pod is
still `Running`; `kubectl get deployments` looks fine.

**Investigate:**

```bash
kubectl get endpointslices -n notes-platform -l kubernetes.io/service-name=postgres
```

```
NAME             ADDRESSTYPE   PORTS     ENDPOINTS   AGE
postgres-b8vzc   IPv4          <unset>   <unset>     35m
```

```bash
kubectl get svc postgres -n notes-platform -o jsonpath='{.spec.selector}'; echo
kubectl get pods -n notes-platform --show-labels | grep postgres
```

**Root cause:** the selector matches no pods, so the EndpointSlice is empty and
kube-proxy has nowhere to send packets. **Kubernetes reports no error for this** —
an empty backend set is a legal state.

**Fix:**

```bash
kubectl apply -f manifests/04-services/postgres-service.yaml
sleep 20 && kubectl get pods -n notes-platform
```

**What you learned:** `Service → EndpointSlice → Pods` is the debugging path.
Check endpoints **before** logs. And notice the readiness probes did their job —
the API pods removed themselves from service rather than serving errors.

---

## Lab 6 — The Secret and the database disagree

**Break:**

```bash
kubectl patch secret postgres-secret -n notes-platform \
  -p '{"stringData":{"POSTGRES_PASSWORD":"a-different-password"}}'
kubectl rollout restart deployment/notes-api -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform --timeout=60s || true
```

**Symptom:** the API pods never become Ready. The database is `1/1` and perfectly
healthy.

**Investigate:**

```bash
kubectl logs deployment/notes-api -n notes-platform --tail=5
```

```
level=WARNING msg=readiness failing: connection failed: … FATAL:  password authentication
failed for user "notes"
```

**Root cause:** PostgreSQL reads `POSTGRES_PASSWORD` **only when it initialises
an empty data directory**. The volume is not empty, so the database still has the
original password while the API now has the new one.

▸ **This is a genuine production hazard.** Rotating a database password means
changing it *in the database* first (`ALTER USER … PASSWORD`), then in the
Secret, then restarting the clients.

**Fix — do it properly:**

```bash
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "ALTER USER notes PASSWORD 'a-different-password'"
kubectl rollout status deployment/notes-api -n notes-platform
```

**Or revert:**

```bash
kubectl apply -f manifests/06-secrets/secret.yaml
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "ALTER USER notes PASSWORD 'dev-password-not-for-production'"
kubectl rollout restart deployment/notes-api -n notes-platform
```

**What you learned:** a shared credential has **two** sides, and changing one is
half a change. Also: this failure was *caught* by the readiness probe instead of
being served to users — which is the entire argument for checking dependencies in
readiness.

---

## Lab 7 — Ingress 404 vs 502 vs 503

**Break, three ways, and read the code each time.**

**404 — no rule matched:**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: wrong.local' http://localhost/
```

**503 — the rule matched, no ready endpoints:**

```bash
kubectl scale deployment/notes-api --replicas=0 -n notes-platform
sleep 5
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: notes.local' http://localhost/api/notes
kubectl scale deployment/notes-api --replicas=2 -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform
```

**502 — endpoints exist, connecting failed:**

```bash
kubectl patch service notes-api -n notes-platform \
  -p '{"spec":{"ports":[{"name":"http","port":8080,"targetPort":9999}]}}'
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: notes.local' http://localhost/api/notes
kubectl apply -f manifests/04-services/notes-api-service.yaml
```

**Investigate each:**

```bash
kubectl describe ingress notes-ingress -n notes-platform | grep -A6 Rules
kubectl get endpointslices -n notes-platform
POD=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl logs -n ingress-nginx "$POD" --tail=10
```

**Root causes and the table to memorise:**

| Code | Meaning | Look at |
|---|---|---|
| **404** | No rule matched the Host and path | Ingress rules; the Host header you sent |
| **503** | Rule matched; **no ready endpoints** | Pod readiness, EndpointSlices |
| **502** | Endpoints exist; connection or response failed | `targetPort`, app logs, `0.0.0.0` binding |

**What you learned:** three codes, three completely different investigations.
This is a standard interview question, and getting it right turns a vague
"the ingress is broken" into a one-command diagnosis.

---

## Lab 8 — Liveness pointed at a dependency

**The most valuable lab in this project.**

**Break:**

```bash
kubectl patch deployment notes-api -n notes-platform --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}]'
kubectl rollout status deployment/notes-api -n notes-platform

# Simulate a brief database problem
kubectl scale statefulset/postgres --replicas=0 -n notes-platform
sleep 75
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
```

**Symptom:**

```
NAME                         READY   STATUS             RESTARTS      AGE
notes-api-5c7d9f8b6-k2mzq    0/1     CrashLoopBackOff   3 (25s ago)   3m
```

**Investigate:**

```bash
kubectl describe pod -n notes-platform -l app.kubernetes.io/name=notes-api \
  | grep -E 'Last State|Reason|Exit Code|Liveness probe failed'
```

```
Last State:     Terminated
  Reason:       Error
  Exit Code:    137
Warning  Unhealthy  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 503
```

**Root cause:** liveness asked *"can you reach the database?"* and killed the
container for answering honestly. **Restarting does not conjure a database.** So
the pods restart, fail, back off, restart — and the backoff outlives the original
outage. You turned a recoverable dependency blip into a compounding outage of
your own making.

▸ **Exit code 137 = 128 + 9 = SIGKILL**, sent by the kubelet. It is the
fingerprint of this bug (and of an OOM kill — check `Reason` to tell them apart).

**Fix:**

```bash
kubectl scale statefulset/postgres --replicas=1 -n notes-platform
kubectl wait --for=condition=Ready pod/postgres-0 -n notes-platform --timeout=180s
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
kubectl rollout status deployment/notes-api -n notes-platform
```

**What you learned:** **liveness checks the process; readiness checks the
service.** Compare with the correct behaviour: with liveness on `/livez`, the
same database outage takes the pods out of the EndpointSlice, leaves them
`0/1 Running` with `RESTARTS 0`, and they rejoin automatically when the database
returns — no restarts, no human.

---

## Lab 9 — Readiness that never passes

**Break:**

```bash
kubectl patch deployment notes-web -n notes-platform --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"}]'
kubectl rollout status deployment/notes-web -n notes-platform --timeout=45s || true
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-web
```

**Symptom:** new pods reach `Running` and stay at `0/1`. The rollout never
completes, and `rollout status` times out.

**Investigate:**

```bash
kubectl describe pod -n notes-platform -l app.kubernetes.io/name=notes-web | grep -A4 Events
```

```
Warning  Unhealthy  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```

**Root cause:** `/ready` does not exist; 404 is not 2xx/3xx, so the probe fails
forever. The pod is never added to the EndpointSlice, so it never counts as
available, so `maxUnavailable: 0` refuses to remove an old pod.

▸ **The site never went down.** The stall is the feature.

**Fix:**

```bash
kubectl apply -f manifests/11-health-checks/notes-web-deployment.yaml
kubectl rollout status deployment/notes-web -n notes-platform
```

**What you learned:** a stalled rollout with `0/1 Running` pods is a readiness
failure, and `describe` gives you the exact status code. Compare with lab 8: same
probe mechanism, opposite consequence.

---

## Lab 10 — The init container that waits forever

**Break:**

```bash
kubectl patch deployment notes-api -n notes-platform --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/command/2","value":"until pg_isready -h nowhere.invalid -p 5432 -U notes; do echo waiting; sleep 2; done"}]'
sleep 15
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
```

**Symptom:**

```
NAME                         READY   STATUS     RESTARTS   AGE
notes-api-6f4d8c9b7-8xk2m    1/1     Running    0          40m
notes-api-79bd5c8f4-mn2xq    0/1     Init:0/1   0          15s
```

**Investigate:**

```bash
# The app container has no logs — it does not exist yet
kubectl logs -n notes-platform -l app.kubernetes.io/name=notes-api --tail=3
# Error from server (BadRequest): container "notes-api" in pod "…" is waiting to start: PodInitializing

# You must ask for the INIT container by name
kubectl logs -n notes-platform -l app.kubernetes.io/name=notes-api -c wait-for-postgres --tail=3
kubectl describe pod -n notes-platform -l app.kubernetes.io/name=notes-api | grep -A8 'Init Containers'
```

**Root cause:** the wait loop can never succeed, and it has no timeout. An init
container with an unbounded wait is an unbounded wait.

▸ **`Init:0/1` is not `CrashLoopBackOff`.** Nothing is crashing — the app
container has never started.

**Fix:**

```bash
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
kubectl rollout status deployment/notes-api -n notes-platform
```

**What you learned:** `Init:0/N` means *"read the init container's logs, with
`-c`"*. And give production wait-loops a bounded retry that eventually fails
loudly — an infinite wait hides the real fault behind a status that looks like
patience.

---

## Lab 11 — Per-pod DNS that does not resolve

**Break:**

```bash
kubectl patch statefulset postgres -n notes-platform \
  -p '{"spec":{"serviceName":"typo-headless"}}'
kubectl delete pod postgres-0 -n notes-platform
kubectl wait --for=condition=Ready pod/postgres-0 -n notes-platform --timeout=180s
```

**Symptom:** everything looks perfect —

```bash
kubectl get statefulset,pods -n notes-platform
# statefulset.apps/postgres   1/1
# pod/postgres-0              1/1   Running
```

— and yet:

```bash
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -n notes-platform -- \
  nslookup postgres-0.postgres-headless.notes-platform.svc.cluster.local
```

```
** server can't find postgres-0.postgres-headless.notes-platform.svc.cluster.local: NXDOMAIN
```

**Investigate:**

```bash
kubectl get statefulset postgres -n notes-platform -o jsonpath='{.spec.serviceName}'; echo
kubectl get svc -n notes-platform
kubectl get pod postgres-0 -n notes-platform -o jsonpath='{.spec.subdomain}'; echo
```

**Root cause:** per-pod DNS records are created for the Service named in
`serviceName`, via the pod's `subdomain`. Point it at a Service that does not
exist and the records are simply never made. **Nothing validates the name** — it
is a string, and the pods run happily without it.

▸ The application still works, because `notes-api` uses the *ClusterIP* Service.
Only member-aware clients — replication, admin tooling, another StatefulSet
member — would break. That is what makes this failure so easy to ship.

**Fix:**

```bash
kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl delete pod postgres-0 -n notes-platform
kubectl wait --for=condition=Ready pod/postgres-0 -n notes-platform --timeout=180s
```

**What you learned:** a healthy StatefulSet whose members cannot resolve each
other is a `serviceName` mistake, or a Service that is not headless. Check both
in one command: `kubectl get svc <serviceName> -o jsonpath='{.spec.clusterIP}'`
must print `None`.

---

## Lab 12 — The StatefulSet is deleted and the disk is not

**Break:**

```bash
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "INSERT INTO notes (body) VALUES ('still here after the delete')"
kubectl delete statefulset postgres -n notes-platform
kubectl get pods,pvc,pv -n notes-platform
```

**Symptom:** no pod, no StatefulSet — and:

```
NAME                                              STATUS   VOLUME        CAPACITY   STORAGECLASS
persistentvolumeclaim/postgres-data-postgres-0    Bound    pvc-2c9d4a…   1Gi        standard
```

The claim is still `Bound`, still holding disk, with nothing using it.

**Investigate:**

```bash
kubectl get pvc postgres-data-postgres-0 -n notes-platform -o jsonpath='{.metadata.ownerReferences}'; echo
```

▸ **Empty.** The PVC has no owner reference to the StatefulSet, which is exactly
why garbage collection does not touch it.

**Root cause:** working as designed. Deleting a workload must never destroy its
data. The same applies on scale-down: going from 3 replicas to 1 leaves two PVCs
behind.

**Fix / prove the upside:**

```bash
kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c "SELECT body FROM notes ORDER BY id DESC LIMIT 1"
```

▸ `still here after the delete`. Pod 0 reattached to its old volume.

**What you learned:** deleting a StatefulSet is not cleanup — auditing orphaned
PVCs belongs on your operational checklist, and on a cloud those orphans are a
monthly bill. `./scripts/cleanup.sh` in this project checks for them explicitly.
Kubernetes 1.27+ offers `persistentVolumeClaimRetentionPolicy` to opt into
deletion; the default is to keep, and for a database that default is right.

---

## Debugging cheat sheet

**The universal first three commands:**

```bash
kubectl get pods -n notes-platform -o wide
kubectl describe pod <pod> -n notes-platform        # read the Events at the bottom
kubectl get events -n notes-platform --sort-by=.lastTimestamp | tail -20
```

**Then, by symptom:**

| Symptom | Next command |
|---|---|
| `Pending` | `kubectl describe pod` → then `kubectl describe pvc` if it mentions volumes |
| `Init:0/1` | `kubectl logs <pod> -c <init-container>` |
| `ImagePullBackOff` | `kubectl describe pod` — then `docker push` the missing tag |
| `CrashLoopBackOff` | `kubectl logs <pod> --previous` |
| `CreateContainerConfigError` | `kubectl describe pod` — it names the missing key |
| `0/1 Running` | `kubectl describe pod` → readiness probe events |
| `RESTARTS` climbing | `kubectl describe pod` → `Exit Code` and `Last State` |
| 502 / 503 from the UI | `kubectl get endpointslices -n notes-platform` |
| Empty endpoints | Compare `svc -o jsonpath='{.spec.selector}'` with `pods --show-labels` |
| PVC `Pending` | `kubectl describe pvc` → then `kubectl get storageclass` |
| DNS NXDOMAIN | `kubectl run … nslookup <fqdn>`; check the namespace in the name |

### Exit codes

| Code | Means |
|---|---|
| `0` | Clean exit — for a long-running container, usually a misconfigured command |
| `1` | Application error — read the logs |
| `137` | `128 + 9` = **SIGKILL**. A failed liveness probe, or an OOM kill (check `Reason`) |
| `143` | `128 + 15` = SIGTERM — a normal shutdown |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Manual steps](../scripts/manual-steps.md)** | [Project 02](../README.md) | **[Exercises](../exercises/beginner.md)** ▶ |
