# Failure Labs — Project 01

Breaking Kubernetes on purpose is the fastest way to learn to debug it. Every lab follows the same shape:

**Break → Observe the symptom → Investigate → Root cause → Fix → What you learned**

> Reset between labs with `./scripts/deploy.sh` (idempotent) if anything gets tangled.
> Start from a working deployment: `./scripts/validate.sh` should pass.

---

## Lab 1 — Delete a Pod

**Break**

```bash
kubectl get pods -n task-tracker -w        # terminal 1
kubectl delete pod -n task-tracker -l app.kubernetes.io/name=task-api --wait=false | head -1   # terminal 2
```

**Symptom:** the Pod goes `Terminating`, and a **new Pod with a different name and IP** appears within a second.

**Investigate**

```bash
kubectl get events -n task-tracker --sort-by=.lastTimestamp | tail -5
kubectl describe replicaset -n task-tracker | grep -A3 Events
```

**Root cause:** not a failure at all. The ReplicaSet controller observed 2 Pods where it wants 3 and created one from
the template. Level-triggered reconciliation — it doesn't react to the delete *event*, it repeatedly compares reality
to desired state.

**Fix:** nothing to fix.

**What you learned:** Pods are cattle. Replacements are new objects with new names and IPs — never restored copies.
Anything holding a Pod IP is already broken.

---

## Lab 2 — ImagePullBackOff

**Break**

```bash
kubectl set image deployment/task-api task-api=task-api:9.9.9 -n task-tracker
sleep 15
kubectl get pods -n task-tracker
```

**Symptom**

```
task-api-7c4d9f8b6-mnp2q   0/1   ImagePullBackOff   0   15s
task-api-6c9d8f7b5-4kzpq   1/1   Running            0   10m    ← old Pods still serving
```

**Investigate**

```bash
kubectl describe pod -n task-tracker -l app.kubernetes.io/name=task-api | grep -A8 Events
```

```
Failed to pull image "task-api:9.9.9": failed to resolve reference: not found
Back-off pulling image "task-api:9.9.9"
```

**Root cause:** the tag doesn't exist locally, so the kubelet tried to pull it from a registry, where it also doesn't
exist. `BackOff` means it's retrying with exponential delay.

▸ **Note the containment:** `maxUnavailable: 0` meant the rollout stalled instead of taking the app down. Old Pods
kept serving throughout.

**Fix**

```bash
kubectl rollout undo deployment/task-api -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker
```

**What you learned:** `ImagePullBackOff` = wrong name/tag, private registry without `imagePullSecrets`, or (locally)
an image you forgot to `kind load`. And a good Deployment strategy turns a bad deploy into a stalled deploy.

---

## Lab 3 — CrashLoopBackOff

**Break**

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["python3","-c","raise SystemExit(\"config file missing\")"]}]'
sleep 30
kubectl get pods -n task-tracker
```

**Symptom:** a new Pod cycling `Error` → `CrashLoopBackOff`, with `RESTARTS` climbing.

**Investigate**

```bash
POD=$(kubectl get pod -n task-tracker -l app.kubernetes.io/name=task-api \
      --field-selector=status.phase!=Running -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD -n task-tracker
kubectl logs $POD -n task-tracker --previous
kubectl describe pod $POD -n task-tracker | grep -A5 'Last State'
```

```
config file missing
Exit Code: 1
```

**Root cause:** the container process exits immediately. `restartPolicy: Always` restarts it, it exits again, and the
kubelet backs off exponentially (10s, 20s, 40s… capped at 5 min). `CrashLoopBackOff` is the *back-off*, not the
crash — the crash reason is in the logs.

▸ **`--previous` is the key flag.** By the time you look, the current container may be in back-off with no logs;
`--previous` shows the instance that actually died.

**Fix**

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]'
kubectl rollout status deployment/task-api -n task-tracker
```

**What you learned:** `CrashLoopBackOff` → always `kubectl logs --previous`. `describe` gives you the exit code:
1 = app error, 137 = SIGKILL (OOM or liveness), 143 = SIGTERM.

---

## Lab 4 — Service with no endpoints (the classic silent failure)

**Break**

```bash
kubectl patch svc task-api -n task-tracker \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"task-apiz","app.kubernetes.io/instance":"task-api"}}}'
```

**Symptom:** every Pod is `Running` and `1/1 READY`. Nothing is red. But:

```bash
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
sleep 2; curl -s localhost:8080/api/tasks; kill %1
```

```
502 — cannot reach the task API at http://task-api.task-tracker.svc.cluster.local:8080
```

**Investigate**

```bash
kubectl get endpointslices -n task-tracker -l kubernetes.io/service-name=task-api
kubectl describe svc task-api -n task-tracker | grep -A2 -E 'Selector|Endpoints'
kubectl get pods -n task-tracker --show-labels | head -3
```

```
NAME             ADDRESSTYPE   PORTS     ENDPOINTS
task-api-abc12   IPv4          <unset>   <unset>
```

**Root cause:** the selector is a label query. It matches nothing, so the EndpointSlice is empty and there is nowhere
to route. **Kubernetes reports no error** — the Service is doing exactly what you asked.

**Fix**

```bash
kubectl apply -f manifests/04-services/task-api-service.yaml
kubectl get endpointslices -n task-tracker
```

**What you learned:** on any connection failure, **check endpoints first**. Empty endpoints has exactly two causes:
selector/label mismatch, or no Pod is Ready.

---

## Lab 5 — Wrong targetPort

**Break**

```bash
kubectl patch svc task-api -n task-tracker \
  -p '{"spec":{"ports":[{"name":"http","port":8080,"targetPort":9999,"protocol":"TCP"}]}}'
```

**Symptom:** 502 again — but this time endpoints **are** populated (`10.244.0.7:9999`).

**Investigate** — the test that splits the problem in half:

```bash
# Through the Service — fails
kubectl run t --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n task-tracker -- \
  curl -sS -m 5 http://task-api:8080/livez

# Straight to the Pod — works
kubectl port-forward deployment/task-api 9090:8080 -n task-tracker &
sleep 2; curl -s localhost:9090/livez; kill %1
```

**Root cause:** the app listens on 8080; the Service forwards to 9999. Endpoints exist because the *selector* is
correct — endpoints only prove label matching, never that the port is right.

**Fix:** `kubectl apply -f manifests/04-services/task-api-service.yaml`

**What you learned:** "works via port-forward to the Pod, fails through the Service" ⇒ `targetPort`. Referencing the
port **by name** (`targetPort: http`) makes this class of bug nearly impossible.

---

## Lab 6 — Missing ConfigMap key

**Break**

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"MISSING","valueFrom":{"configMapKeyRef":{"name":"task-tracker-config","key":"NOT_A_REAL_KEY"}}}}]'
sleep 10
kubectl get pods -n task-tracker
```

**Symptom:** `CreateContainerConfigError`.

**Investigate**

```bash
kubectl describe pod -n task-tracker -l app.kubernetes.io/name=task-api | grep -A5 Events
```

```
Error: couldn't find key NOT_A_REAL_KEY in ConfigMap task-tracker/task-tracker-config
```

**Root cause:** `optional` defaults to `false`, making the key a hard dependency. The kubelet can't build the
container's environment, so it never starts the container.

**Fix**

```bash
kubectl apply -f manifests/11-health-checks/task-api-deployment.yaml
```

**What you learned:** `CreateContainerConfigError` always means a referenced ConfigMap/Secret **object or key** is
missing, and `describe` names the exact key.

---

## Lab 7 — Missing Secret

**Break**

```bash
kubectl delete secret task-api-secret -n task-tracker
kubectl rollout restart deployment/task-api -n task-tracker
sleep 10
kubectl get pods -n task-tracker
```

**Symptom:** new Pods in `CreateContainerConfigError`; **old Pods still serving**.

**Investigate**

```bash
kubectl describe pod -n task-tracker -l app.kubernetes.io/name=task-api | grep -A3 Events
# Error: secret "task-api-secret" not found
```

**Root cause:** same mechanics as lab 6 at the object level rather than the key level.

**Fix**

```bash
kubectl apply -f manifests/06-secrets/secret.yaml
kubectl rollout status deployment/task-api -n task-tracker
```

**What you learned:** a stalled rollout is a *safe* failure. `maxUnavailable: 0` is what turned "someone deleted a
Secret" from an outage into an alert.

---

## Lab 8 — The tiers disagree about the token

**Break**

```bash
kubectl set env deployment/task-web API_TOKEN=wrong-token -n task-tracker
kubectl rollout status deployment/task-web -n task-tracker
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
sleep 2; curl -s localhost:8080/api/tasks; kill %1
```

**Symptom**

```json
{"error":"invalid or missing X-API-Token"}
```

**Every Pod is `Running` and `1/1 READY`. `kubectl get` shows nothing wrong.**

**Investigate**

```bash
kubectl logs deployment/task-api -n task-tracker --tail=5          # 401s in the access log
kubectl exec deployment/task-web -n task-tracker -- env | grep API_TOKEN
kubectl get secret task-api-secret -n task-tracker -o jsonpath='{.data.API_TOKEN}' | base64 -d; echo
```

**Root cause:** an application-level auth failure. Kubernetes has no opinion about your app's HTTP status codes.

**Fix**

```bash
kubectl apply -f manifests/11-health-checks/task-web-deployment.yaml
kubectl rollout status deployment/task-web -n task-tracker
```

**What you learned:** "all Pods Ready" ≠ "the application works". Green platform status plus a broken app means the
fault is in config or code — go to the logs.

---

## Lab 9 — Readiness probe failing

**Break**

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'
sleep 25
kubectl get pods -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker --timeout=20s
```

**Symptom:** a new Pod stuck at `0/1 Running`; the rollout times out; old Pods keep serving.

**Investigate**

```bash
kubectl describe pod -n task-tracker -l app.kubernetes.io/name=task-api | grep -B1 -A4 'Readiness probe failed'
# Readiness probe failed: HTTP probe failed with statuscode: 404
```

**Root cause:** a 404 is outside 200–399, so the Pod never becomes Ready → never joins the Service → never counts as
available → the rollout can't progress.

**Fix:** `kubectl apply -f manifests/11-health-checks/task-api-deployment.yaml`

**What you learned:** readiness gates *both* Service membership and rollout progress. One misconfigured probe stalls
deploys — which is far better than shipping a broken version.

---

## Lab 10 — Liveness probe pointed at a dependency check

**Break**

```bash
kubectl patch deployment task-api -n task-tracker --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}]'
kubectl rollout status deployment/task-api -n task-tracker

POD=$(kubectl get pod -n task-tracker -l app.kubernetes.io/name=task-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -n task-tracker -- python3 -c \
  "import urllib.request;urllib.request.urlopen('http://localhost:8080/debug/toggle-ready')"
kubectl get pod $POD -n task-tracker -w
```

**Symptom:** after ~30s the container is **killed and restarted**. `RESTARTS` climbs.

**Investigate**

```bash
kubectl describe pod $POD -n task-tracker | grep -A4 'Last State'
kubectl get events -n task-tracker --sort-by=.lastTimestamp | tail -5
```

```
Exit Code: 137                    ← SIGKILL, the kubelet killed it
Liveness probe failed: HTTP probe failed with statuscode: 503
Container task-api failed liveness probe, will be restarted
```

**Root cause:** liveness was checking a *readiness* signal. "Temporarily unable to serve" got treated as
"permanently broken". In a real dependency outage this restarts every replica simultaneously — turning a blip into a
full outage, and usually slowing recovery.

**Fix:** `kubectl apply -f manifests/11-health-checks/task-api-deployment.yaml`

**What you learned:** exit code 137 + `Liveness probe failed` = a self-inflicted restart. Liveness must check **only
the process itself** (`/livez`); readiness may check dependencies (`/healthz`).

---

## Lab 11 — Scale to zero

**Break**

```bash
kubectl scale deployment task-api --replicas=0 -n task-tracker
sleep 5
kubectl get endpointslices -n task-tracker -l kubernetes.io/service-name=task-api
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
sleep 2; curl -s localhost:8080/api/tasks; kill %1
```

**Symptom:** empty endpoints, and the UI returns 502. The Service still exists and still has a ClusterIP.

**Root cause:** a Service is not a server. With no ready Pods behind it there is nothing to DNAT to. In a real cluster
behind an Ingress, this is precisely what produces a **503**.

**Fix**

```bash
kubectl scale deployment task-api --replicas=3 -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker
```

**What you learned:** empty endpoints ⇒ 502/503. The Service object looking healthy tells you nothing.

---

## Lab 12 — Delete the ReplicaSet

**Break**

```bash
kubectl get replicaset -n task-tracker
kubectl delete replicaset -n task-tracker -l app.kubernetes.io/name=task-api
kubectl get replicaset,pods -n task-tracker
```

**Symptom:** the ReplicaSet and its Pods vanish — and a **new ReplicaSet with a new hash immediately appears**,
recreating the Pods.

**Investigate**

```bash
kubectl describe deployment task-api -n task-tracker | grep -A5 Events
kubectl get pod -n task-tracker -o jsonpath='{.items[0].metadata.ownerReferences}' | python3 -m json.tool
```

**Root cause:** two mechanisms at once. **Garbage collection** deleted the Pods because their `ownerReferences`
pointed at the deleted ReplicaSet. **The Deployment controller** then noticed it had no ReplicaSet for its current
template and created one.

▸ Try `--cascade=orphan` to delete a controller while leaving its Pods running, unmanaged.

**What you learned:** ownership is explicit (`ownerReferences`) and drives cascading deletion. Controllers reconcile
at every level — deleting a middle layer just gets it rebuilt.

---

## Debugging Cheat Sheet

| Question | Command |
|---|---|
| What state is it in? | `kubectl get pods -n task-tracker -o wide` |
| Why is it in that state? | `kubectl describe pod <pod> -n task-tracker` — **read the Events at the bottom** |
| What did the app say? | `kubectl logs <pod> -n task-tracker` |
| What did it say before it died? | `kubectl logs <pod> -n task-tracker --previous` |
| Is the Service wired up? | `kubectl get endpointslices -n task-tracker` |
| Is it the Service or the app? | `kubectl port-forward pod/<pod> 9090:8080 -n task-tracker` |
| Can Pods resolve each other? | `kubectl exec -it <pod> -n task-tracker -- nslookup task-api` |
| What just happened? | `kubectl get events -n task-tracker --sort-by=.lastTimestamp` |
| What does this field do? | `kubectl explain deployment.spec.strategy --recursive` |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Clean exit |
| 1 | Application error — check logs |
| 137 | SIGKILL — OOMKilled, or a failed liveness probe |
| 143 | SIGTERM — normal shutdown during a rollout or delete |
