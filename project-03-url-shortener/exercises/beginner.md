# Beginner Exercises — Project 03

[⬅ Project 03](../README.md) · Solutions: [`solutions/beginner.md`](solutions/beginner.md)

Try each one before opening the solution. Every answer is verifiable with a command.

---

## Exercise 1 — Read a pod's DNS configuration

Print `/etc/resolv.conf` from a `shortener-api` pod and explain every line, including why `ec2.internal` is there.

**Verify:** you can say which of `postgres`, `postgres.url-shortener`, `analytics-collector` and
`analytics-collector.analytics` resolve from this pod, and why — then prove it.

---

## Exercise 2 — Find the EBS volumes

For each of the three PVCs, find the EBS volume ID, its availability zone, and the node its pod is running on.

**Verify:** every pod's node is in the same AZ as its volume.

---

## Exercise 3 — Which Redis member answered?

Using only `curl` and the ALB, show that reads reach both Redis members while writes always reach `redis-0`.

**Verify:** `/api/info` shows `redis_read.role` alternating between `master` and `slave`, and `redis_write.role`
always `master`.

---

## Exercise 4 — Decode a Secret

Read the Redis password from the cluster, and explain which RBAC permission made that possible.

**Verify:** `kubectl auth can-i get secrets -n url-shortener` for you and for the namespace's default ServiceAccount.

---

## Exercise 5 — See the ALB's targets

List the ALB target groups for this project and their targets, and match every target to a pod.

**Verify:** the target IDs equal pod IPs from `kubectl get pods -o wide`.

---

## Exercise 6 — Count the objects

List every object this project created — in both namespaces, the cluster-scoped ones, and the AWS resources the
controllers created.

**Verify:** your list includes the StorageClass, three PVs, the generated ConfigMaps, the TargetGroupBindings, one
ALB and three EBS volumes.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Failure labs](../failure-labs/labs.md)** | [Project 03](../README.md) | **[Intermediate](intermediate.md)** ▶ |
