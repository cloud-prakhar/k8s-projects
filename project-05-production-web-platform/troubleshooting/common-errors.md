# Common Errors — Project XX

Every error you are likely to hit, with the diagnosis path. Self-contained: you should never need another project's
docs to debug this one.

---

## Pod states

| Status | Meaning | First command | Common causes |
|---|---|---|---|
| `Pending` | Not scheduled yet | `kubectl describe pod` → Events | Insufficient CPU/memory, no matching node (selector/affinity/taint), unbound PVC |
| `ContainerCreating` | Scheduled, container not up | `describe` | Image pulling, volume attach failing, Secret/ConfigMap missing |
| `ImagePullBackOff` / `ErrImagePull` | Kubelet can't get the image | `describe` → Events | Wrong name/tag, private registry without `imagePullSecrets`, image not `kind load`ed |
| `CrashLoopBackOff` | Starts then exits repeatedly | `logs --previous` | App crash, bad config, missing dependency, wrong command |
| `CreateContainerConfigError` | Config referenced doesn't exist | `describe` | Missing ConfigMap/Secret **key** or object |
| `OOMKilled` | Exceeded its memory limit | `describe` → Last State | Limit too low, or a real leak |
| `Running` but `0/1 READY` | Readiness probe failing | `describe` + `logs` | Wrong probe path/port, too-short `initialDelaySeconds`, app genuinely not ready |
| `Terminating` (stuck) | Graceful shutdown not completing | `describe` | App ignores SIGTERM, finalizer, long `terminationGracePeriodSeconds` |
| `Evicted` | Node under pressure | `describe node` | Disk/memory pressure, BestEffort QoS |

---

## Networking

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| Service refuses connections | `kubectl get endpointslices -n <ns>` | Empty endpoints → selector doesn't match pod labels, or no pod is Ready | Align `spec.selector` with the pod template labels |
| Reachable via `port-forward` to the Pod but not via the Service | `kubectl describe svc` | `targetPort` doesn't match the container's port | Fix `targetPort` (prefer the port **name**) |
| Ingress returns 404 | `kubectl describe ingress` | Host/path doesn't match, or no `ingressClassName` | Fix the rule; confirm `kubectl get ingressclass` |
| Ingress returns 503 | controller logs | Backend Service has no ready endpoints | Fix the pods first |
| Ingress returns 502 | controller logs | Reached a pod but the connection failed — wrong port, or app crashing | Check `targetPort` and app logs |
| Nothing on `localhost:80` | `docker port <kind-node>` | Cluster created without `extraPortMappings` | Recreate with `clusters/kind-ingress.yaml` |
| DNS lookup fails | `kubectl exec … -- nslookup <svc>` | Wrong namespace/FQDN, CoreDNS down, NetworkPolicy blocking egress :53 | Use the FQDN; allow DNS egress |
| NetworkPolicy has no effect | `kubectl get pods -n kube-system` | Kind's default CNI doesn't enforce policies | Install Calico or Cilium |

---

## Storage

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| PVC stuck `Pending` | `kubectl describe pvc` | No default StorageClass, no matching PV, or size/access mode unsatisfiable | Set `storageClassName`; check `kubectl get sc` |
| Pod stuck `ContainerCreating` on a volume | `describe pod` | Volume can't attach — RWO already bound elsewhere, or wrong AZ (cloud) | One writer per RWO volume |
| Data lost after restart | — | `emptyDir` or no volume at all | Use a PVC |
| PV stuck `Released` | `kubectl get pv` | `Retain` reclaim policy | Delete the PV, or clear `claimRef` to reuse it |

---

## RBAC and security

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| `Error from server (Forbidden)` | `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa>` | Role/binding missing the verb or apiGroup | Add it — narrowly |
| Pod rejected on create | `kubectl get events` | Pod Security Standards violation | Fix `securityContext` to satisfy the namespace's level |
| `CreateContainerError: unable to find user` | `describe` | `runAsNonRoot` with a root-only image | Use a non-root image or set `runAsUser` |
| App crashes writing to disk | `logs` | `readOnlyRootFilesystem: true` | Mount an `emptyDir` at the writable path |
| ReplicaSet `FailedCreate`, no pods | `kubectl describe rs` | ResourceQuota exceeded | Raise the quota or lower requests — note the error is on the **ReplicaSet**, not a Pod |

---

## The universal first three commands

```bash
kubectl get pods -n <ns> -o wide
kubectl describe pod <pod> -n <ns>          # read the Events section at the bottom
kubectl get events -n <ns> --sort-by=.lastTimestamp
```
