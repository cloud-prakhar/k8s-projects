# Interview Questions — Project XX

Grouped by resource, each with a model answer. Aim for ≥15 per project.

---

## Workloads

> 🎯 **What's the difference between a Deployment and a ReplicaSet? When would you create a ReplicaSet directly?**

**Answer:** A ReplicaSet keeps N identical pods running — that's all it does. A Deployment manages ReplicaSets to give
you versioned rollouts: on a template change it creates a *new* ReplicaSet and shifts replicas from old to new
according to `maxSurge`/`maxUnavailable`, keeping old ReplicaSets around for rollback. You essentially never create a
ReplicaSet directly; you'd lose rolling updates, rollback, and revision history.

**Follow-up:** what does `kubectl rollout undo` actually do? *(Scales the previous ReplicaSet back up and the current
one down — the old pod template was never deleted.)*

---

> 🎯 **A Pod is `Running` but the Service returns "connection refused". Walk me through your debugging.**

**Answer:** 1) `kubectl get endpointslices` — empty means the Service selector doesn't match the pod labels, or no
pod is Ready. 2) If endpoints exist, compare `targetPort` with the container's actual listening port. 3)
`port-forward` straight to the Pod: if that works, the problem is the Service; if not, it's the app. 4) Check the app
isn't bound to `127.0.0.1` instead of `0.0.0.0` — a classic in containers.

---

## Networking

> 🎯 **Why doesn't `type: LoadBalancer` get an external IP on my local cluster?**

**Answer:** `type: LoadBalancer` is a request to a cloud controller manager to provision an external LB. Kind and
bare-metal clusters have no such controller, so the Service stays `<pending>` — which is correct behaviour, not a bug.
Locally you'd install Cloud Provider KIND or MetalLB, or use the NodePort the Service already has.

---

## Configuration

> 🎯 **Are Kubernetes Secrets encrypted?**

**Answer:** By default, no. They're base64-**encoded** in etcd — encoding, not encryption; anyone with `get secret`
or etcd access can read them. Production needs encryption at rest (`EncryptionConfiguration`), tight RBAC, and ideally
an external manager (External Secrets Operator + AWS Secrets Manager / Vault / Key Vault) so the secret never lives
in Git.

---

## Storage · Scaling · Reliability · Security · Observability

<!-- Same format. Every answer states the mechanism, not just the definition, and ends with a follow-up. -->
