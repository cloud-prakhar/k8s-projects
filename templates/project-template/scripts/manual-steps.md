# Manual Steps — Project XX

**Every script in this directory has its steps written out here, by hand, with an explanation of each command.**

Scripts are a convenience *after* you understand the steps — never a substitute for understanding them. If you only
ever run `./deploy.sh`, you learn a shell script, not Kubernetes. Work through this document the first time; use the
scripts afterwards.

> **Rule for this repository:** a script may not do anything that isn't explained here. If you change a script,
> change this file in the same commit.

---

## Conventions used below

| Notation | Meaning |
|---|---|
| `<ns>` | This project's namespace |
| `$` | Run on your machine |
| ▸ **What it does** | Plain-language explanation of the command |
| ▸ **Expected output** | What success looks like |
| ▸ **If it fails** | The most likely cause and where to look |

---

# Part 1 — Cluster setup

*(script equivalent: none — you do this once per project)*

### Step 1.1 — Create the cluster

```bash
kind create cluster --name kubernetes-lab --config ../../clusters/kind-<config>.yaml
```

▸ **What it does:** `kind` runs each Kubernetes "node" as a Docker container. `--name` sets the cluster name (and
therefore the kube-context, `kind-kubernetes-lab`). `--config` supplies the node layout — this project needs
`<config>` because <reason: port mappings for Ingress / multiple nodes for scheduling>.

▸ **Expected output:** several `✓` lines ending with `Set kubectl context to "kind-kubernetes-lab"`.

▸ **If it fails:** `docker ps` — the Docker daemon must be running. A name clash means the cluster already exists:
`kind get clusters`, then either reuse it or `kind delete cluster --name kubernetes-lab`.

### Step 1.2 — Verify you're pointed at the right cluster

```bash
kubectl config current-context
kubectl get nodes -o wide
```

▸ **What it does:** `current-context` shows which cluster `kubectl` will talk to — the single most common cause of
"my changes did nothing" is a stale context. `get nodes -o wide` lists nodes with IPs, OS, and kubelet version.

▸ **Expected output:** context `kind-kubernetes-lab`; all nodes `Ready`.

▸ **If it fails:** `kubectl config use-context kind-kubernetes-lab`.

---

# Part 2 — Build and load images

*(script equivalent: [`build-images.sh`](build-images.sh))*

### Step 2.1 — Build the image

```bash
docker build -t <project>-backend:1.0.0 ../application/backend
```

▸ **What it does:** builds the container image and tags it `name:version`. We use an explicit version, never
`latest` — `latest` makes rollouts unpredictable because the tag can point at different content over time.

▸ **Expected output:** ends with `naming to docker.io/library/<project>-backend:1.0.0`.

▸ **If it fails:** read the failing build stage; the Dockerfile is in `application/backend/Dockerfile`.

### Step 2.2 — Load the image into the cluster

```bash
kind load docker-image <project>-backend:1.0.0 --name kubernetes-lab
```

▸ **What it does:** copies the image from your laptop's Docker daemon into each Kind node's own image store.

▸ **Why it's needed:** the kubelet inside a Kind node cannot see your local Docker images. Skipping this is the
number-one cause of `ErrImagePull` / `ImagePullBackOff` in local labs, because the kubelet falls back to pulling from
Docker Hub, where your image doesn't exist.

▸ **Expected output:** `Image: "<project>-backend:1.0.0" with ID ... not yet present on node ..., loading...`

▸ **Verify:**

```bash
docker exec -it kubernetes-lab-control-plane crictl images | grep <project>
```

▸ **Also required in the manifest:** `imagePullPolicy: IfNotPresent`. With `Always`, the kubelet ignores the loaded
copy and tries the registry anyway.

---

# Part 3 — Deploy, stage by stage

*(script equivalent: [`deploy.sh`](deploy.sh) — it runs exactly these steps in this order)*

> Each stage below corresponds to one `manifests/NN-*/` directory. The **why** for each resource lives in that
> directory's `README.md`; this document is the operational sequence.

### Step 3.1 — Namespace

```bash
kubectl apply -f ../manifests/00-namespace/namespace.yaml
kubectl get namespace <ns>
```

▸ **What it does:** `apply` sends the manifest to the API server, which creates the object if absent or patches it
if present — that's what makes `apply` idempotent and re-runnable, unlike `create`.

▸ **Expected output:** `namespace/<ns> created`, then `Active`.

▸ **If it fails:** `error: the path ... does not exist` means you're in the wrong directory — paths here are relative
to `scripts/`.

### Step 3.2 — Deployments

```bash
kubectl apply -f ../manifests/03-deployments/
kubectl rollout status deployment/<name> -n <ns> --timeout=120s
```

▸ **What it does:** `-f <directory>` applies every manifest in it (non-recursively; add `-R` for subdirectories).
`rollout status` blocks until the new ReplicaSet reports enough ready replicas, so the next step doesn't race ahead.

▸ **Expected output:** `deployment "<name>" successfully rolled out`.

▸ **If it fails:** it will hang instead of erroring. In another terminal:
`kubectl get pods -n <ns>` then `kubectl describe pod <pod> -n <ns>` and read the **Events** section at the bottom.

### Step 3.3 — Services

```bash
kubectl apply -f ../manifests/04-services/
kubectl get svc -n <ns>
kubectl get endpointslices -n <ns>
```

▸ **What it does:** creates the stable virtual IP and DNS name in front of the pods. The EndpointSlice check is the
important one: it lists the **Ready** pod IPs the Service will forward to.

▸ **Expected output:** each Service has at least one endpoint address.

▸ **If it fails:** an empty EndpointSlice means the Service `selector` doesn't match any Ready pod's labels — compare
`kubectl get svc <name> -n <ns> -o jsonpath='{.spec.selector}'` with
`kubectl get pods -n <ns> --show-labels`.

### Step 3.4 — ConfigMaps and Secrets

```bash
kubectl apply -f ../manifests/05-configmaps/
kubectl apply -f ../manifests/06-secrets/
kubectl get configmap,secret -n <ns>
```

▸ **What it does:** creates the configuration objects the pods reference.

▸ **Order matters:** a pod referencing a missing ConfigMap/Secret key stays in `CreateContainerConfigError`. Apply
config *before* the workloads that consume it, or restart the workloads afterwards.

▸ **Inspect a value** (Secrets are base64-**encoded**, not encrypted):

```bash
kubectl get secret <name> -n <ns> -o jsonpath='{.data.PASSWORD}' | base64 -d; echo
```

### Step 3.5 — Storage

```bash
kubectl apply -f ../manifests/07-storage/
kubectl get pvc -n <ns>
kubectl get pv
```

▸ **What it does:** requests storage. With a dynamic StorageClass, creating the PVC triggers the provisioner to
create a matching PV automatically.

▸ **Expected output:** PVC `Bound`.

▸ **If it fails:** `Pending` → `kubectl describe pvc <name> -n <ns>`. Usually no default StorageClass
(`kubectl get sc`) or an access mode/size that nothing can satisfy.

### Step 3.6 — Ingress

```bash
kubectl apply -f ../manifests/09-ingress/
kubectl get ingress -n <ns>
```

▸ **Prerequisite:** the Ingress **Controller** must already be installed. An Ingress resource with no controller does
nothing at all — no error, no routing, no clue. See `docs/local-vs-cloud.md` §4.

▸ **Add the host to your hosts file** so the browser sends the right `Host` header:

```bash
echo "127.0.0.1  <app>.local" | sudo tee -a /etc/hosts
```

▸ **Expected output:** `kubectl get ingress` shows the host and an ADDRESS.

▸ **If it fails:** 404 = no rule matched (host/path/ingressClassName). 503 = rule matched but the Service has no
ready endpoints. 502 = reached a pod but the connection failed, usually a wrong `targetPort`.

---

# Part 4 — Validate

*(script equivalent: [`validate.sh`](validate.sh))*

### Step 4.1 — Everything running

```bash
kubectl get all -n <ns>
```

▸ **What it does:** lists the common namespaced resources at once. Note that `all` is a misnomer — it excludes
ConfigMaps, Secrets, Ingresses, PVCs and more. Check those explicitly.

### Step 4.2 — Pods actually Ready

```bash
kubectl get pods -n <ns> -o wide
```

▸ **Read the READY column, not STATUS.** `Running` with `0/1` means the container is up but its readiness probe is
failing — so the Service is *not* sending it traffic. That distinction is the whole point of readiness probes.

### Step 4.3 — Service routing works

```bash
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -n <ns> -- \
  curl -s http://<service>.<ns>.svc.cluster.local/healthz
```

▸ **What it does:** starts a throwaway pod inside the cluster and curls the Service by its DNS name. This tests
cluster DNS, the Service, the EndpointSlice, and the app in one shot. `--rm` deletes the pod on exit.

### Step 4.4 — External access works

```bash
curl -i http://<app>.local/healthz
```

▸ **Expected output:** `HTTP/1.1 200 OK`.

### Step 4.5 — Debug fallback: bypass everything

```bash
kubectl port-forward pod/<pod> 8080:8080 -n <ns>
curl localhost:8080/healthz
```

▸ **What it does:** tunnels straight to one pod, skipping Ingress, Service, and kube-proxy. If this works and the
Service doesn't, the fault is in the Service/Ingress layer, not the application. Debugging only — it's a single
client, no load balancing, and it dies with the command.

---

# Part 5 — Cleanup

*(script equivalent: [`cleanup.sh`](cleanup.sh))*

### Step 5.1 — Delete the namespace

```bash
kubectl delete namespace <ns>
```

▸ **What it does:** deletes every **namespaced** object inside it — pods, deployments, services, configmaps, secrets,
PVCs. Deletion is asynchronous; it can take a minute while finalizers run.

▸ **If it hangs in `Terminating`:** something has a finalizer.
`kubectl get namespace <ns> -o jsonpath='{.spec.finalizers}'` and `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns>` to find what's left.

### Step 5.2 — Delete cluster-scoped leftovers

```bash
kubectl get pv
kubectl delete pv -l app.kubernetes.io/part-of=<project>
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=<project>
```

▸ **Why it's needed:** PersistentVolumes, StorageClasses, ClusterRoles, ClusterRoleBindings and PriorityClasses live
**outside** namespaces and survive the namespace deletion. A PV with a `Retain` reclaim policy will sit in `Released`
forever, holding disk.

### Step 5.3 — Nuclear option

```bash
kind delete cluster --name kubernetes-lab
```

▸ **What it does:** destroys the whole cluster and all its data in a few seconds. Perfectly fine in a lab —
recreating takes about a minute, and starting from a known-clean cluster beats debugging a polluted one.

---

# Command reference used in this project

| Command | What it does | Flag worth knowing |
|---|---|---|
| `kubectl apply -f` | Create or update from a manifest (idempotent) | `--dry-run=server` validates without creating |
| `kubectl get` | List objects | `-o wide`, `-o yaml`, `-w` to watch, `-l` by label, `-A` all namespaces |
| `kubectl describe` | Full detail **plus the Events** — always read the bottom | — |
| `kubectl logs` | Container stdout/stderr | `-f` follow, `--previous` the crashed instance, `-c` pick a container |
| `kubectl exec -it` | Shell into a running container | `-c` for multi-container pods |
| `kubectl rollout` | `status`, `history`, `undo`, `restart` | `--to-revision=N` |
| `kubectl scale` | Change replicas imperatively | ⚠️ overwritten by the next `apply` |
| `kubectl port-forward` | Tunnel a local port to a pod/service | Debugging only |
| `kubectl top` | Live CPU/memory | Requires Metrics Server |
| `kubectl get events --sort-by=.lastTimestamp` | What the cluster did recently | Default retention is only ~1 hour |
| `kubectl explain <kind>.spec` | Field documentation from the live API server | `--recursive` |
| `kubectl auth can-i` | Test RBAC | `--as=system:serviceaccount:<ns>:<sa>` |
