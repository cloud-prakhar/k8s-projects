# Solutions — Advanced

---

## 1. Probes for a slow-starting app

```yaml
startupProbe:
  httpGet: { path: /livez, port: http }
  periodSeconds: 5
  failureThreshold: 24        # 24 × 5s = 120s budget for a 45s boot — generous headroom
  timeoutSeconds: 3

readinessProbe:
  httpGet: { path: /healthz, port: http }
  periodSeconds: 5
  timeoutSeconds: 3           # NOT the 1s default — a loaded app is slowest exactly when probed
  failureThreshold: 3         # ~15s before traffic is withdrawn
  successThreshold: 1         # return to service quickly

livenessProbe:
  httpGet: { path: /livez, port: http }
  periodSeconds: 15
  timeoutSeconds: 3
  failureThreshold: 4         # ~60s of unresponsiveness before a restart — deliberately slow
```

**Why no `initialDelaySeconds`:** it's a fixed guess. Too short → restart loop; too long → every rollout is slower
than it needs to be. The startup probe exits the moment the app is up and only kills after the whole budget.

**Behaviour in each scenario:**

| Scenario | What happens |
|---|---|
| **(a) Normal 45s start** | Startup probe polls every 5s, succeeds around 45–50s. Readiness and liveness then begin. The Pod joins the Service ~50s in. Rollout waits — correctly. |
| **(b) 60s boot** | Still inside the 120s budget. Slower, no restart. Had we used `initialDelaySeconds: 50` with a liveness probe, the container would be killed at ~50s and loop forever. |
| **(c) 5-minute dependency outage** | `/healthz` fails → all replicas leave the Service (503s to clients). `/livez` keeps passing, so **nothing restarts**. When the dependency returns, Pods rejoin automatically with warm caches and connection pools. Had liveness pointed at `/healthz`, every replica would restart repeatedly for five minutes and recovery would be far slower. |

**Too aggressive vs too lenient:**

| Probe | Too aggressive | Too lenient |
|---|---|---|
| Readiness | Flapping in/out of the Service under load; capacity oscillates | Traffic sent to Pods that can't serve |
| Liveness | **Restart storms** — the worst outcome; can take down a healthy fleet | A hung Pod stays in rotation black-holing requests |
| Startup | Container killed mid-boot, forever | A genuinely broken start isn't caught for minutes |

**Follow-up:** why is a liveness restart storm worse than a hung Pod? Because readiness already removes a hung Pod
from traffic — you get degraded capacity. A restart storm removes *all* capacity and adds cold-start load to a
system that's already struggling.

---

## 2. Making the API horizontally scalable without a database

| Approach | How | Trade-offs |
|---|---|---|
| **A. External shared store (Redis/Memcached)** | Replace the Python list with calls to a shared cache | ✅ Genuinely correct; all replicas see the same data. ❌ Adds a dependency and a new failure domain — and Redis itself now needs persistence, which is just "a database" wearing a hat. **This is the honest answer.** |
| **B. Sticky sessions** (`sessionAffinity: ClientIP`) | Pin each client to one Pod | ❌ Not a fix — hides the problem. Data still dies on Pod restart, one client's data is invisible to another, and it breaks entirely behind a NAT or proxy where many clients share an IP. Also defeats load balancing. |
| **C. Single writer + read replicas** | One Pod owns writes, others serve reads from a replicated copy | ❌ Needs replication you'd have to build; the writer is a single point of failure; introduces consistency lag. In Kubernetes you'd express identity with a StatefulSet. Real systems do this — but they call the result a database. |
| **D. StatefulSet + per-Pod PVC** | Each replica gets stable identity and its own volume | ❌ Survives restarts but **shards** the data — replica 0 and replica 1 still hold different tasks. Solves durability, not correctness. |

**Which I'd pick:** A — externalise state. It's the only one that makes replicas genuinely interchangeable, which is
the property that makes horizontal scaling work at all.

**Kubernetes primitives each needs:** A → a Deployment plus a Service for the store (Project 03). B →
`spec.sessionAffinity`. C/D → StatefulSet, headless Service, `volumeClaimTemplates` (Projects 02, 03).

**The real lesson:** "make it stateless" usually means "move the state somewhere that's designed to hold it". You
don't eliminate state — you relocate it to a component built for durability and consistency.

---

## 3. Survive a node failure

**Prediction:** on a single-node cluster, stopping the node container kills the control plane *and* every workload.
`kubectl` itself stops responding — there's no API server to talk to. Nothing recovers, because the thing that would
do the recovering is also gone.

```bash
docker stop kubernetes-lab-control-plane
kubectl get pods -n task-tracker           # connection refused
docker start kubernetes-lab-control-plane
sleep 45
kubectl get pods -n task-tracker           # everything returns; tasks are gone (in-memory)
```

**What you'd need to survive it:**

| Mitigation | Kubernetes feature or infrastructure? |
|---|---|
| Multiple worker nodes | **Infrastructure** — Kubernetes can't schedule onto machines you don't have |
| HA control plane (3+ control-plane nodes, etcd quorum) | Infrastructure |
| Spread replicas across nodes (`podAntiAffinity`) | **Kubernetes** (Project 09) |
| Spread across failure domains (`topologySpreadConstraints`) | **Kubernetes** (Project 09) |
| Survive maintenance (`PodDisruptionBudget`) | **Kubernetes** (Project 05) |
| Automatic node replacement | Infrastructure (cloud autoscaling group / Karpenter, Project 10) |
| Data surviving the node | **Both** — a PVC on network-attached storage, not local disk (Project 02) |

**The point:** Kubernetes gives you *placement* tools. It cannot manufacture hardware redundancy. A single-node
cluster is a single point of failure no matter how good your manifests are.

---

## 4. Closing the last zero-downtime gap

**The race:** when a Pod is deleted, two things happen **in parallel**, not in order:

1. The endpoints controller removes its IP from the EndpointSlice, then every node's kube-proxy must update its
   iptables rules — this takes hundreds of milliseconds to seconds
2. The kubelet sends SIGTERM to the container, which begins shutting down immediately

So for a brief window, kube-proxy on some nodes still routes to a Pod that has already stopped accepting connections.

**Demonstrate it:** run a tight request loop while deleting a Pod, and look for occasional connection resets. It's
timing-dependent and easy to miss on a single-node cluster — which is exactly why people ship this bug.

**The fix:**

```yaml
spec:
  terminationGracePeriodSeconds: 45
  containers:
    - name: task-api
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "10"]
```

**Why sleeping helps when the app is about to die anyway:** `preStop` runs **before** SIGTERM is sent. During those
10 seconds the Pod is already marked Terminating (so it's been removed from EndpointSlices and kube-proxy has caught
up) while the application is *still accepting and serving requests normally*. By the time SIGTERM arrives, no new
traffic is being sent to it. The grace period must exceed the preStop sleep plus the app's longest legitimate
request, or SIGKILL cuts it off mid-response.

**Why it's in Project 05:** it only matters under real traffic with observable error rates. Demonstrating it needs
load generation and metrics, which is the environment Project 05 builds.

---

## Challenge — Rebuild from memory

Reference solution — the fields most people have to look up are marked ⚠️.

```bash
kubectl create namespace task-tracker

kubectl create configmap task-tracker-config -n task-tracker \
  --from-literal=APP_ENV=development \
  --from-literal=LOG_LEVEL=info \
  --from-literal=TASK_API_URL=http://task-api.task-tracker.svc.cluster.local:8080

kubectl create secret generic task-api-secret -n task-tracker \
  --from-literal=API_TOKEN=dev-token-not-for-production

# Generate a skeleton rather than writing YAML from scratch:
kubectl create deployment task-api --image=task-api:1.0.0 -n task-tracker \
  --dry-run=client -o yaml > api.yaml
# then add by hand: replicas, strategy, ports[].name, envFrom, secretKeyRef,
# Downward API POD_NAME, and all three probes.

kubectl expose deployment task-api -n task-tracker --port=8080 --target-port=http
```

**Fields people reliably have to look up** (review these before an interview):

- ⚠️ `env[].valueFrom.configMapKeyRef` vs `envFrom[].configMapRef` — singular key vs whole map
- ⚠️ `valueFrom.fieldRef.fieldPath: metadata.name` — the Downward API path
- ⚠️ `strategy.rollingUpdate.maxSurge` / `maxUnavailable` nesting depth
- ⚠️ `ports[].name` on the container versus `targetPort` on the Service
- ⚠️ Probe structure: `httpGet.path` / `httpGet.port`, and where `periodSeconds` sits relative to it
- ⚠️ `stringData` vs `data` on a Secret

**Use `kubectl explain` for all of them:**

```bash
kubectl explain deployment.spec.strategy.rollingUpdate
kubectl explain pod.spec.containers.readinessProbe --recursive
kubectl explain pod.spec.containers.env.valueFrom
```

**Verify:** `./scripts/validate.sh`

**Follow-up:** which of these did you get wrong, and would `--dry-run=server` have caught it? (Structure yes,
semantics — like a probe pointing at the wrong path — no. That's what the failure labs are for.)
