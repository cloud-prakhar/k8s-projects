# Solutions — Intermediate

---

## 1. Diagnose a broken Service, blind

**The decision tree:**

```bash
kubectl get endpointslices -n task-tracker -l kubernetes.io/service-name=task-api
```

| Endpoints | Next check | Cause |
|---|---|---|
| Empty | `kubectl get pods -n task-tracker` | **0 replicas** if no Pods exist; **selector mismatch** if Pods exist and are Ready |
| Populated | Compare `targetPort` with the container port | **Wrong `targetPort`** |

```bash
# Distinguishing empty-endpoint causes
kubectl get deploy task-api -n task-tracker -o jsonpath='{.spec.replicas}'   # 0 → scaled down
kubectl describe svc task-api -n task-tracker | grep Selector
kubectl get pods -n task-tracker --show-labels                                # compare
```

**Why endpoints split the space:** the EndpointSlice is built purely from *label matching plus readiness*. It proves
nothing about ports. So populated-but-broken can only be a port problem; empty can only be labels or no Ready Pod.

**Common wrong answer:** starting with `kubectl logs`. The app is fine in all three cases — you'd learn nothing.

**Follow-up:** which of the three would an Ingress report as 503 and which as 502? (Empty endpoints → 503; wrong port
→ 502.)

---

## 2. Make a config change roll out automatically

```bash
CHECKSUM=$(kubectl get configmap task-tracker-config -n task-tracker -o yaml | sha256sum | cut -c1-16)
kubectl patch deployment task-api -n task-tracker \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"${CHECKSUM}\"}}}}}"
```

**Why it works:** the annotation is inside `spec.template`, so changing it changes the Pod-template hash → new
ReplicaSet → rolling update. The ConfigMap's *content* now drives the rollout.

In practice a tool computes this. Helm:

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Kustomize does it differently and arguably better — `configMapGenerator` appends a content hash to the ConfigMap's
**name**, so a content change renames the object, which changes the Deployment's reference, which triggers a rollout.
It also leaves the old ConfigMap intact for rollback.

**Why it beats remembering to restart:** a human step that's only needed *sometimes* is a step that gets forgotten
exactly when it matters. And under GitOps there's no human running `rollout restart` at all.

**Follow-up:** what's the downside of a shared ConfigMap with this pattern? (Any key change restarts *every*
workload that references it — argues for per-component ConfigMaps at scale.)

---

## 3. Zero-downtime proof

```bash
# terminal 1
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
sleep 2
while true; do curl -s -o /dev/null -w "%{http_code} " localhost:8080/api/tasks; sleep 0.2; done

# terminal 2
kubectl rollout restart deployment/task-api -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker
```

**With probes:** an unbroken stream of `200`s.

**Without probes** — remove them and repeat:

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"},
       {"op":"remove","path":"/spec/template/spec/containers/0/startupProbe"}]'
kubectl rollout restart deployment/task-api -n task-tracker
```

You'll see `502`s appear during the rollout.

**Why `maxUnavailable: 0` stops being a guarantee:** the Deployment counts a Pod as *available* when it's Ready.
With no readiness probe, Kubernetes has nothing to ask, so a Pod is Ready the instant its container starts —
milliseconds before gunicorn can accept a connection. The controller happily removes an old Pod in exchange for a
new one that isn't serving yet.

**Restore:** `kubectl apply -f manifests/11-health-checks/task-api-deployment.yaml`

**Follow-up:** even *with* probes there's a residual gap at shutdown — endpoint removal and SIGTERM race. See advanced
exercise 4.

---

## 4. Readiness without restart

```bash
kubectl get endpointslices -n task-tracker -w      # terminal 1

POD=$(kubectl get pod -n task-tracker -l app.kubernetes.io/name=task-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -n task-tracker -- python3 -c \
  "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/debug/toggle-ready').read())"

sleep 20
kubectl get pods -n task-tracker        # 0/1 READY, Running, RESTARTS 0
```

**Why it works:** `/debug/toggle-ready` flips a flag so `/healthz` returns 503 while `/livez` still returns 200. The
readiness probe fails → the Pod's `Ready` condition goes false → the EndpointSlice controller removes its IP → kube-proxy
stops routing to it. The liveness probe is unaffected, so nothing restarts.

Toggle again to bring it back — automatically, with no human action.

**Real-world uses:** graceful drain before shutdown, cache warm-up, shedding load when a dependency is unavailable,
and pausing a Pod during maintenance without losing it.

**Follow-up:** why is it *dangerous* to make readiness depend on a shared downstream dependency? (If it goes down,
every replica goes unready simultaneously and you have a total outage instead of degraded service. Sometimes serving
errors beats serving nothing.)

---

## 5. Two versions, one Service

```bash
kubectl get deployment task-api -n task-tracker -o yaml \
  | sed -e 's/name: task-api$/name: task-api-canary/' \
        -e 's/replicas: 3/replicas: 1/' \
  | kubectl apply -f - 2>/dev/null || true
```

Simpler and clearer — copy the manifest, change only the **Deployment name and replicas**, and leave the Pod labels
that the Service selects (`name` + `instance`) **unchanged**.

```bash
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
for i in $(seq 1 12); do curl -s localhost:8080/api/info | python3 -c 'import sys,json;print(json.load(sys.stdin)["pod"])'; done
kill %1
```

**Why it works:** a Service selects **Pods by label**. It has no concept of Deployments and never asks which
controller owns a Pod. Any Ready Pod with matching labels joins the EndpointSlice.

**Controlling the split:** only by **replica ratio** — 1 canary against 3 stable is roughly 25%. That's the
limitation: the granularity is coarse, you can't route by header or user, and you can't shift traffic without
changing Pod counts. Real progressive delivery needs an L7 layer (Ingress with canary annotations, or a service
mesh) — Project 05.

**Follow-up:** what happens to the canary Pods if you `kubectl rollout undo` the stable Deployment? (Nothing — they're
a separate Deployment. Which is exactly why blue/green works this way, and why cleanup discipline matters.)

---

## 6. Debugging with describe only

| Lab | What `describe` alone tells you |
|---|---|
| 2 — ImagePullBackOff | Events: `Failed to pull image "task-api:9.9.9": not found` → wrong tag |
| 6 — Missing ConfigMap key | Events: `couldn't find key NOT_A_REAL_KEY in ConfigMap …` → names the exact key |
| 9 — Readiness failing | Events: `Readiness probe failed: HTTP probe failed with statuscode: 404` → wrong path |

**Which failures need logs:** anything where the container **started and then misbehaved** — lab 3
(`CrashLoopBackOff`, where you need `--previous` for the traceback) and lab 8 (token mismatch, where every Kubernetes
object is healthy and only the app's 401s reveal it).

**The rule:** `describe` explains why a container didn't *start*. Logs explain why a started container isn't
*working*.
