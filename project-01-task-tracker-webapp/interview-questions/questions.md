# Interview Questions — Project 01

Grouped by resource, each with a model answer that states the **mechanism**, not just the definition — that's the
difference between passing and not.

---

## Pods

> 🎯 **What is a Pod, and why doesn't Kubernetes just schedule containers?**

Because the practical unit of an application is often several containers that must share a fate: an app plus a log
shipper reading the same files, or an app plus a proxy sidecar. They need to share a network namespace (talk over
`localhost`), share volumes, land on the **same node**, and live and die together. Bare containers can't express
that. So the smallest schedulable unit is a group of co-located containers — a Pod — even when the group has one
member, which is the common case.

**Follow-up:** *Can two containers in a Pod bind the same port?* No — they share one network namespace, so the second
gets "address already in use".

---

> 🎯 **What happens when you delete a Pod created directly (no controller)?**

It's gone permanently. The Pod object is a record of one specific Pod; deleting it removes the record. The kubelet
restarts *containers* within a Pod, but nothing has been told "there should always be one of these", so nothing
recreates it. That's what controllers are for.

---

> 🎯 **What's the difference between a container restart and a Pod being recreated?**

A container restart is the kubelet restarting a process inside a **surviving** Pod — same name, same IP, `RESTARTS`
increments. A Pod recreation is a controller creating a **new object** — new name, new IP, `RESTARTS` back to 0. Only
the second happens on node failure or during a rolling update.

---

## ReplicaSets and Deployments

> 🎯 **What's the difference between a Deployment and a ReplicaSet? When would you create a ReplicaSet directly?**

A ReplicaSet keeps N identical Pods running — that's all. It reconciles **count**, never **content**: change its Pod
template and running Pods are untouched, because the template is only read when creating a new Pod.

A Deployment manages ReplicaSets to add versioning. On a template change it creates a *new* ReplicaSet (identified by
a `pod-template-hash`) and shifts replicas from old to new per `maxSurge`/`maxUnavailable`, keeping old ReplicaSets
at zero replicas as revision history.

You essentially never create a ReplicaSet directly — you'd give up rolling updates, rollback and history for nothing.

**Follow-up:** *What does `kubectl rollout undo` actually do?* It scales the previous ReplicaSet back up and the
current one down. Nothing is restored; the old template was never deleted. That's why it takes seconds.

---

> 🎯 **Explain `maxSurge` and `maxUnavailable`. What does `maxUnavailable: 0` guarantee?**

`maxSurge` is how many Pods above `replicas` may exist during a rollout; `maxUnavailable` is how many ready Pods you
may drop below it.

`maxUnavailable: 0` guarantees zero-downtime — **but only if you have a readiness probe.** Without one, a Pod counts
as available the moment it's Running, so the rollout advances before the new Pod can serve anything, and the
guarantee is meaningless.

---

> 🎯 **You changed a Deployment's `replicas` field. Does that create a new ReplicaSet?**

No. Only a change to `spec.template` produces a new template hash and therefore a new ReplicaSet. Scaling is
delegated to the existing one.

---

> 🎯 **Why is `spec.selector` immutable, and what does that mean for how you write it?**

Changing it would orphan the existing Pods — the controller would stop recognising what it owns. Kubernetes forbids
it rather than let you strand workloads. Practically: keep selectors **minimal and stable** (name + instance) and put
churny labels like `version` in the Pod template only. Put `version` in the selector and you can never ship a new
version without deleting the Deployment.

---

## Services and networking

> 🎯 **A Pod is `Running` but the Service returns connection refused. Walk me through your debugging.**

1. `kubectl get endpointslices` — empty means the selector doesn't match any Pod's labels, or no Pod is Ready. Those
   are the only two causes.
2. If endpoints exist, compare `targetPort` with the port the app actually listens on.
3. `kubectl port-forward` straight to the Pod. Works → the fault is in the Service layer. Fails → it's the app.
4. Check the app isn't bound to `127.0.0.1` instead of `0.0.0.0` — a classic in containers, and completely silent.

---

> 🎯 **What actually happens when a Pod connects to a ClusterIP?**

Nothing listens on that IP — there's no proxy Pod and no process. kube-proxy programs iptables (or IPVS) rules on
every node that **DNAT** packets destined for the ClusterIP to a real Pod IP from the Service's EndpointSlice. So the
rewrite happens in the kernel before the packet leaves the node.

Consequences: a Service adds essentially no latency, and you can't `ping` a ClusterIP because there's nothing to
answer ICMP.

---

> 🎯 **How does a Service know which Pods are healthy?**

It doesn't — the **EndpointSlice controller** does. It watches Pods matching the Service's selector and includes only
those whose `Ready` condition is true, which is driven by the readiness probe. kube-proxy then programs rules from
that EndpointSlice. So: `readinessProbe → Pod Ready condition → EndpointSlice → routing`.

---

> 🎯 **Why does load balancing look uneven, and why does one client sometimes always hit the same Pod?**

kube-proxy balances **connections at L4**, chosen randomly — not requests, and not round-robin. A client using HTTP
keep-alive holds one connection, so every request on it lands on the same Pod. Per-request balancing needs an L7
proxy, an Ingress controller, or a service mesh.

---

> 🎯 **What are the Service types and when do you use each?**

`ClusterIP` (default) for internal traffic; `NodePort` opens a port on every node (works everywhere, ugly ports, one
port per Service); `LoadBalancer` asks the cloud provider for an external LB (one per Service, costs money);
`Headless` (`clusterIP: None`) returns Pod IPs directly for StatefulSets; `ExternalName` is a CNAME to something
outside the cluster.

For HTTP you generally want an **Ingress** rather than a LoadBalancer per Service — one entrypoint with host/path
routing and TLS.

---

> 🎯 **Why does `type: LoadBalancer` stay `<pending>` on a local cluster?**

Because it's a *request* to a cloud controller manager to provision an external load balancer. Kind and bare-metal
clusters have no such controller, so nothing fulfils it. That's correct behaviour, not a bug. Locally you'd install
Cloud Provider KIND or MetalLB, or use the NodePort the Service already has.

---

## ConfigMaps and Secrets

> 🎯 **You edited a ConfigMap but the app still shows the old value. Why?**

Environment variables are passed at `exec()` time and the Linux process environment is immutable afterwards —
Kubernetes cannot change a running process's environment. The ConfigMap object changed; the container didn't.

Fix: `kubectl rollout restart deployment/<name>`, which patches the Pod template and triggers a normal rolling
update. Better: add a `checksum/config` annotation derived from the ConfigMap so the change *itself* triggers the
rollout.

**Exception:** volume-mounted ConfigMaps *are* refreshed by the kubelet (~60s). Whether the app notices depends on
whether it re-reads the file.

---

> 🎯 **Are Kubernetes Secrets encrypted?**

By default, no. They're base64-**encoded** in etcd — encoding, not encryption. Anyone with `get secrets` in the
namespace, or access to etcd or an etcd backup, can read them.

What actually protects them: encryption at rest (`EncryptionConfiguration`), tight RBAC, and ideally an external
manager (External Secrets Operator with AWS Secrets Manager / Vault / Key Vault) so the value never lives in Git or
sits statically in the cluster.

---

> 🎯 **Then what's the point of a Secret over a ConfigMap?**

Separate RBAC surface, values omitted from `kubectl describe`, encryptable at rest, stored in **tmpfs** (RAM, never
node disk) when mounted as a volume, only distributed to nodes actually running a consuming Pod, and typed so
features like `imagePullSecrets` and Ingress TLS can consume them. It's a marker plus mechanisms — not security by
itself.

---

> 🎯 **Env var or volume mount for a Secret?**

Volume, where you can. Env vars leak into `/proc/<pid>/environ`, crash dumps, child processes, and any log line that
dumps configuration. Volumes are tmpfs-backed and auto-update without a restart.

---

## Probes

> 🎯 **Readiness vs liveness — and what happens if you swap them?**

Readiness answers "can I serve traffic right now?" — failing removes the Pod from Service endpoints without
restarting it. Liveness answers "is this process broken?" — failing **restarts the container**.

Swap them and you get the classic self-inflicted outage: liveness pointed at a dependency-checking endpoint means a
database hiccup restarts every replica simultaneously, turning a blip into a full outage and usually slowing
recovery. Meanwhile readiness pointed at a trivial check keeps routing traffic to Pods that can't serve.

Rule: **liveness checks only the process; readiness may check dependencies.**

---

> 🎯 **Why use a startup probe instead of `initialDelaySeconds`?**

`initialDelaySeconds` is a fixed guess — too short causes a restart loop on slow starts, too long delays every
rollout. A startup probe suspends readiness and liveness until the app is up, exits the moment it is, and only kills
the container if the whole budget (`failureThreshold × periodSeconds`) is exhausted. It adapts.

---

> 🎯 **A Pod shows `1/1 Running` and `RESTARTS: 7`. What do you check?**

`kubectl describe pod` for `Last State` and the exit code, and `kubectl logs --previous` for what the dying instance
said. Exit code 137 means SIGKILL — either OOMKilled (check memory limits) or a failing liveness probe (check the
Events for `Liveness probe failed`). Restarts climbing with no crash in the logs almost always means a misconfigured
liveness probe.

---

## Operations

> 🎯 **What does `kubectl apply` do that `kubectl create` doesn't?**

`apply` is declarative and idempotent: it creates the object if absent and patches it if present, tracking a
last-applied configuration so it can compute a three-way merge. `create` fails if the object exists. That's why every
manifest workflow uses `apply`.

---

> 🎯 **Where do you look when a Pod won't start?**

`kubectl describe pod` — specifically the **Events** section at the bottom. That's the scheduler's, kubelet's and
runtime's timeline, and it answers "why" far more often than logs do. Logs only exist once a container actually
started.

---

> 🎯 **What's the difference between `kubectl logs` and `kubectl logs --previous`?**

`logs` shows the current container instance. `--previous` shows the one that died. In `CrashLoopBackOff` the current
instance is often in back-off with nothing to show, so `--previous` is the only way to see the actual crash.

---

> 🎯 **Deleting a namespace — what does it and doesn't it remove?**

It removes everything **namespaced**: Pods, Deployments, Services, ConfigMaps, Secrets, PVCs. It does **not** remove
cluster-scoped objects: PersistentVolumes, StorageClasses, ClusterRoles, ClusterRoleBindings, PriorityClasses, Nodes.
A PV with a `Retain` reclaim policy will sit in `Released` forever holding storage.

Deletion is also asynchronous — the namespace controller enumerates resource types and deletes what it finds, which
is why a stuck finalizer leaves it `Terminating` indefinitely.

---

> 🎯 **What are `ownerReferences` and why do they matter?**

Each Pod created by a ReplicaSet carries an `ownerReferences` entry pointing at it (and the ReplicaSet points at the
Deployment). The garbage collector uses this to cascade deletions: delete the Deployment and the ReplicaSets and Pods
go with it. `--cascade=orphan` breaks the link and leaves them running, unmanaged.

---

## Scenario questions

> 🎯 **Your rollout is stuck. Old Pods are serving; new Pods never become Ready. Walk me through it.**

First: this is the **safe** failure mode. `maxUnavailable: 0` plus a readiness probe means a broken version can't
take down the running one.

`kubectl describe pod` on a new Pod and read the Events. Likely: `ImagePullBackOff` (wrong tag or missing registry
credentials), `CreateContainerConfigError` (missing ConfigMap/Secret key), or `Readiness probe failed` (wrong path or
port, or the app genuinely can't serve). Then either fix forward or `kubectl rollout undo`.

---

> 🎯 **All Pods are Running and Ready, endpoints are populated, and the app still returns errors. What now?**

Kubernetes is healthy, so the fault is in the application or its configuration. Go to `kubectl logs`. In this project
the canonical example is the two tiers holding different `API_TOKEN` values: every Pod is green and every request is
a 401. Platform status tells you nothing about business correctness.

---

> 🎯 **How would you make this app safe to run at 3 replicas when its state is in memory?**

You can't, as designed — three replicas means three independent task lists, and which one you get depends on which
Pod kube-proxy picked. The honest fix is externalising state to a shared datastore (which is what Project 02 does
with PostgreSQL plus a PersistentVolume). Sticky sessions would hide it, not fix it: you'd still lose data on every
Pod restart.


---

## Verify these answers yourself

Don't take a model answer on trust — that's how wrong confidence gets built. Each of these is the primary source for
the section above. *(All links verified 2026-08-09.)*

| Section | Primary source |
|---|---|
| Pods | [Pods](https://kubernetes.io/docs/concepts/workloads/pods/) · [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) |
| ReplicaSets & Deployments | [ReplicaSet](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/) · [Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) |
| Services & networking | [Service](https://kubernetes.io/docs/concepts/services-networking/service/) · [Virtual IPs](https://kubernetes.io/docs/reference/networking/virtual-ips/) · [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) |
| ConfigMaps & Secrets | [ConfigMap](https://kubernetes.io/docs/concepts/configuration/configmap/) · [Secret](https://kubernetes.io/docs/concepts/configuration/secret/) · [Encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) |
| Probes | [Configure probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) |
| Operations | [Declarative management](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/) · [Garbage collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/) · [Owners and dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/) |

> **The best interview answer cites the mechanism.** If you can say *which controller* does the thing and *what it
> watches*, you've demonstrated understanding rather than recall.
