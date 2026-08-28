# Interview Questions — Project 02

[⬅ Project 02](../README.md)

Grouped by resource, with model answers. These are the questions this project's
material actually prepares you for — every one of them can be verified on your
own cluster, and §"Verify these answers yourself" at the end shows you how.

---

## Storage

### 1. Walk me through what happens when a pod uses a PersistentVolumeClaim.

The pod's `spec.volumes` names a **claim**, not a disk. The claim states what is
needed: a StorageClass, an access mode and a size.

If the class uses `WaitForFirstConsumer`, nothing is provisioned until the
scheduler picks a node. Then the class's **provisioner** creates real storage and
a **PersistentVolume** object describing it; the PV controller binds PVC ↔ PV
one-to-one; the kubelet mounts it into the container at `mountPath`.

Delete the pod and the PVC and PV are untouched — which is why the replacement
finds the data waiting.

**The point:** the application author says what they need; the cluster decides
how. That indirection is what makes a manifest portable between a laptop and EKS.

### 2. What is the difference between a PV, a PVC and a StorageClass?

- **PV** — a piece of storage that *exists*. Cluster-scoped.
- **PVC** — a *request* for storage. Namespaced. Binds to exactly one PV.
- **StorageClass** — a *template* naming a provisioner that creates PVs on
  demand, plus the reclaim policy and binding mode they inherit.

Without a StorageClass someone must hand-write a PV for every workload. With one,
the claim is enough.

### 3. A PVC is stuck in `Pending`. Walk me through your debugging.

```bash
kubectl describe pvc <name> -n <ns>          # the reason is here, never in `get`
```

Then, in order of likelihood:

1. **No pod yet, and the class is `WaitForFirstConsumer`** — this is correct
   behaviour, not a fault.
2. **The StorageClass does not exist** — `storageclass … not found`.
3. **No default class**, and the PVC omitted `storageClassName`.
4. **An access mode the storage cannot provide** — `ReadWriteMany` on
   node-local or block storage.
5. **No PV large enough** for static provisioning.
6. **The provisioner is not running** — check its pod.

The pod's own error (`pod has unbound immediate PersistentVolumeClaims`) points
at the PVC. **Always chase storage failures backwards: pod → PVC → PV → class.**

### 4. What is the difference between `emptyDir`, `hostPath` and a PVC?

| | Survives container restart | Survives pod deletion | Survives node loss |
|---|:--:|:--:|:--:|
| `emptyDir` | ✅ | ❌ | ❌ |
| `hostPath` | ✅ | ✅ | ❌ — the data is stranded on that node |
| PVC + network storage | ✅ | ✅ | ✅ |

`emptyDir` is scratch space with a pod-shaped lifetime — caches, or a channel
between containers in one pod. `hostPath` is for node-level agents that genuinely
need the host, and it is a container-escape risk that `restricted` Pod Security
Standards forbid outright. Only a PVC is persistence.

### 5. Explain access modes. Does `ReadWriteMany` let me run two PostgreSQL pods?

`ReadWriteOnce` — one **node** may mount it read-write. `ReadWriteOncePod` — one
**pod**, cluster-wide. `ReadOnlyMany`, `ReadWriteMany` — many nodes.

**No.** `ReadWriteMany` would happily let two PostgreSQL processes open one data
directory and corrupt it. Access modes tell the scheduler and CSI driver which
attachments to permit; they say nothing about whether the *software* tolerates
concurrent writers. Multi-writer databases replicate — they do not share a
filesystem.

### 6. What does `reclaimPolicy` do, and which should I use?

It decides what happens to the PV when its claim is deleted.

- **`Delete`** — the PV and the underlying storage are destroyed. Convenient,
  and one wrong `kubectl delete pvc` from permanent loss.
- **`Retain`** — the PV remains in phase `Released` with the data intact, and it
  cannot be reused until an administrator clears the `claimRef`.

Use `Retain` for anything you care about, and put "reap released volumes" in a
runbook — otherwise you pay for orphaned disks indefinitely.

### 7. Why did my `init.sql` change do nothing after I edited the ConfigMap?

Two independent reasons, and both are worth knowing:

1. The `postgres` image runs `/docker-entrypoint-initdb.d/` scripts **only when
   the data directory is empty**. Once a PersistentVolume holds a database, that
   is never true again.
2. The file is mounted with **`subPath`**, and subPath mounts are resolved once
   at pod start and never refreshed by the kubelet.

Entrypoint scripts are for bootstrap. Day-two schema changes are a migration job.

---

## StatefulSets

### 8. When do you use a StatefulSet instead of a Deployment?

When pods are **not** interchangeable. A StatefulSet gives each pod:

- a stable ordinal **name** (`postgres-0`)
- a stable **DNS name** via a headless Service
- **its own** PersistentVolumeClaim, from a `volumeClaimTemplate`
- ordered creation, deletion and updates

Databases, Kafka, Elasticsearch, etcd, ZooKeeper. Anything where a member has an
identity or its own data.

### 9. What does a StatefulSet *not* give you?

Replication, leader election, failover, consistency or backups. It provides
identity, ordering and storage; everything else lives inside the software.

Running PostgreSQL as a 3-replica StatefulSet gives you **three empty, unrelated
databases** — you can prove it in two commands. Real replication needs an
operator (CloudNativePG, Strimzi) or a managed service. This is the single most
common misconception in the area.

### 10. Why does a StatefulSet need a headless Service?

A normal ClusterIP Service hides which pod you reached — one virtual IP, load
balanced. A headless Service (`clusterIP: None`) has no virtual IP: DNS returns
pod IPs, and because the StatefulSet names it in `serviceName`, CoreDNS also
creates **one A record per pod**:

```
postgres-0.postgres-headless.notes-platform.svc.cluster.local
```

That name belongs to ordinal 0 forever. It is how members find each other.

**The failure to recognise:** a healthy StatefulSet whose per-pod names return
NXDOMAIN means `serviceName` is wrong, or the Service is not actually headless.

### 11. I deleted a StatefulSet and the PVCs are still there. Bug?

No — deliberate. PVCs created from a `volumeClaimTemplate` are given **no owner
reference** to the StatefulSet, so garbage collection never touches them.
Deleting a workload must not destroy data.

The same applies on scale-down: 3 → 1 leaves two PVCs. Recreate the StatefulSet
and the pods reattach to their original volumes, because the claim name is
derived from the ordinal.

Kubernetes 1.27+ adds `persistentVolumeClaimRetentionPolicy` to opt in to
deletion. For a database, leave it alone.

### 12. What does `podManagementPolicy: OrderedReady` mean, and when would you change it?

Pods are created `0,1,2…`, each waiting until the previous one is Running **and
Ready**; deletion and updates go in reverse. So a StatefulSet stuck at `0/3` with
one pending pod is not broken — pod 1 is never created while pod 0 is unready.

`Parallel` starts them all at once, which is right for members that do not
bootstrap from each other (a Redis cache, for example). It is **immutable after
creation**.

---

## Services and networking

### 13. What actually happens when a pod connects to a ClusterIP?

CoreDNS resolves the Service name to its ClusterIP — a **virtual** IP that no
process listens on and that appears on no interface. The client opens a
connection to it; the node's kernel has **kube-proxy**-installed rules that DNAT
the destination to one of the **ready** pod IPs from the EndpointSlice, and
un-NAT the reply.

There is no proxy process in the data path — it is packet rewriting in the
kernel. And balancing is **per connection**, not per request, which is why a
keep-alive client appears to be pinned to one pod.

### 14. A Service returns connection refused, but every pod is Running. Where do you look?

`kubectl get endpointslices -n <ns>` — first, before logs.

- **Empty endpoints** ⇒ the selector matches nothing, or no pod is Ready.
  Compare `svc -o jsonpath='{.spec.selector}'` with `pods --show-labels`.
- **Endpoints present, still refused** ⇒ wrong `targetPort`, or the app is bound
  to `127.0.0.1` instead of `0.0.0.0`.

To separate the two layers, connect straight to a pod IP. Works ⇒ the Service is
misconfigured. Fails ⇒ the application is.

**Kubernetes reports no error for an empty Service** — it is a legal state, and
that silence is why this is the most common failure people cannot find.

### 15. What is the difference between an Ingress and an Ingress controller?

The **Ingress** is a set of routing rules — an API object, and only data.
The **controller** is a running program that watches those objects and configures
a real proxy.

**Kubernetes ships no ingress implementation.** Create an Ingress on a cluster
with no controller and you get no error: the object exists, `ADDRESS` stays
empty, and nothing routes. **IngressClass** is the link between them, so one
cluster can run nginx and an ALB controller side by side.

### 16. Ingress returns 404. Then 502. Then 503. What do they each tell you?

| Code | Meaning | Look at |
|---|---|---|
| **404** | No rule matched this Host and path | The Ingress rules; the Host header you actually sent |
| **503** | The rule matched; the backend has **no ready endpoints** | Pod readiness, EndpointSlices |
| **502** | Endpoints exist; connecting or reading failed | `targetPort`, app logs, the bind address |

Three codes, three completely different investigations. Notice also that a 404
from *nginx* and a 404 from *your application* mean different things — read the
body.

### 17. Explain ClusterIP vs NodePort vs LoadBalancer.

A ladder, each rung including the one below:

- **ClusterIP** — internal virtual IP. The default and the right default.
- **NodePort** — plus a port (30000–32767) on **every** node, even nodes running
  none of the pods.
- **LoadBalancer** — plus an external address, **provisioned by the cloud
  controller manager**, not by Kubernetes.

In production you want exactly one LoadBalancer, in front of an ingress
controller, with all HTTP routing behind it as Ingress objects. Otherwise every
Service costs a billed load balancer, an IP, a DNS record and a certificate.

### 18. My LoadBalancer Service has been `<pending>` for ten minutes. What is wrong?

Probably nothing. `type: LoadBalancer` is a **request** to the cloud controller
manager, and Kubernetes creates no load balancer itself. On Kind, Minikube or
bare metal there is no cloud provider integration, so nobody answers — and there
is no error, because nothing failed.

Locally, install `cloud-provider-kind` or MetalLB and the same manifest gets an
address, unchanged. On EKS/GKE/AKS the provider's controller is already there.

### 19. Why does an Ingress work on Kind at all, if its controller's Service is `<pending>`?

Because the Kind-specific manifest also gives the controller pod
`hostPort: 80/443`, binding it directly to the node's network namespace, and the
cluster config maps the host's port 80 into the node container with
`extraPortMappings`. That combination is the entire path from browser to
controller.

`hostPort` is a development shortcut — it bypasses Services, allows one pod per
port per node, and is forbidden by `restricted` Pod Security Standards.

---

## Configuration and secrets

### 20. I edited a ConfigMap and nothing changed. Why?

If it is consumed as **environment variables**: the Linux process environment is
fixed at `exec()`. Nothing in Kubernetes can change a running process's
environment. Use `kubectl rollout restart`, which patches the pod template and
performs a normal rolling update.

If it is consumed as a **mounted volume**: the kubelet refreshes the files
(~60 s) — **unless** the mount uses `subPath`, which is resolved once at pod
start and never updated. Whether the app notices depends on whether it re-reads
the file.

The production answer is to make the change trigger the rollout: a
`checksum/config` annotation, or better, Kustomize's `configMapGenerator`, which
puts a content hash in the ConfigMap's **name** so rollbacks restore the old
config too.

### 21. Are Kubernetes Secrets encrypted?

**No, not by default.** They are base64-encoded, which is encoding for transport,
not encryption. Anyone who can `get` the Secret reads it with one more command.

What actually protects a Secret:

- **RBAC** — the real control. `get secrets` should be rare and audited.
- **Encryption at rest** — an `EncryptionConfiguration` on the API server, ideally
  KMS-backed, so etcd holds ciphertext.
- **tmpfs** — volume-mounted Secrets never touch the node's disk.
- **Not committing them** — External Secrets, Sealed Secrets, SOPS.

And the one people miss: **anyone who can `create pods` in a namespace can mount
any Secret in it.** That permission is equivalent to reading them.

### 22. Why prefer mounting a Secret as a file over an environment variable?

Environment variables leak in more ways: `/proc/<pid>/environ`, crash dumps,
child processes, and logging middleware that helpfully prints the environment.
A file in a tmpfs leaks in fewer, and can be re-read after rotation without a
restart.

This project uses environment variables because the PostgreSQL image requires
them. A service you write yourself should read a file.

### 23. How do you rotate a database password in Kubernetes?

**Order matters, and this catches people.** PostgreSQL reads `POSTGRES_PASSWORD`
only when it initialises an **empty** data directory. Once a volume persists,
changing the Secret and restarting the database does nothing.

The sequence is:

1. `ALTER USER … PASSWORD '…'` **in the database**
2. update the Secret
3. restart the clients

Get it backwards and you have healthy pods, a green dashboard, and
`password authentication failed` in every log line. The strongest answer is to
have no long-lived password at all — short-lived credentials from Vault or cloud
IAM database authentication.

---

## Probes and reliability

### 24. Readiness, liveness, startup — what is the difference?

| Probe | Question | On failure |
|---|---|---|
| **startup** | "Have you finished booting?" | Keep waiting; **suspends** the other two |
| **readiness** | "Should I send you traffic now?" | Removed from EndpointSlices. **Not restarted** |
| **liveness** | "Are you still working at all?" | The container is **restarted** |

Readiness controls traffic; liveness controls life. Readiness is checked forever,
not once — a pod that fails it later leaves the load balancer and rejoins when it
recovers, with no restart and no human.

### 25. What happens if you point the liveness probe at a database check?

You convert a recoverable dependency blip into an outage of your own making.

The database has a five-second problem. Every API pod's liveness probe fails, the
kubelet SIGKILLs every container (exit code **137**), they restart, fail again,
and CrashLoopBackOff's exponential backoff keeps them down long after the
database recovered.

With liveness on a dependency-free endpoint, the same event takes the pods out of
the EndpointSlice, leaves them `0/1 Running` with `RESTARTS 0`, and they rejoin
automatically. **That contrast is the answer.**

### 26. Why is `maxUnavailable: 0` meaningless without a readiness probe?

Because "available" then means "the container process started". The Deployment
controller removes an old pod as soon as a new one is Running, and the
EndpointSlice admits a pod that cannot serve — so users get 502s during every
deploy while the rollout reports success.

A readiness probe is what gives the word "available" a meaning the controller can
act on.

### 27. When would you use an init container instead of a startup probe?

They answer different questions. An **init container** asks *"is my dependency
ready?"*; a **startup probe** asks *"am I ready?"*. They compose: the init
container waits for PostgreSQL, then the startup probe gives the app its boot
budget.

An init container also runs to completion before the app container exists, so a
pod waiting on one shows `Init:0/1` — **not** `CrashLoopBackOff`. Its logs need
`kubectl logs <pod> -c <init-container>`.

### 28. A pod is `0/1 Running` with 0 restarts. What does that tell you?

The container process is alive and the readiness probe is failing, so the pod has
been removed from every Service's endpoints and is deliberately receiving no
traffic. Nothing is restarting it, because readiness failure is not a death
sentence.

`kubectl describe pod` gives the probe's exact status code. If the pod also has
climbing `RESTARTS`, look at `Exit Code`: 137 is SIGKILL, from a liveness probe
or an OOM kill — `Reason` distinguishes them.

---

## Scenario questions

### 29. Users report the app is down. Walk me through the first five minutes.

```bash
kubectl get pods -n notes-platform -o wide          # what state is everything in?
kubectl get endpointslices -n notes-platform        # does anything have backends?
kubectl get events -n notes-platform --sort-by=.lastTimestamp | tail -20
```

Then branch on what you saw:

- **All pods Ready, no endpoints** ⇒ a Service selector problem.
- **API pods `0/1`** ⇒ readiness failing ⇒ check the database first.
- **`postgres-0` Pending** ⇒ `describe pvc`, then `describe pod` — a storage or
  scheduling problem.
- **Everything healthy, users still failing** ⇒ the ingress layer. Check the
  status code: 404, 502 and 503 mean three different things.

State the *shape* of the failure before you start reading logs. Logs are for
confirming a hypothesis, not forming one.

### 30. You are asked to run PostgreSQL in Kubernetes for a production service. What do you say?

Ask why first — a managed database (RDS, Cloud SQL) takes backups, failover,
patching and point-in-time recovery off the team's plate, and that is usually the
right answer.

If it must run in-cluster:

- Use an **operator** (CloudNativePG, Zalando), not a hand-written StatefulSet.
  A StatefulSet gives identity and storage, not failover.
- Network storage via a CSI driver, `reclaimPolicy: Retain`,
  `allowVolumeExpansion: true`, sized for growth.
- **Backups to object storage, with a restore you have tested on a schedule.**
- A PodDisruptionBudget so `drain` cannot take the last member.
- Anti-affinity and topology spread across nodes and zones.
- Resource requests **and** limits; monitoring of disk usage, connections and
  replication lag.
- Credentials from a secret manager, never committed.

Being able to say what a StatefulSet does *not* give you is what separates a
useful answer from a rehearsed one.

### 31. What is the difference between this application and Project 01's, architecturally?

Project 01 held state **in the process**, so each replica had its own data and
scaling changed the answers. Here every replica reads one PostgreSQL database, so
the pod name varies and the data does not.

That is the definition of a stateless tier — and it is what makes replicas,
rolling updates and autoscaling safe. All the difficulty moved into the one
component that genuinely cannot be treated that way, which is exactly why
StatefulSets, PVCs and probes exist.

---

## Verify these answers yourself

Do not take any of this on trust. Every claim above is checkable:

```bash
# Base64 is not encryption
kubectl get secret postgres-secret -n notes-platform \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

# A StatefulSet is not replication
kubectl scale statefulset/postgres --replicas=3 -n notes-platform
for i in 0 1 2; do kubectl exec postgres-$i -n notes-platform -- \
  psql -U notes -d notes -tAc 'SELECT count(*) FROM notes'; done

# Readiness removes traffic without restarting
kubectl scale statefulset/postgres --replicas=0 -n notes-platform
sleep 20 && kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api

# The PVC outlives the workload
kubectl delete statefulset postgres -n notes-platform && kubectl get pvc -n notes-platform

# LoadBalancer is a request, not a creation
kubectl get svc notes-web-lb -n notes-platform
```

The [failure labs](../failure-labs/labs.md) turn every one of these into a full
break → diagnose → fix exercise.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Troubleshooting](../troubleshooting/common-errors.md)** | [Project 02](../README.md) | **[Project 03 →](../../docs/ROADMAP.md#project-03--url-shortener)** ▶ |
