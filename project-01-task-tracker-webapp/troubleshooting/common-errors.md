# Common Errors — Project 01

Every error you're likely to hit, with the diagnosis path. Self-contained: you never need another project's docs to
debug this one.

**The universal first three commands:**

```bash
kubectl get pods -n task-tracker -o wide
kubectl describe pod <pod> -n task-tracker        # read the Events section at the bottom
kubectl get events -n task-tracker --sort-by=.lastTimestamp
```

---

## Pod states

| Status | Meaning | First command | Common causes in this project |
|---|---|---|---|
| `Pending` | Accepted but not scheduled | `describe pod` → Events | Not enough CPU/memory on the single Kind node — raise Docker's resource limits |
| `ContainerCreating` | Scheduled, container starting | `describe pod` | Image pulling; normally lasts seconds |
| `ImagePullBackOff` / `ErrImagePull` | Kubelet can't get the image | `describe pod` → Events | **Forgot `kind load docker-image`**; wrong tag; `imagePullPolicy: Always` instead of `IfNotPresent` |
| `CrashLoopBackOff` | Starts then exits, repeatedly | `logs --previous` | App raises on startup; bad `command` override |
| `CreateContainerConfigError` | Referenced config doesn't exist | `describe pod` | Missing ConfigMap/Secret **object or key** |
| `Running` but `0/1 READY` | Readiness probe failing | `describe pod` + `logs` | Wrong probe path/port; app genuinely not ready |
| `Terminating` (stuck) | Shutdown not completing | `describe pod` | App ignoring SIGTERM; long `terminationGracePeriodSeconds` |
| `OOMKilled` | Exceeded memory limit | `describe pod` → Last State | Not applicable here (no limits set) — see Project 05 |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Clean exit |
| 1 | Application error — read the logs |
| 137 | SIGKILL — OOMKilled or a failed liveness probe |
| 143 | SIGTERM — normal shutdown during a rollout |

---

## Networking

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| `502 — cannot reach the task API at …` | `kubectl get endpointslices -n task-tracker` | Backend unreachable. **The error message names the URL it tried** | Follow the URL: does the Service exist? Does it have endpoints? |
| Empty endpoints (`<unset>`) | `kubectl describe svc task-api -n task-tracker` | Selector doesn't match Pod labels, **or** no Pod is Ready | Align `spec.selector` with the Pod template labels |
| Works via `port-forward` to the Pod, not via the Service | `kubectl describe svc` | `targetPort` doesn't match the container port | Fix `targetPort` — prefer the port **name** |
| `nslookup` fails inside a Pod | `kubectl exec … -- cat /etc/resolv.conf` | Wrong FQDN or namespace; CoreDNS unhealthy | Use `task-api.task-tracker.svc.cluster.local` |
| `localhost:8080` refused | — | The `port-forward` process stopped (it's foreground) | Restart it |
| Cannot `ping` the ClusterIP | — | **Expected.** A ClusterIP is an iptables rule, not a host | Test with `curl`, not `ping` |

---

## Configuration

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| ConfigMap edited, app unchanged | `kubectl exec … -- env` | **Env vars are frozen at process start** | `kubectl rollout restart deployment/<name> -n task-tracker` |
| `CreateContainerConfigError` | `describe pod` | Missing key or object | `describe` names the exact key |
| `cannot unmarshal number into ... type string` | — | Unquoted number/bool in ConfigMap `data` | Quote every value: `PORT: "8080"` |
| `{"error":"invalid or missing X-API-Token"}` | `kubectl exec … -- env \| grep API_TOKEN` | The two tiers hold different tokens | Re-apply both Deployments |
| Secret value not visible in `describe` | — | **Expected** — `describe` shows byte counts | `kubectl get secret … -o jsonpath='{.data.KEY}' \| base64 -d` |

---

## Rollouts

| Symptom | Command | Cause | Fix |
|---|---|---|---|
| `rollout status` hangs | `kubectl get pods -n task-tracker` | New Pods never become Ready | `describe` the new Pod; the old ones are still serving |
| `kubectl set image` did nothing (ReplicaSet) | `kubectl get pods -o jsonpath=…` | ReplicaSets reconcile **count**, not content | Use a Deployment |
| Changes reverted after `apply` | — | An imperative `scale`/`set env` was overwritten by the declarative file | Edit the manifest, not the live object |
| `field is immutable` | `kubectl describe deployment` | You tried to change `spec.selector` | Delete and recreate the Deployment |

---

## Application behaviour that is not a bug

| Observation | Why |
|---|---|
| Tasks appear and disappear on refresh | Each API Pod holds its **own** in-memory list. Three replicas = three task lists. This is the motivation for Project 02. |
| Tasks lost after a rollout | Same — new Pods start with the seed data |
| "served by pod" changes on refresh | kube-proxy load-balancing across the three backend Pods. Working as intended. |

---

## Environment

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl` targets the wrong cluster | Stale context | `kubectl config use-context kind-kubernetes-lab` |
| "No resources found" but the app is running | You omitted `-n task-tracker` | Add `-n`, or `kubectl config set-context --current --namespace=task-tracker` |
| `kind create` fails immediately | Docker not running | `docker ps` |
| Pods `Pending` on a fresh cluster | Docker Desktop/WSL resource limits too low | Increase CPU/memory allocation |


---

## Official troubleshooting references

*(All links verified 2026-08-09.)*

| Reference | What it covers |
|---|---|
| [Debug running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/) | `describe`, `logs`, `exec`, ephemeral debug containers |
| [Debug applications](https://kubernetes.io/docs/tasks/debug/debug-application/) | The official decision tree for a Pod that won't work |
| [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) | What each phase and container state actually means |
| [Images](https://kubernetes.io/docs/concepts/containers/images/) | `ImagePullBackOff`, pull policy, private registries |
| [Service](https://kubernetes.io/docs/concepts/services-networking/service/) · [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) | Empty endpoints and `targetPort` mismatches |
| [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) | Name resolution failures |
| [kubectl reference](https://kubernetes.io/docs/reference/kubectl/) | Full flag list for every command above |
