# Interview Questions — Project 03

[⬅ Project 03](../README.md)

Grouped by resource, with model answers. Every answer can be checked on your own EKS cluster with the commands in
this project.

---

## Services and DNS

### 1. A pod logs `could not resolve host 'postgres'`, but PostgreSQL is running. Walk me through it.

A running pod has no DNS name. Names come from **Services**: CoreDNS publishes `<svc>.<ns>.svc.cluster.local` for
each Service. So in order:

1. `kubectl get svc postgres -n <client-namespace>` — does a Service with **that exact name** exist, in the
   **client's** namespace (short names only complete within it)?
2. If the client uses an FQDN, is the namespace in it right?
3. `kubectl get endpointslices -l kubernetes.io/service-name=postgres` — resolution failing is DNS; resolution
   working but connections failing is endpoints or ports.
4. Resolve with the application's own resolver: `kubectl exec <pod> -- python -c "import socket;
   print(socket.gethostbyname('postgres'))"`. busybox `nslookup` treats dotted names differently and misleads.
5. Only then suspect CoreDNS itself: `kubectl get pods -n kube-system -l k8s-app=kube-dns`.

### 2. What does a ClusterIP Service actually consist of?

Three things, none of them a process: an **A record** in CoreDNS pointing at a virtual IP; the **virtual IP**
itself, which nothing listens on; and **kube-proxy rules** on every node that DNAT connections to that IP onto a
ready pod IP taken from the Service's EndpointSlices. Load balancing is per **connection**, chosen when it opens —
which is why a pooled client can stick to one pod forever.

### 3. Explain `ndots:5` and the search list. What does it cost?

`/etc/resolv.conf` in a pod lists search suffixes starting with its own namespace (`url-shortener.svc.cluster.local
svc.cluster.local cluster.local`, plus `ec2.internal` on EKS). With `ndots:5`, any name with fewer than five dots is
tried with every suffix **before** being tried as typed. That makes `postgres` work — and it means
`api.stripe.com` costs four NXDOMAIN lookups before the real one. At scale that is real CoreDNS load and latency.
Mitigations: a trailing dot (`api.stripe.com.`), `dnsConfig.options ndots: "2"` on pods that mostly call external
names, NodeLocal DNSCache, and scaling CoreDNS.

### 4. What is an ExternalName Service, and what are its limits?

A Service with no selector, no ClusterIP and no endpoints — CoreDNS answers its name with a **CNAME** to
`spec.externalName`. It gives a namespace-local alias for something you do not control: another namespace, an RDS
endpoint, a SaaS host. Re-pointing it needs no application change and no rollout.

Limits: it does **not** remap ports (the client's port is used against the target); it does **not** rewrite the
HTTP `Host` header or TLS SNI, so HTTPS certificates must match the alias the client dials — which usually makes it a
poor fit for HTTPS APIs and a good fit for TCP protocols like PostgreSQL and Redis; the target must be a DNS name,
never an IP; and there is no health checking.

### 5. When do you need a headless Service?

When clients must address **individual pods** rather than "any pod": replication (`replicaof
redis-0.redis-headless…`), clients that do their own load balancing or member discovery, and StatefulSets, which
require one as their governing Service. `clusterIP: None` makes CoreDNS return all ready pod IPs for the Service
name, and — for pods whose `hostname`/`subdomain` match, as StatefulSet pods do — an A record **per pod**.

### 6. Why did half of our Redis writes fail after we added a replica?

The application wrote through a ClusterIP Service whose selector matched both the primary and the replica. Each new
connection was DNAT'd to either pod; writes that reached the replica got `READONLY You can't write against a read
only replica`. The fix is to address writes to the primary **by a stable per-pod name**
(`redis-0.redis-headless…`) while reads keep using the ClusterIP. In production the primary's identity should come
from Sentinel, an operator, or a managed endpoint, because ordinal 0 is not always the primary after a failover.

---

## Configuration

### 7. I edited a ConfigMap and nothing happened. A week later half my pods behaved differently. Why?

Environment variables from a ConfigMap are read **once, at container start**. The edit changed etcd and nothing
else. A week later some pods restarted — node rotation, eviction, a crash — and those pods read the new values;
the others kept the old ones. Nothing rolled out, so there was no readiness gate, no revision and nothing for
`rollout undo` to revert. Mounted files update eventually, except `subPath` mounts, which never do.

### 8. How do you make configuration changes safe?

Make config **immutable and versioned**, and make a change a **rollout**. `immutable: true` rejects edits; a new
version is a new object (`app-config-v2` or a content hash); changing the workload's reference edits the pod
template, which rolls every pod with readiness gating and a revision. Because old versions still exist unchanged,
`rollout undo` restores the old config as well as the old image. Kustomize's `configMapGenerator` automates
naming, immutability and reference rewriting; Helm charts often use a `checksum/config` annotation instead.

### 9. What does a `checksum/config` annotation do?

Nothing to Kubernetes — it is a string on the pod template. Its value is a hash of a ConfigMap's content, so when
the content changes the hash changes, the **template** changes, and the controller rolls the pods. It exists because
nothing else links a ConfigMap edit to a workload.

### 10. How do you give Redis a password from a Secret without leaking it?

Not in the ConfigMap, and not as `--requirepass $(REDIS_PASSWORD)` — Kubernetes expands that into the process
arguments, visible in `ps`. Render the config at start-up: copy the ConfigMap file into a `medium: Memory` emptyDir,
append `requirepass` from an env var sourced from the Secret, and `exec redis-server` so Redis is PID 1 and receives
SIGTERM. Better still in production: a managed Redis with IAM authentication, or a secret delivered by the Secrets
Store CSI driver.

---

## Storage on EKS

### 11. A PVC is `Pending` on a brand-new EKS cluster. What do you check?

`kubectl describe pvc` — the reason is only there. On EKS, in order of likelihood:

1. **No pod yet and the class is `WaitForFirstConsumer`** — correct, not a fault.
2. **No `storageClassName` and no default class** — EKS creates `gp2` without the default annotation:
   `no storage class is set`.
3. **The EBS CSI driver add-on is missing** (`kubectl get csidriver ebs.csi.aws.com`) or **has no IAM permissions**
   (`UnauthorizedOperation` in events / provisioner logs).
4. An access mode EBS cannot provide (`ReadWriteMany`).

### 12. Why `WaitForFirstConsumer` for EBS?

An EBS volume exists in **one** availability zone and can only attach to instances there. `Immediate` binding
creates the volume before the scheduler picks a node — possibly in an AZ where the pod can never be scheduled.
`WaitForFirstConsumer` lets the scheduler choose first; the CSI driver then creates the volume in that node's AZ and
records it in the PV's node affinity.

### 13. What does `ReadWriteOnce` actually guarantee?

One **node** may mount the volume read-write — not one pod. Two pods on the same node can both mount an RWO volume;
two pods on different nodes get `Multi-Attach error`. If you need one pod, use `ReadWriteOncePod`. This project's
two-replica Redis Deployment landed both pods on the single node in the volume's AZ, and they silently diverged.

### 14. What happens to a StatefulSet's PVCs when the StatefulSet is deleted or scaled down?

They are kept. `volumeClaimTemplates` PVCs are not owned by the StatefulSet; recreating it reattaches each ordinal to
its old claim with data intact. `persistentVolumeClaimRetentionPolicy` can opt into deletion on scale-down or
delete; the default `Retain` is right for data. They **are** deleted with the namespace — and with
`reclaimPolicy: Delete` so are the EBS volumes.

### 15. An AZ is impaired. What happens to an in-cluster PostgreSQL on EBS?

If its node is in that AZ, the pod is lost and cannot be rescheduled anywhere else: the PV's node affinity pins it to
the volume's AZ, so it stays `Pending` with a volume node-affinity conflict until the AZ recovers. That is the
argument for RDS Multi-AZ or a replicated operator with members in several AZs.

---

## StatefulSets

### 16. What does a StatefulSet give you, and what does it not?

It gives **stable identity** (ordinal names), **stable network identity** (per-pod DNS via the headless Service),
**stable per-pod storage** (claim templates), and **ordered** creation, deletion and updates. It does **not** give
replication, leader election, failover or backups. Replication in this project is Redis's own `replicaof`; nothing
promotes the replica if the primary dies.

### 17. Why might a StatefulSet's pods run fine while their per-pod names return NXDOMAIN?

`serviceName` names a Service that does not exist or is not headless. Per-pod records are published only under the
headless Service named there. Nothing validates the field — it is a string.

---

## Ingress on EKS

### 18. How does an Ingress become an ALB?

The AWS Load Balancer Controller watches Ingresses whose `ingressClassName` is `alb`. It calls the ELBv2 and EC2
APIs — using an IAM role delivered by Pod Identity or IRSA — to create the ALB in subnets tagged for load balancers,
a listener, rules for each path, a target group per backend Service and security groups. With `target-type: ip` it
reads the Services' EndpointSlices and registers **pod IPs** directly (possible because the VPC CNI gives pods VPC
addresses). It writes the ALB hostname into the Ingress status and adds a finalizer so deletion waits for the ALB to
be removed.

### 19. What happens if you delete the controller before the Ingress?

The Ingress's finalizer is never cleared, so deleting it — or its namespace — hangs in `Terminating`. Removing the
finalizer by hand lets the object go but leaves the ALB, target groups and security groups in AWS, still billing,
and can block `eksctl delete cluster` on the VPC. Always delete Ingresses and `LoadBalancer` Services first.

### 20. The ALB returns 503, but all pods are Running and Ready. Why?

The ALB health-checks targets **itself**. Ready pods can still be `unhealthy` in the target group: a wrong
`healthcheck-path`, a security group blocking the ALB from the pods, or a port mismatch. `aws elbv2
describe-target-health` shows the state and reason. Conversely, a 502 means a target was tried and failed.

### 21. What is an ALB pod readiness gate for?

Without it, a new pod becomes Ready when its kubelet probe passes — before the ALB has registered it and seen it
healthy — so a rolling update can remove old pods while the ALB has no healthy new ones. With the namespace label
`elbv2.k8s.aws/pod-readiness-gate-inject: enabled`, the controller injects a readiness gate and only sets it True when
the target is healthy, so rollouts wait for the load balancer. It does not solve the *termination* side; that needs
`preStop` and grace periods.

---

## Probes and init containers

### 22. Should readiness check the cache?

Only if the service genuinely cannot work without it. Here Redis is optional — redirects fall back to PostgreSQL —
so readiness checks PostgreSQL only. If readiness checked Redis, a Redis restart would pull every API pod out of the
load balancer, turning a degraded service into an outage. Liveness should check neither.

### 23. Does moving migrations into an init container prevent concurrent migrations?

No. Init containers run **per pod**; two replicas start two migrators at once. It makes "schema current" a
precondition of starting and turns a failed migration into a visible `Init:Error`, but concurrency still needs a lock
(this project uses a PostgreSQL advisory lock) — or a single Job run before the rollout.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Exercises — Advanced](../exercises/advanced.md)** | [Project 03](../README.md) | **[Project 04 →](../../docs/ROADMAP.md#project-04--e-commerce-microservices)** ▶ |
