# Interview Questions — Project 05

[⬅ Project 05](../README.md)

Grouped by resource, with model answers. Every answer can be checked on your own cluster with this project.

---

## Resources and QoS

### 1. What is the difference between a request and a limit?

A **request** is what the scheduler reserves on a node and what the kubelet guarantees under contention; it is
also the denominator of HPA utilisation. A **limit** is a ceiling enforced by the kernel: CPU above it is
**throttled** (the process is paused for the rest of each CFS period), memory above it is **OOM-killed**. Requests
are for placement and fairness; limits are for containment.

### 2. A pod's CPU limit is 500m. What happens when it tries to use 800m?

Nothing is killed. The cgroup's CFS quota lets it run for 50 ms per 100 ms period; then it is paused until the
next period. Latency rises — often dramatically at the tail — while `kubectl top` shows it pinned at 500m. Evidence:
`nr_throttled` in `/sys/fs/cgroup/cpu.stat`.

### 3. And when it exceeds its memory limit?

The kernel's OOM killer terminates the process: `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`, and the
kubelet restarts the container. Memory is not compressible, so there is no "throttling" equivalent.

### 4. Name the QoS classes and how each is derived.

**Guaranteed**: every container has requests == limits for both CPU and memory. **Burstable**: at least one
request or limit, not Guaranteed. **BestEffort**: none at all. It is computed, never set, and decides eviction order
under node memory pressure: BestEffort first, then Burstable using more than its request, Guaranteed last.

### 5. Why can a pod with no requests be dangerous even if it uses little?

The scheduler treats it as costing zero, so it will overpack nodes; under pressure it is evicted first; and no HPA
can compute a utilisation for it. It also hides capacity from everyone else's planning.

### 6. LimitRange vs ResourceQuota?

A **LimitRange** is per-container (or per-pod) policy applied at admission: defaults for missing requests/limits
and min/max bounds. A **ResourceQuota** is a per-namespace total: the sum of requests, limits and object counts.
With a quota covering requests, every new pod must declare them (or get them from a LimitRange) or it is rejected —
and the rejection shows up as a `FailedCreate` event on the **ReplicaSet**, not on a pod.

---

## Autoscaling

### 7. How does the HPA compute the replica count?

Every 15 s it reads per-pod CPU from Metrics Server, divides by each pod's **request**, averages, and computes
`desired = ceil(current × currentUtilisation / target)`, then applies the `behavior` policies and stabilisation
window. 3 pods at 180% of a 60% target → 9.

### 8. The HPA shows `<unknown>/60%` and never scales. Causes?

No metrics (Metrics Server missing or failing — `kubectl top pods`), or no CPU **request** on the pods (utilisation
is a percentage of the request), or pods not yet Ready long enough to report. `kubectl describe hpa` names which.

### 9. Why does the Deployment manifest in this project stop setting `replicas` once the HPA exists?

Both would own `spec.replicas`. Every `kubectl apply` of a manifest with `replicas: 3` would reset an autoscaled 9
back to 3 — mid-peak, silently. Leave the field unset and let the HPA own it.

### 10. Why is scale-up fast and scale-down slow?

Under-provisioning costs users; over-provisioning costs a few minutes of compute. A short or zero stabilisation
window on scale-up reacts to spikes; a longer window and small step on scale-down avoid flapping when load is
bursty.

### 11. The HPA wants 12 pods and only 7 run. Why?

Capacity or quota. Pods beyond node capacity are `Pending` (`Insufficient cpu`) — the HPA scales pods, not nodes;
that is the Cluster Autoscaler or Karpenter. Or the ResourceQuota is exhausted — `FailedCreate` on the ReplicaSet.

---

## Disruption

### 12. What does a PodDisruptionBudget protect against, and what not?

**Voluntary** disruptions that go through the Eviction API: `kubectl drain`, node-group upgrades, the cluster
autoscaler. Not node crashes, OOM kills, or `kubectl delete pod` (which bypasses eviction).

### 13. `kubectl drain` hangs forever. Why, and what do you check?

Usually a PDB that allows zero disruptions: `minAvailable` equal to the replica count, or a single-replica workload
with `minAvailable: 1`. `kubectl get pdb` → `ALLOWED DISRUPTIONS 0`. Drain retries evictions every 5 s,
indefinitely. Fix the budget (prefer `maxUnavailable`), add replicas, or accept the disruption deliberately.

### 14. Why `maxUnavailable: 1` rather than `minAvailable: 2`?

`maxUnavailable` stays meaningful as the HPA changes the replica count; `minAvailable` is absolute and either
becomes too permissive at high counts or blocks every drain at low counts.

### 15. Why pair a PDB with pod anti-affinity?

A PDB limits how fast pods leave; it says nothing about where they are. If all replicas are on one node, an
**involuntary** node loss still takes all of them. Spreading (anti-affinity / topology spread) and budgeting are two
halves of availability.

---

## Rollouts and graceful shutdown

### 16. We see 502s on every rolling update, even with readiness probes. Why?

The end of a pod's life. On deletion, removal from endpoints and SIGTERM happen **in parallel**. The app (gunicorn)
stops accepting on SIGTERM immediately, but kube-proxy rules and the ALB take seconds to stop sending new requests —
which then hit a closed port. Fix: a `preStop` sleep longer than that propagation, and a
`terminationGracePeriodSeconds` covering preStop plus the app's own drain.

### 17. Why does a readiness probe fix the *start* of a rollout but not the end?

Readiness gates when a pod **joins** the endpoints. Removal on termination is not probe-driven — a terminating pod
is removed regardless — so the race at the end needs `preStop`.

### 18. What goes wrong if `terminationGracePeriodSeconds` is shorter than `preStop` + the app's drain?

The kubelet SIGKILLs the container when the grace period expires; in-flight requests are cut off mid-response.
`/api/slow?seconds=40` with a 30 s grace period demonstrates it.

### 19. Startup vs readiness vs liveness — which would you use for an app that takes 60 s to warm up?

A **startup probe** with a budget ≥ 60 s (e.g. 30 × 2 s); readiness and liveness do not run until it passes. Using
`initialDelaySeconds` on liveness instead is fragile: set it too short and a slow node restarts the pod in a loop.

### 20. `maxSurge` / `maxUnavailable` — what would you choose for a 3-replica web tier?

`maxSurge: 1, maxUnavailable: 0`: never fewer than 3 ready pods, one extra during the rollout. It costs one pod of
headroom (and must fit the quota) and makes the rollout slower but safe.

### 21. How do you do a canary with plain Kubernetes objects?

Two Deployments whose pods share the label the **Service** selects on (the application) but whose own selectors
differ (the instance). Traffic splits roughly by pod count. Promote by rolling the stable Deployment and deleting the
canary; abort by deleting the canary. Precise percentages or metric-driven promotion need a mesh, ALB weighted
target groups, or a tool like Argo Rollouts.

### 22. And blue/green?

Two complete Deployments, one Service whose selector names exactly one colour. Switching is one selector patch —
atomic for new connections and instantly reversible — at the cost of running both stacks during the switch.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Exercises — Advanced](../exercises/advanced.md)** | [Project 05](../README.md) | **[Roadmap — Projects 06–09](../../docs/ROADMAP.md)** ▶ |
