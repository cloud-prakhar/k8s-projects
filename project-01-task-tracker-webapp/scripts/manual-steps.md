# Manual Steps — Project 01

**Every command the scripts run is written out here by hand, with an explanation.**

Scripts are a convenience *after* you understand the steps. Run only `./deploy.sh` and you'll have learned a shell
script, not Kubernetes. Work through this document the first time; use the scripts afterwards to reset quickly.

> **Repository rule:** a script may not do anything that isn't explained here. Change a script → update this file in
> the same commit.

**This document covers the operational sequence.** The *why* for each resource lives in its stage README —
[00](../manifests/00-namespace/README.md) · [01](../manifests/01-pods/README.md) ·
[02](../manifests/02-replicasets/README.md) · [03](../manifests/03-deployments/README.md) ·
[04](../manifests/04-services/README.md) · [05](../manifests/05-configmaps/README.md) ·
[06](../manifests/06-secrets/README.md) · [11](../manifests/11-health-checks/README.md) ·
[19](../manifests/19-final/README.md).

| Notation | Meaning |
|---|---|
| ▸ **What it does** | Plain-language explanation of the command and its flags |
| ▸ **Expected output** | What success looks like |
| ▸ **If it fails** | Most likely cause and the next command to run |

All paths are relative to the **project directory** (`project-01-task-tracker-webapp/`).

---

# Part 1 — Cluster setup

*Script equivalent: none — you do this once.*

### Step 1.1 — Create the cluster

```bash
kind create cluster --name kubernetes-lab --config ../clusters/kind-single-node.yaml
```

▸ **What it does:** Kind runs each Kubernetes node as a Docker container. `--name` sets the cluster name, which also
determines the kube-context (`kind-kubernetes-lab`). `--config` supplies the node layout — this project uses the
single-node config because the lesson is workloads and networking, not scheduling.

▸ **Expected output:** several `✓` lines ending with `Set kubectl context to "kind-kubernetes-lab"`.

▸ **If it fails:** run `docker ps` — the Docker daemon must be running. A name clash means the cluster exists
already: `kind get clusters`, then reuse it or `kind delete cluster --name kubernetes-lab`.

### Step 1.2 — Confirm you're pointed at the right cluster

```bash
kubectl config current-context
kubectl get nodes -o wide
```

▸ **What it does:** `current-context` shows which cluster `kubectl` talks to. A stale context is the most common
cause of "my changes did nothing" — you were editing a different cluster. `get nodes -o wide` adds IP, OS and kubelet
version columns.

▸ **Expected output:** context `kind-kubernetes-lab`; one node, `STATUS: Ready`, role `control-plane`.

▸ **If it fails:** `kubectl config use-context kind-kubernetes-lab`.

---

# Part 2 — Build and load the images

*Script equivalent: [`build-images.sh`](build-images.sh)*

### Step 2.1 — Build the backend

```bash
docker build -t task-api:1.0.0 application/backend
```

▸ **What it does:** builds the image and tags it `name:version`. We always use an explicit version and **never**
`latest`, because `latest` can point at different content over time — which makes rollouts and rollbacks
unpredictable.

▸ **Expected output:** ends with `naming to docker.io/library/task-api:1.0.0`.

▸ **If it fails:** read the failing stage. The Dockerfile is at `application/backend/Dockerfile`; the two-stage build
installs dependencies into a venv, then copies only that venv into a clean runtime image.

### Step 2.2 — Build the frontend

```bash
docker build -t task-web:1.0.0 application/frontend
```

▸ **Expected output:** as above, for `task-web:1.0.0`.

### Step 2.3 — Load both images into the cluster

```bash
kind load docker-image task-api:1.0.0 --name kubernetes-lab
kind load docker-image task-web:1.0.0 --name kubernetes-lab
```

▸ **What it does:** copies the images from your laptop's Docker daemon into each Kind node's own image store.

▸ **Why it's needed:** the kubelet inside a Kind node cannot see your local Docker images. Skip this and the kubelet
tries to pull `task-api:1.0.0` from Docker Hub, where it doesn't exist — the number-one cause of `ErrImagePull` /
`ImagePullBackOff` in local labs.

▸ **Expected output:** `Image: "task-api:1.0.0" with ID ... not yet present on node "kubernetes-lab-control-plane", loading...`

▸ **Verify:**

```bash
docker exec -it kubernetes-lab-control-plane crictl images | grep task-
```

▸ **Also required in the manifests:** `imagePullPolicy: IfNotPresent`. With `Always`, the kubelet ignores the loaded
copy and tries the registry anyway.

### Step 2.4 (optional) — Run the app with plain Docker first

```bash
docker network create tasknet
docker run -d --name api --network tasknet task-api:1.0.0
docker run -d --name web --network tasknet -p 18080:8080 -e TASK_API_URL=http://api:8080 task-web:1.0.0
curl -s localhost:18080/api/tasks
docker rm -f api web && docker network rm tasknet
```

▸ **Why bother:** if the app doesn't work in Docker, it won't work in Kubernetes — and you'd waste an hour debugging
the wrong layer. Always establish that the app is fine before blaming the platform.

---

# Part 3 — Deploy, stage by stage

*Script equivalent: [`deploy.sh`](deploy.sh) — but the script jumps straight to the final state. Below is the
**learning path**, which is what you should follow the first time.*

## 3.1 — Namespace (stage 00)

```bash
kubectl apply -f manifests/00-namespace/namespace.yaml
kubectl get namespace task-tracker
```

▸ **What it does:** `apply` sends the manifest to the API server, which creates the object if absent and patches it
if present. That idempotency is why we use `apply` rather than `create` — re-running is always safe.

▸ **Expected output:** `namespace/task-tracker created`, then `STATUS: Active`.

▸ **If it fails:** `the path ... does not exist` means you're in the wrong directory. All paths here are relative to
the project directory.

## 3.2 — A single Pod (stage 01)

```bash
kubectl apply -f manifests/01-pods/pod.yaml
kubectl get pods -n task-tracker -o wide
```

▸ **What it does:** creates the smallest schedulable unit. `-o wide` adds the **Pod IP** and node columns.

▸ **Expected output:** `task-api  1/1  Running`, with an IP like `10.244.0.5`. **Write that IP down.**

▸ **If it fails:**
- `ImagePullBackOff` → step 2.3 wasn't done, or `imagePullPolicy` isn't `IfNotPresent`
- `Pending` → `kubectl describe pod task-api -n task-tracker` and read the Events at the bottom

**Reach it:**

```bash
kubectl port-forward pod/task-api 8080:8080 -n task-tracker
# another terminal:
curl -s localhost:8080/api/tasks
```

▸ **What it does:** tunnels a local port through the API server to this one Pod. Debugging only — single client, no
load balancing, dies with the command.

**Now feel the problem:**

```bash
kubectl delete pod task-api -n task-tracker
kubectl get pods -n task-tracker
```

▸ **Expected output:** `No resources found`. Your app is gone permanently — nothing was watching. This is the failure
that motivates stage 02.

## 3.3 — ReplicaSet (stage 02)

```bash
kubectl apply -f manifests/02-replicasets/replicaset.yaml
kubectl get replicaset,pods -n task-tracker
```

▸ **Expected output:** `DESIRED 3, CURRENT 3, READY 3`, and three Pods named `task-api-<random>`.

**Watch self-healing:**

```bash
kubectl get pods -n task-tracker -w      # terminal 1
kubectl delete pod -n task-tracker -l app.kubernetes.io/name=task-api --wait=false | head -1   # terminal 2
```

▸ **What you see:** one Pod terminates, a **new Pod with a new name** appears within a second. The count returns to 3.

**Then hit its limit:**

```bash
kubectl set image replicaset/task-api task-api=task-api:2.0.0 -n task-tracker
kubectl get pods -n task-tracker -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
```

▸ **Expected output:** all Pods still on `1.0.0`. The ReplicaSet reconciles **count**, never **content** — the
template is only consulted when creating a *new* Pod. That's what motivates stage 03.

```bash
kubectl delete replicaset task-api -n task-tracker
```

## 3.4 — Deployments (stage 03)

```bash
kubectl apply -f manifests/03-deployments/
kubectl rollout status deployment/task-api -n task-tracker --timeout=120s
kubectl rollout status deployment/task-web -n task-tracker --timeout=120s
```

▸ **What `-f <directory>` does:** applies every manifest in it (not recursively — add `-R` for subdirectories).

▸ **What `rollout status` does:** blocks until the rollout finishes, exiting non-zero on failure. `apply` alone
returns instantly and tells you nothing about whether the app came up — this is the command you put in CI.

▸ **Expected output:** `deployment "task-api" successfully rolled out`.

▸ **If it hangs:** it's waiting for Pods that never become ready. In another terminal:
`kubectl get pods -n task-tracker` then `kubectl describe pod <pod> -n task-tracker`.

**See the chain:**

```bash
kubectl get deployments,replicasets,pods -n task-tracker
```

▸ Names show the hierarchy: `task-api` → `task-api-6d4f8b9c7` → `task-api-6d4f8b9c7-2xkqp`.

**Then break it the way stage 03 describes** — point `task-web` at a real backend Pod IP, delete that Pod, and watch
the 502. Full walkthrough in [stage 03 §9](../manifests/03-deployments/README.md).

## 3.5 — Services (stage 04)

```bash
kubectl apply -f manifests/04-services/task-api-service.yaml
kubectl apply -f manifests/04-services/task-web-service.yaml
kubectl get svc -n task-tracker
kubectl get endpointslices -n task-tracker
```

▸ **What it does:** creates a stable virtual IP and DNS name in front of each set of Pods.

▸ **The check that matters is the second one.** An EndpointSlice lists the **ready** Pod IPs the Service will forward
to. `<unset>` or empty means the Service is wired to nothing — and *no object reports an error*. This is the most
common silent failure in Kubernetes.

▸ **Expected output:**

```
NAME             ADDRESSTYPE   PORTS   ENDPOINTS
task-api-abc12   IPv4          8080    10.244.0.7,10.244.0.8,10.244.0.9
```

▸ **If endpoints are empty:** compare the Service selector with the Pod labels —
`kubectl describe svc task-api -n task-tracker | grep Selector` versus
`kubectl get pods -n task-tracker --show-labels`.

**Point the frontend at the Service instead of a Pod IP:**

```bash
kubectl apply -f manifests/04-services/task-web-deployment-patched.yaml
kubectl rollout status deployment/task-web -n task-tracker
```

▸ **What changed:** `TASK_API_URL` went from `http://10.244.0.7:8080` to
`http://task-api.task-tracker.svc.cluster.local:8080`. A Pod-template change, so a rolling update happens.

## 3.6 — ConfigMap (stage 05)

```bash
kubectl apply -f manifests/05-configmaps/configmap.yaml
kubectl apply -f manifests/05-configmaps/task-api-deployment.yaml
kubectl apply -f manifests/05-configmaps/task-web-deployment.yaml
kubectl rollout status deployment/task-api -n task-tracker
kubectl rollout status deployment/task-web -n task-tracker
```

▸ **Order matters:** create the ConfigMap **before** the workloads that reference it. A Pod referencing a missing key
sits in `CreateContainerConfigError` and never starts.

▸ **Verify the values reached the container:**

```bash
kubectl exec deployment/task-api -n task-tracker -- env | grep -E 'APP_ENV|LOG_LEVEL'
```

▸ **Important behaviour:** editing the ConfigMap does **not** change running Pods. The process environment is fixed
at `exec()` time. To roll a config change out:

```bash
kubectl rollout restart deployment/task-api -n task-tracker
```

▸ **What `rollout restart` does:** patches the Pod template with a `restartedAt` annotation, which is a template
change, which triggers a normal rolling update. Zero downtime — unlike deleting Pods.

## 3.7 — Secret (stage 06)

```bash
kubectl apply -f manifests/06-secrets/secret.yaml
kubectl apply -f manifests/06-secrets/task-api-deployment.yaml
kubectl apply -f manifests/06-secrets/task-web-deployment.yaml
kubectl rollout status deployment/task-api -n task-tracker
kubectl rollout status deployment/task-web -n task-tracker
```

▸ **Both tiers must roll together.** The moment the API sees a non-empty `API_TOKEN` it starts requiring the
`X-API-Token` header. If `task-web` doesn't have the token yet, every request becomes a 401.

▸ **Inspect it** (Secrets are base64-**encoded**, not encrypted):

```bash
kubectl describe secret task-api-secret -n task-tracker          # shows "27 bytes", not the value
kubectl get secret task-api-secret -n task-tracker -o jsonpath='{.data.API_TOKEN}' | base64 -d; echo
```

▸ **What that proves:** anyone with `get secrets` in this namespace has the credential. RBAC is the real control, not
base64.

## 3.8 — Probes (stage 11)

```bash
kubectl apply -f manifests/11-health-checks/
kubectl rollout status deployment/task-api -n task-tracker
kubectl rollout status deployment/task-web -n task-tracker
```

▸ **What changes:** `1/1 READY` now means the app answered `/healthz` with a 200 — not merely that a process started.
Only now is `maxUnavailable: 0` a real zero-downtime guarantee.

▸ **Verify the probes are registered:**

```bash
kubectl describe pod -n task-tracker -l app.kubernetes.io/name=task-api | grep -E 'Liveness|Readiness|Startup'
```

## 3.9 — The combined manifest (stage 19)

```bash
kubectl kustomize manifests/19-final/          # preview — ALWAYS do this first
kubectl apply -k manifests/19-final/
```

▸ **What `-k` does:** renders the kustomization client-side and applies the result. `kubectl kustomize` prints that
result without applying — inspect before you apply, every time.

▸ **Expected output:** mostly `unchanged`. That's the proof that your incremental path and the combined manifest
describe the same cluster.

---

# Part 4 — Validate

*Script equivalent: [`validate.sh`](validate.sh)*

### Step 4.1 — Everything exists

```bash
kubectl get all -n task-tracker
```

▸ **What it does:** lists common namespaced resources. Note `all` is a misnomer — it excludes ConfigMaps, Secrets,
Ingresses and PVCs. Check those explicitly:

```bash
kubectl get configmap,secret -n task-tracker
```

### Step 4.2 — Pods are Ready, not merely Running

```bash
kubectl get pods -n task-tracker -o wide
```

▸ **Read the READY column, not STATUS.** `Running` with `0/1` means the container is up but its readiness probe is
failing — so the Service is deliberately **not** sending it traffic. That distinction is the entire point of
readiness probes.

▸ **Expected:** 3 × `task-api` and 2 × `task-web`, all `1/1 Running`.

### Step 4.3 — Services have endpoints

```bash
kubectl get endpointslices -n task-tracker
```

▸ **Expected:** three IPs for `task-api`, two for `task-web`.

### Step 4.4 — The app answers, from inside the cluster

```bash
kubectl run t --rm -it --restart=Never --image=curlimages/curl:8.10.1 -n task-tracker -- \
  curl -sS http://task-web.task-tracker.svc.cluster.local/api/tasks
```

▸ **What it does:** starts a throwaway Pod inside the cluster and calls the web tier by its DNS name. This exercises
CoreDNS, both Services, both EndpointSlices and both tiers in one command. `--rm` deletes the Pod on exit.

▸ **Expected output:** a JSON array of tasks.

### Step 4.5 — Use it in a browser

```bash
kubectl port-forward svc/task-web 8080:80 -n task-tracker
```

▸ **What the numbers mean:** local port 8080 → the **Service's** port 80 (which forwards to container port 8080).

▸ Open <http://localhost:8080>. Add a task. Refresh several times and watch the "served by pod" line change — that's
kube-proxy balancing across three backend Pods.

▸ **Expect tasks to appear and disappear.** Each API Pod has its own in-memory list. Not a bug — a demonstration that
in-memory state and multiple replicas don't mix, which is what Project 02 fixes.

### Step 4.6 — Debug fallback: bypass everything

```bash
kubectl port-forward deployment/task-api 9090:8080 -n task-tracker
curl -s localhost:9090/livez
```

▸ **What it does:** tunnels straight to a Pod, skipping the Service and kube-proxy. If this works and the Service
doesn't, the fault is in the Service layer (selector or `targetPort`), not the application. This single test splits
the problem space in half.

---

# Part 5 — Cleanup

*Script equivalent: [`cleanup.sh`](cleanup.sh)*

### Step 5.1 — Delete the namespace

```bash
kubectl delete namespace task-tracker
```

▸ **What it does:** deletes every **namespaced** object inside it — Pods, Deployments, ReplicaSets, Services,
ConfigMaps, Secrets. Deletion is asynchronous: the namespace enters `Terminating` while the namespace controller
enumerates resource types and deletes what it finds.

▸ **If it hangs in `Terminating`:** something has a finalizer.

```bash
kubectl get namespace task-tracker -o jsonpath='{.spec.finalizers}'
```

### Step 5.2 — Check for cluster-scoped leftovers

```bash
kubectl get pv
kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=task-tracker
```

▸ **Why bother when this project creates none:** PersistentVolumes, StorageClasses, ClusterRoles, ClusterRoleBindings
and PriorityClasses live **outside** namespaces and survive `delete namespace`. Project 02 onwards creates them, and
a PV with a `Retain` policy will sit in `Released` forever holding disk. Build the habit now.

### Step 5.3 — Nuclear option

```bash
kind delete cluster --name kubernetes-lab
```

▸ **What it does:** destroys the whole cluster in seconds. Entirely fine in a lab — recreating takes about a minute,
and starting from a clean cluster beats debugging a polluted one.

---

# Command reference used in this project

| Command | What it does | Flag worth knowing |
|---|---|---|
| `kubectl apply -f` | Create or update from a manifest (idempotent) | `-k` for kustomize, `-R` recursive, `--dry-run=server` |
| `kubectl get` | List objects | `-o wide`, `-o yaml`, `-o jsonpath=…`, `-w` watch, `-l` by label, `--show-labels`, `-A` all namespaces |
| `kubectl describe` | Full detail **plus Events** — always read the bottom | — |
| `kubectl logs` | Container stdout/stderr | `-f` follow, `--previous` the crashed instance, `--tail=N` |
| `kubectl exec -it` | Run a command in a container | `-c` for multi-container Pods |
| `kubectl run` | One-off Pod, ideal for in-cluster tests | `--rm -it --restart=Never` |
| `kubectl rollout status` | Block until a rollout completes | `--timeout=120s` |
| `kubectl rollout restart` | Trigger a rolling restart (picks up config changes) | — |
| `kubectl rollout history` / `undo` | Revisions and rollback | `--revision=N`, `--to-revision=N` |
| `kubectl scale` | Change replicas imperatively | ⚠️ overwritten by the next `apply` |
| `kubectl set image` / `set env` | Quick imperative edits | Same caveat |
| `kubectl port-forward` | Tunnel to a Pod/Service | Debugging only |
| `kubectl get events --sort-by=.lastTimestamp` | What the cluster did recently | Retention is ~1 hour |
| `kubectl get endpointslices` | Which Pods a Service will route to | The first thing to check on a connection failure |
| `kubectl explain <kind>.spec` | Field docs from the live API server | `--recursive` |
| `kind load docker-image` | Copy a local image into the cluster | `--name <cluster>` |
