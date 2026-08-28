# Common Errors — Project 02

[⬅ Project 02](../README.md)

Symptom → investigate → root cause → fix. For deliberate breakage exercises see
[`failure-labs/labs.md`](../failure-labs/labs.md).

**The universal first three commands:**

```bash
kubectl get pods -n notes-platform -o wide
kubectl describe pod <pod> -n notes-platform        # the Events at the bottom are the answer
kubectl get events -n notes-platform --sort-by=.lastTimestamp | tail -20
```

---

## Pod states

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `Pending` | `describe pod` → Events | Unschedulable, or an unbound PVC | See **Storage** below; check node capacity |
| `Init:0/1` | `logs <pod> -c wait-for-postgres` | The database is not reachable yet | Usually correct — it is waiting. If it never ends, check `POSTGRES_HOST` |
| `ContainerCreating` (stuck) | `describe pod` → Events | A volume that cannot be attached or mounted | Multi-Attach ⇒ two pods want one RWO volume; wrong `hostPath` type |
| `ImagePullBackOff` | `describe pod` | The image was not `kind load`ed, or the tag is wrong | `kind load docker-image notes-api:1.0.0 --name kubernetes-lab` |
| `CrashLoopBackOff` | `logs <pod> --previous` | The app exits at start-up, **or** a liveness probe is killing it | Read the logs; check `Exit Code` in `describe` |
| `CreateContainerConfigError` | `describe pod` | A referenced ConfigMap/Secret **object or key** is missing | Apply the ConfigMap/Secret before the workload |
| `0/1 Running` | `describe pod` → readiness events | The readiness probe is failing | For `notes-api`, check the database first |
| `Terminating` (stuck) | `describe pod`, `get pod -o yaml \| grep finalizers` | A finalizer, or a long grace period | Wait; then investigate the finalizer |
| `RESTARTS` climbing | `describe pod` → `Exit Code`, `Last State` | Liveness probe, or OOM | See exit codes below |

### Exit codes

| Code | Means | Do |
|---|---|---|
| `0` | Clean exit | For a long-running container, the command is probably wrong |
| `1` | Application error | `kubectl logs --previous` |
| `137` | `128+9` SIGKILL — liveness probe or OOM | Check `Reason: OOMKilled` to tell them apart |
| `143` | `128+15` SIGTERM — normal shutdown | Nothing |

---

## Storage

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| PVC `Pending`, **no pod yet** | `describe pvc` | `WaitForFirstConsumer` — **this is correct** | Create the pod |
| PVC `Pending`, **pod exists** | `describe pvc` → Events | No such StorageClass, or no default class | `kubectl get storageclass` |
| PVC `Pending` with `ProvisioningFailed` | `describe pvc` | An access mode the storage cannot do (`ReadWriteMany` on local disk) | Ask for what the class supports |
| Pod `Pending`: `unbound immediate PersistentVolumeClaims` | `describe pvc` | The pod's error points at the PVC; the PVC has the real cause | Fix the PVC |
| `Multi-Attach error for volume` | `get pods -o wide` | Two pods on different nodes want one RWO volume | One replica, `Recreate`, or a StatefulSet |
| `lock file "postmaster.pid" already exists` | `logs`, `get pods` | Two Postgres pods sharing one data directory | Scale to 1; use a StatefulSet |
| Postgres: `initdb: directory exists but is not empty` | `describe pod` | `PGDATA` is the mount point instead of a subdirectory | `PGDATA=/var/lib/postgresql/data/pgdata` |
| Data gone after a pod restart | `get deploy -o jsonpath='{…volumes}'` | `emptyDir`, or no volume at all | Use a PVC (stage 07) |
| Edited `init.sql`, nothing changed | — | initdb scripts run **only on an empty data directory** | Use a migration, not the entrypoint |
| PV stuck `Released` | `get pv` | `reclaimPolicy: Retain` — by design | `kubectl delete pv <name>` when you are sure |
| PVC still there after deleting a StatefulSet | `get pvc` | By design — data outlives workloads | Delete it explicitly if you mean to |

---

## Networking

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| Service refuses connections | `get endpointslices -n notes-platform` | Empty endpoints — selector mismatch, or no pod Ready | Compare `svc -o jsonpath='{.spec.selector}'` with `pods --show-labels` |
| Endpoints exist, still refused | `get svc <name> -o yaml` | Wrong `targetPort` | Point it at the container's **named** port |
| `could not translate host name` | `exec … env \| grep POSTGRES_HOST` | DNS failure — wrong FQDN or namespace | Use `<svc>.<ns>.svc.cluster.local` |
| `Connection refused` to a name that resolves | `get endpointslices` | DNS worked; nothing is listening | Check the port and the app's bind address (`0.0.0.0`, not `127.0.0.1`) |
| Only one replica ever answers | — | A hardcoded pod IP, or a keep-alive connection | Use the Service; remember balancing is per **connection** |
| `postgres-0.postgres-headless…` NXDOMAIN | `get sts -o jsonpath='{.spec.serviceName}'` | Wrong `serviceName`, or the Service is not headless | `clusterIP` must be `None` |

---

## Ingress

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `Connection refused` on :80 | `get pods -n ingress-nginx` | No controller, or no port mapping | Install the controller; recreate the cluster from `kind-ingress.yaml` |
| `ADDRESS` empty after a minute | `get ingressclass` | Wrong or missing `ingressClassName`; no default class | Set `ingressClassName: nginx` |
| **404** from nginx | `describe ingress` | No rule matched the Host and path | Check the Host header you sent |
| **503** from nginx | `get endpointslices` | The rule matched; no ready endpoints | Fix pod readiness |
| **502** from nginx | `logs -n ingress-nginx <controller>` | Endpoints exist; the connection failed | `targetPort`, app logs, bind address |
| **502** text body naming a URL | `logs deployment/notes-web` | The **web tier** cannot reach the API | `NOTES_API_URL`, the `notes-api` Service |
| **503** JSON `"cannot reach postgres at …"` | `get pods -l app.kubernetes.io/name=postgres` | The **API** cannot reach the database | `postgres-0`, its probe, the Secret |
| `EXTERNAL-IP: <pending>` on a LoadBalancer | `get pods -A \| grep cloud` | No cloud controller manager — **normal on Kind** | Install `cloud-provider-kind`/MetalLB, or use the Ingress |

---

## Configuration

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `CreateContainerConfigError` | `describe pod` | A missing ConfigMap/Secret key — it names the key | Apply the ConfigMap/Secret first |
| Edited a ConfigMap, nothing changed | `exec … env` | **Env vars are frozen at process start** | `kubectl rollout restart` |
| Edited a ConfigMap, a mounted file did not change | — | `subPath` mounts are never refreshed | Mount the whole directory, or restart |
| `cannot unmarshal number into … of type string` | — | An unquoted number or boolean in `data` | Quote every value |
| `password authentication failed` | `logs statefulset/postgres` | The Secret and the initialised database disagree | `ALTER USER … PASSWORD`, then restart clients |
| A decoded Secret has a trailing newline | `… \| base64 -d \| xxd` | `echo` without `-n` | Use `stringData` |

---

## Rollouts

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `rollout status` times out | `get pods` | New pods never become Ready | `describe pod` → readiness events |
| New pods `0/1`, old ones still serving | `describe pod` | `maxUnavailable: 0` protecting you | Fix the new version, or `rollout undo` |
| 502s during a rollout | `get deploy -o yaml` | No readiness probe, or no `preStop` | Add probes (stage 11); `preStop` is Project 05 |
| `field is immutable` | — | You changed a selector, or a `volumeClaimTemplate` | Delete and recreate the workload |
| StatefulSet stuck at `0/3` | `get pods` | `OrderedReady` — pod 0 is not Ready, so pod 1 is never created | Fix pod 0 |

---

## Application behaviour that is not a bug

| Observation | Explanation |
|---|---|
| The "served by pod" line changes on refresh | Load balancing across API replicas — the note list stays identical because all of them read one database |
| Seed notes reappear after a restart | Only when the data directory was empty. Once a PVC persists, `init.sql` never runs again |
| `postgres-1` and `postgres-2` have different data from `postgres-0` | Correct. A StatefulSet gives identity and storage, **not** replication |
| PVC `Pending` before any pod exists | `WaitForFirstConsumer`, working as designed |
| `EXTERNAL-IP: <pending>` on Kind | No cloud controller. The manifest is right; the platform is missing |
| API pods go `0/1` when the database is down | The readiness probe doing its job — no restarts, and they recover on their own |

---

## Environment

| Symptom | Fix |
|---|---|
| `The connection to the server … was refused` | The cluster is not running — `kind get clusters`, `kubectl config use-context kind-kubernetes-lab` |
| `no matches for kind "Ingress" in version "extensions/v1beta1"` | A deprecated API version — this repo uses `networking.k8s.io/v1` |
| Ingress unreachable, controller healthy | The cluster lacks `extraPortMappings` — recreate it from `clusters/kind-ingress.yaml` |
| PVCs never bind, no StorageClass listed | Kind's `standard` class is missing — recreate the cluster |
| `port is already allocated` creating the cluster | Something else is on port 80 |

---

## Official troubleshooting references

*(All links verified 2026-08-28.)*

| Reference | What it covers |
|---|---|
| [Debug applications](https://kubernetes.io/docs/tasks/debug/debug-application/) | The general method: describe, logs, events |
| [Debug a running pod](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/) | `exec`, ephemeral containers, copying a pod for debugging |
| [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) | Phases, binding, reclaim policies |
| [Configure probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) | Every probe field and failure mode |
| [Ingress controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/) | Why an Ingress with no controller does nothing |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Failure labs](../failure-labs/labs.md)** | [Project 02](../README.md) | **[Interview questions](../interview-questions/questions.md)** ▶ |
