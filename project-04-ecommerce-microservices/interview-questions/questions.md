# Interview Questions — Project 04

[⬅ Project 04](../README.md)

Grouped by resource, with model answers. Every answer can be checked on your own cluster with the commands in this
project.

---

## Services and service discovery

### 1. Five services call each other by name. What actually makes `http://catalog:8080` work?

A **Service** named `catalog`. CoreDNS publishes `catalog.ecommerce.svc.cluster.local` → the Service's ClusterIP;
the pod's resolv.conf search list turns the short name into that FQDN; kube-proxy on the client's node DNATs the
ClusterIP to a **ready** pod IP from the Service's EndpointSlices. A Deployment's name registers nothing — which is
why stage 03's twelve Running pods could not find each other.

### 2. DNS resolves, but connections fail. What are the candidates, and how do you tell them apart?

| Symptom | Cause | Check |
|---|---|---|
| Connection **refused**, EndpointSlice **empty** | Selector matches no ready pod | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` |
| Refused, endpoints **present** | Wrong `targetPort` | Compare with the container's ports |
| **Timeout**, endpoints present | A **NetworkPolicy** dropping the packet | `kubectl get networkpolicy`; the agent's policy logs |

The refused/timeout distinction is the fastest discriminator: policies drop, they never refuse.

### 3. Is a Service a security boundary?

No. It is discovery and load balancing. `Service/payment` makes payment reachable **by every pod in the cluster**;
there is no field that restricts callers. This project proves it by authorising a payment from a throwaway pod,
and only a NetworkPolicy stops it.

### 4. Why do all Services in this project use `port == targetPort`?

Because the Amazon VPC CNI network policy engine requires a Service's port to equal the container port (and named
ports to share names). A conventional `80 → 8080` mapping makes policies enforce against the wrong port. It is a
platform-specific constraint worth knowing exists — on other CNIs the mapping is harmless.

---

## Configuration

### 5. What belongs in a shared ConfigMap, and what does not?

Values every consumer must agree on (hostnames, timeouts, service URLs). **Owned** config — values that are
different and correct per service, like `POSTGRES_DB=catalog` vs `orders` — stays in each Deployment. Putting it
in the shared ConfigMap would force both services onto one database with no error anywhere. Credentials go in
Secrets.

### 6. `envFrom` vs `configMapKeyRef` — when does the difference bite?

`envFrom` injects whatever keys exist: rename a key and it silently disappears, the app falls back to a default
(stage 05 Break 1 — checkout calling `127.0.0.1`). `configMapKeyRef` names the key, so a missing one fails the
container at start with `CreateContainerConfigError`. `envFrom` also gives every pod every key, including ones it
should not see.

### 7. I edited the shared ConfigMap and nothing changed. Why, and what is the durable fix?

Env vars are read at container start; the edit changed etcd only. Pods pick it up as they are replaced — at random
times — so the fleet drifts. Fix: immutable, content-hashed ConfigMaps (a Kustomize `configMapGenerator`), so a
change is a new name, a pod-template change, and a revisioned rollout that `rollout undo` can reverse.

---

## Ingress

### 8. Why one Ingress rather than a LoadBalancer Service per microservice?

On EKS each `type: LoadBalancer` Service is its own NLB — its own hourly charge and hostname — and L4 cannot route
by path. One Ingress becomes one ALB with path and host rules, one address, one TLS termination point.

### 9. Explain host-based vs path-based routing, and what happens with a typo in the host.

Path rules match the URL path; host rules match the `Host` header. A rule without `host:` matches any host. A typo
in a host rule does not error — requests simply do not match it and fall through to a hostless rule, taking a
different route silently.

### 10. What is the difference between ALB 404, 502 and 503?

404 (plain HTML): no listener rule matched. 502: a target was tried and failed (wrong port, refused). 503: no
healthy targets. Each backend has its own target group, so one service's 503 does not affect the others.

### 11. The Ingress has no rule for `payment`. Is payment protected?

From the **internet**, yes. From **inside the cluster**, not at all — Ingress controls north-south traffic only.
East-west needs NetworkPolicy.

---

## Probes and resilience

### 12. What should `order`'s readiness probe check?

PostgreSQL — its hard dependency — and **not** `payment`. If readiness checked payment, a payment outage would
remove every order pod from the ALB, breaking the order list and the admin host as well as checkout: a cascading
readiness failure.

### 13. Nothing is down, every pod passes every probe, and the site is slow. How?

A slow dependency. With `PAYMENT_LATENCY_MS=8000` and no bounded timeout, every checkout holds an `order` thread
for 8 s; under load the thread pool fills, `/healthz` queues behind real requests, readiness times out, and pods
leave the ALB — so even endpoints that never touch payment return 503. Fixes: timeouts sized down the call chain,
circuit breakers, bulkheads, and capacity (Project 05).

---

## NetworkPolicy

### 14. I applied a default-deny and traffic still flows. What's wrong?

The CNI is not enforcing policies. NetworkPolicy is accepted by every API server and enforced only by a CNI that
implements it. On EKS: the VPC CNI needs `enableNetworkPolicy: "true"` — check for the `aws-eks-nodeagent`
container in `aws-node` and the `policyendpoints.networking.k8s.aws` CRD. On default Kind, kindnet ignores them.

### 15. After a default-deny, every service reports "Name or service not known". Why?

Egress deny blocks DNS. Allow UDP **and** TCP 53 to CoreDNS pods in kube-system — with the `namespaceSelector` and
`podSelector` in the **same** `to` item (AND). This is the most common NetworkPolicy mistake.

### 16. `order → payment` fails, yet `allow-order-to-payment` exists. What else is needed?

Egress on the source. A connection needs egress permitted on `order` **and** ingress permitted on `payment` once
both are isolated by the default-deny. Replies are allowed automatically by connection tracking.

### 17. What is the difference between these two rules?

```yaml
- from: [ { namespaceSelector: {…}, podSelector: {…} } ]   # A
- from: [ { namespaceSelector: {…} }, { podSelector: {…} } ]   # B
```

A is AND — matching pods *in* matching namespaces. B is OR — any pod in the matching namespaces, **or** matching
pods in the policy's own namespace. One dash, a very different rule.

### 18. Does NetworkPolicy authenticate the caller?

No. It authorises by labels and IPs. Anyone who can create a pod labelled `app.kubernetes.io/name=order` in the
namespace passes `allow-order-to-payment`. RBAC on pod creation and admission policy make labels trustworthy;
mTLS (a service mesh) gives real workload identity.

### 19. A denied connection — refused or timeout? Why does it matter?

Timeout. The eBPF filter drops the packet with no RST or ICMP. If you expect "refused" you will look in the wrong
place. Resolves-but-times-out between pods is the signature of a policy denial.

### 20. What does "standard" vs "strict" enforcement mode mean on the VPC CNI?

In standard mode a new pod starts **allow-all** until its policies are programmed — a brief window. Strict mode
(`NETWORK_POLICY_ENFORCING_MODE=strict`) starts pods **deny-all**, so every flow needs an explicit policy from the
first packet, including DNS.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Exercises — Advanced](../exercises/advanced.md)** | [Project 04](../README.md) | **[Project 05](../../project-05-production-web-platform/README.md)** ▶ |
