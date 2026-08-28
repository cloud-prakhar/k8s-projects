# Manual Steps — Project 02

Every command the scripts run, written out by hand and explained. **You can
complete this entire project without executing a single script.**

> **Why this file exists:** a script that "just works" teaches you a shell
> script, not Kubernetes. Automation is the convenience you earn *after* you
> understand the sequence. It also means a broken script never blocks learning —
> the manual path always exists.

Every command below gets three things:

▸ **What it does** — the command and its flags, in plain language
▸ **Expected output** — what success actually prints
▸ **If it fails** — the most likely cause and the next command to run

| Part | Script equivalent | Time |
|---|---|---|
| [1 — Cluster setup](#part-1--cluster-setup) | *(none — do this once)* | 5 min |
| [2 — Build and load the images](#part-2--build-and-load-the-images) | `build-images.sh` | 5 min |
| [3 — Deploy, stage by stage](#part-3--deploy-stage-by-stage) | `deploy.sh` | 2 h |
| [4 — Validate](#part-4--validate) | `validate.sh` | 10 min |
| [5 — Cleanup](#part-5--cleanup) | `cleanup.sh` | 2 min |

The **why** for each resource lives in `manifests/NN-*/README.md`. This file owns
the operational sequence.

All commands are run from the **project directory**
(`project-02-three-tier-notes/`) unless stated otherwise.

---

# Part 1 — Cluster setup

## Step 1.1 — Create the cluster with ingress port mappings

```bash
cd ..                                   # repository root
kind create cluster --name kubernetes-lab --config clusters/kind-ingress.yaml
cd project-02-three-tier-notes
```

▸ **What it does:** creates a two-node Kind cluster (one control-plane, one
worker) and — the part that matters — maps your machine's ports **80 and 443**
into the control-plane node container, and labels that node `ingress-ready=true`
so the ingress controller will schedule there.

▸ **Expected output:**

```
Creating cluster "kubernetes-lab" …
 ✓ Ensuring node image (kindest/node:v1.32.x)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass
 ✓ Joining worker nodes
Set kubectl context to "kind-kubernetes-lab"
```

▸ **If it fails:** *"node(s) already exist"* — a cluster of this name is already
running. Either reuse it (`kubectl cluster-info`) or delete it with
`kind delete cluster --name kubernetes-lab`. *"port is already allocated"* — you
have something on port 80; stop it, or edit the config's `hostPort`.

> ⚠️ **You cannot add `extraPortMappings` to an existing cluster.** It is a
> node-creation setting. If you started from Project 01's
> `kind-single-node.yaml`, delete that cluster and recreate it with this config,
> or the Ingress in stage 09 will never be reachable.

## Step 1.2 — Confirm you are pointed at the right cluster

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass
```

▸ **What it does:** shows which cluster `kubectl` will talk to, that both nodes
are `Ready`, and that a default StorageClass exists — this project cannot
provision storage without one.

▸ **Expected output:**

```
kind-kubernetes-lab

NAME                           STATUS   ROLES           AGE   VERSION
kubernetes-lab-control-plane   Ready    control-plane   60s   v1.32.x
kubernetes-lab-worker          Ready    <none>          45s   v1.32.x

NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   60s
```

▸ **If it fails:** the wrong context — `kubectl config use-context
kind-kubernetes-lab`. No `(default)` next to a StorageClass means every PVC in
stage 07 will sit `Pending`.

## Step 1.3 — Install the NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

▸ **What it does:** installs the ingress controller — a Deployment, a Service, an
**IngressClass** named `nginx`, RBAC and admission webhooks — into a new
`ingress-nginx` namespace. The `kind`-specific manifest configures the controller
pod with `hostPort: 80/443`, which is how traffic reaches it without a cloud load
balancer. `kubectl wait` blocks until the controller pod passes its readiness
probe.

▸ **Expected output:**

```
namespace/ingress-nginx created
…
ingressclass.networking.k8s.io/nginx created
…
pod/ingress-nginx-controller-… condition met
```

▸ **If it fails:** a `wait` timeout usually means the controller pod cannot be
scheduled — check `kubectl get pods -n ingress-nginx` and
`kubectl describe pod -n ingress-nginx`. If it is `Pending` with a nodeSelector
message, your cluster was not created from `kind-ingress.yaml` and no node
carries `ingress-ready=true`.

> This is **cluster software**, installed once, shared by every project. It is
> not part of the Notes Platform, which is why `cleanup.sh` leaves it running.

---

# Part 2 — Build and load the images

## Step 2.1 — Build the API image

```bash
docker build -t notes-api:1.0.0 application/backend
```

▸ **What it does:** runs the two-stage Dockerfile — dependencies into a
virtualenv in a build stage, then only that virtualenv copied into a clean
runtime image. The result runs as UID 10001, not root.

▸ **Expected output:** ends with `naming to docker.io/library/notes-api:1.0.0`.

▸ **If it fails:** *"Cannot connect to the Docker daemon"* — Docker is not
running. A pip resolution error — check `application/backend/requirements.txt`;
every version is pinned deliberately.

## Step 2.2 — Build the web image

```bash
docker build -t notes-web:1.0.0 application/frontend
```

▸ **What it does:** same shape, plus `COPY static /static` for the UI.

## Step 2.3 — Load both images into the cluster

```bash
kind load docker-image notes-api:1.0.0 --name kubernetes-lab
kind load docker-image notes-web:1.0.0 --name kubernetes-lab
```

▸ **What it does:** a Kind "node" is a Docker container with **its own image
store**. An image in your laptop's daemon is invisible to it. This copies the
images into every node's store.

▸ **Expected output:**

```
Image: "notes-api:1.0.0" with ID "sha256:…" not yet present on node "kubernetes-lab-worker", loading...
```

▸ **If it fails:** *"image not found"* — the build did not tag what you think;
check `docker images | grep notes-`.

> **Skip this and you get `ErrImagePull` / `ImagePullBackOff`,** because the
> kubelet falls back to pulling `notes-api:1.0.0` from Docker Hub, where it does
> not exist. That is failure lab 1.

## Step 2.4 — Pre-pull PostgreSQL

```bash
docker pull postgres:17.5-alpine
kind load docker-image postgres:17.5-alpine --name kubernetes-lab
```

▸ **What it does:** PostgreSQL is a public image the kubelet *can* pull, but it
is ~100 MB and the first deploy otherwise sits in `ContainerCreating` looking
broken. Optional but kind to yourself.

## Step 2.5 (optional but recommended) — run all three tiers in plain Docker first

```bash
docker network create notes-test
docker run -d --name pg --network notes-test \
  -e POSTGRES_DB=notes -e POSTGRES_USER=notes -e POSTGRES_PASSWORD=devpassword \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v "$PWD/application/database/init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro" \
  postgres:17.5-alpine
sleep 12
docker run -d --name notes-api --network notes-test \
  -e POSTGRES_HOST=pg -e POSTGRES_DB=notes -e POSTGRES_USER=notes \
  -e POSTGRES_PASSWORD=devpassword -e POD_NAME=local-api -p 18081:8080 notes-api:1.0.0
docker run -d --name notes-web --network notes-test \
  -e NOTES_API_URL=http://notes-api:8080 -e POD_NAME=local-web -p 18080:8080 notes-web:1.0.0
sleep 5
curl -s localhost:18080/api/info; echo
curl -sX POST localhost:18080/api/notes -H 'Content-Type: application/json' -d '{"body":"hello"}'
```

▸ **What it does:** proves the application works before Kubernetes is involved.
If it is broken here, it is an application bug; if it works here and fails in the
cluster, the problem is your manifests. **This is the fastest way to halve your
debugging surface.**

▸ **Expected output:** `{"db_connected":true,…,"note_count":2,…}` then a created
note with `"id":3`.

▸ **Clean up when you are done:**

```bash
docker rm -f pg notes-api notes-web && docker network rm notes-test
```

---

# Part 3 — Deploy, stage by stage

Read the stage README **before** running its commands. The failures are the
lesson.

## 3.1 — Namespace (stage 00)

📖 [`manifests/00-namespace/README.md`](../manifests/00-namespace/README.md)

```bash
kubectl apply -f manifests/00-namespace/namespace.yaml
kubectl get namespace notes-platform
```

▸ **What it does:** creates the scope everything else lives in. `apply` is
declarative and idempotent — safe to re-run.

▸ **Expected output:** `namespace/notes-platform created`, then `Active`.

▸ **If it fails:** an invalid-name error means you edited the name — it must be a
lowercase DNS label.

## 3.2 — Three tiers as Deployments (stage 03)

📖 [`manifests/03-deployments/README.md`](../manifests/03-deployments/README.md)

```bash
kubectl apply -f manifests/03-deployments/postgres-deployment.yaml
kubectl rollout status deployment/postgres -n notes-platform --timeout=180s

kubectl apply -f manifests/03-deployments/notes-api-deployment.yaml
kubectl apply -f manifests/03-deployments/notes-web-deployment.yaml
kubectl get pods -n notes-platform -o wide
```

▸ **What it does:** creates three Deployments. `rollout status` blocks until the
desired replicas are available — the correct way to wait, instead of `sleep`.
`-o wide` adds the pod IP and node columns, which you need next.

▸ **Expected output:** five pods `Running`, with IPs like `10.244.1.4`.

▸ **If it fails:** `ImagePullBackOff` — step 2.3 was skipped.
`CrashLoopBackOff` — `kubectl logs <pod> -n notes-platform --previous`.

**Now wire them together with Pod IPs, which is the deliberate mistake:**

```bash
PG_IP=$(kubectl get pod -n notes-platform \
  -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].status.podIP}')
kubectl set env deployment/notes-api -n notes-platform POSTGRES_HOST="${PG_IP}"
kubectl rollout status deployment/notes-api -n notes-platform

API_IP=$(kubectl get pod -n notes-platform \
  -l app.kubernetes.io/name=notes-api -o jsonpath='{.items[0].status.podIP}')
kubectl set env deployment/notes-web -n notes-platform NOTES_API_URL="http://${API_IP}:8080"
kubectl rollout status deployment/notes-web -n notes-platform
```

▸ **What it does:** `-o jsonpath='{…}'` extracts one field from the API response
without `grep`. `kubectl set env` patches the pod template, which changes the
template hash, which triggers a rolling update.

▸ **Then break it on purpose:**

```bash
kubectl delete pod -n notes-platform -l app.kubernetes.io/name=postgres
kubectl port-forward deployment/notes-web 8080:8080 -n notes-platform &
sleep 2; curl -s localhost:8080/api/notes; echo; kill %1
```

▸ **Expected output:** `{"error":"cannot reach postgres at 10.244.1.4:5432", …}`
— the address of a pod that no longer exists.

## 3.3 — Services (stage 04)

📖 [`manifests/04-services/README.md`](../manifests/04-services/README.md)

```bash
kubectl apply -f manifests/04-services/postgres-service.yaml
kubectl apply -f manifests/04-services/notes-api-service.yaml
kubectl apply -f manifests/04-services/notes-web-service.yaml
kubectl apply -f manifests/04-services/notes-api-deployment-patched.yaml
kubectl apply -f manifests/04-services/notes-web-deployment-patched.yaml
kubectl rollout status deployment/notes-api -n notes-platform
kubectl rollout status deployment/notes-web -n notes-platform

kubectl get services,endpointslices -n notes-platform
```

▸ **What it does:** gives each tier a stable name and virtual IP, then repoints
the workloads at DNS names instead of IPs. The EndpointSlice listing is the check
that matters — it is the Service's actual backend set.

▸ **Expected output:** every EndpointSlice lists pod IPs.

▸ **If it fails:** `<unset>` under ENDPOINTS means the selector matches no pods,
or no pod is Ready. `kubectl get pods --show-labels -n notes-platform` and
compare against `kubectl get svc <name> -o jsonpath='{.spec.selector}'`.

```bash
kubectl port-forward svc/notes-web 8080:80 -n notes-platform &
sleep 2; curl -s localhost:8080/api/info; echo; kill %1
```

▸ **Expected output:** `"db_host":"postgres.notes-platform.svc.cluster.local"` —
a name, not an address.

## 3.4 — ConfigMaps (stage 05)

📖 [`manifests/05-configmaps/README.md`](../manifests/05-configmaps/README.md)

```bash
kubectl apply -f manifests/05-configmaps/configmap.yaml
kubectl apply -f manifests/05-configmaps/postgres-init-configmap.yaml
kubectl apply -f manifests/05-configmaps/postgres-deployment.yaml
kubectl apply -f manifests/05-configmaps/notes-api-deployment.yaml
kubectl apply -f manifests/05-configmaps/notes-web-deployment.yaml
kubectl rollout status deployment/postgres  -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform
kubectl rollout status deployment/notes-web -n notes-platform
```

▸ **What it does:** moves configuration out of the workload specs. **ConfigMaps
first** — a workload referencing a key that does not exist yet will not start.

▸ **Verify the values reached the containers, and the file was mounted:**

```bash
kubectl exec deployment/notes-api -n notes-platform -- env | grep POSTGRES_
kubectl exec deployment/postgres -n notes-platform -- ls -l /docker-entrypoint-initdb.d/
kubectl exec deployment/postgres -n notes-platform -- psql -U notes -d notes -c '\d notes'
```

▸ **Expected output:** the six connection variables; a symlink to
`10-init.sql`; and an index named `notes_created_at_idx`, which only `init.sql`
creates — proof the mounted file was executed.

▸ **If it fails:** `CreateContainerConfigError` means a missing ConfigMap or key.
`kubectl describe pod <pod> -n notes-platform` names it exactly.

## 3.5 — Secret (stage 06)

📖 [`manifests/06-secrets/README.md`](../manifests/06-secrets/README.md)

```bash
kubectl apply -f manifests/06-secrets/secret.yaml
kubectl apply -f manifests/06-secrets/postgres-deployment.yaml
kubectl apply -f manifests/06-secrets/notes-api-deployment.yaml
kubectl rollout status deployment/postgres  -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform

kubectl describe secret postgres-secret -n notes-platform
kubectl get secret postgres-secret -n notes-platform \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
```

▸ **What it does:** the password moves into a Secret, consumed by **both** the
database (which creates the user) and the API (which connects as it). The two
commands afterwards show the point: `describe` prints `32 bytes` instead of the
value — and one more command decodes it anyway. **Base64 is encoding, not
encryption.**

▸ **If it fails:** `Error: secret "postgres-secret" not found` — apply the Secret
before the workloads.

## 3.6 — Storage (stage 07)

📖 [`manifests/07-storage/README.md`](../manifests/07-storage/README.md)

**First, prove the problem.** Write a note, delete the database pod, count again:

```bash
kubectl port-forward svc/notes-web 8080:80 -n notes-platform &
sleep 2
curl -sX POST localhost:8080/api/notes -H 'Content-Type: application/json' \
  -d '{"body":"this note is about to disappear"}'
kill %1

kubectl delete pod -n notes-platform -l app.kubernetes.io/name=postgres
kubectl rollout status deployment/postgres -n notes-platform
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c 'SELECT count(*) FROM notes'
```

▸ **Expected output:** `2` — the seed rows, recreated on a brand-new empty data
directory. Your note is gone.

**Attempt 1 — emptyDir:**

```bash
kubectl apply -f manifests/07-storage/01-postgres-deployment-emptydir.yaml
kubectl rollout status deployment/postgres -n notes-platform
```

▸ Survives a **container** restart, not a **pod** deletion. §8 of the stage
README walks both.

**The exhibits — a static PV, its claim, and a second StorageClass:**

```bash
kubectl apply -f manifests/07-storage/02-hostpath-persistentvolume.yaml
kubectl get pv notes-hostpath-demo                       # Available
kubectl apply -f manifests/07-storage/03-hostpath-persistentvolumeclaim.yaml
sleep 2
kubectl get pv,pvc -n notes-platform                     # both Bound
kubectl apply -f manifests/07-storage/04-storageclass.yaml
kubectl get storageclass
```

▸ **What it does:** shows the PV/PVC handshake with nothing automated, then a
second class so you can compare `Retain` against the default `Delete`.

**The real thing — a dynamically provisioned volume:**

```bash
kubectl apply -f manifests/07-storage/05-postgres-data-persistentvolumeclaim.yaml
kubectl get pvc postgres-data -n notes-platform
kubectl describe pvc postgres-data -n notes-platform | tail -3
```

▸ **Expected output:** `Pending`, with
`waiting for first consumer to be created before binding`. **That is correct**,
not broken — `WaitForFirstConsumer` provisions on the node the pod lands on.

```bash
kubectl apply -f manifests/07-storage/06-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n notes-platform
kubectl get pvc,pv -n notes-platform
```

▸ **Expected output:** `Bound`, to an automatically created `pvc-…` volume.

**Prove it persists:**

```bash
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c "INSERT INTO notes (body) VALUES ('survives pod deletion')"
kubectl delete pod -n notes-platform -l app.kubernetes.io/name=postgres
kubectl rollout status deployment/postgres -n notes-platform
kubectl exec deployment/postgres -n notes-platform -- \
  psql -U notes -d notes -c 'SELECT id, body FROM notes ORDER BY id'
```

▸ **Expected output:** three rows, and **no duplicated seed rows** — `init.sql`
did not run, because the data directory was no longer empty.

**Tidy the exhibits away:**

```bash
kubectl delete -f manifests/07-storage/03-hostpath-persistentvolumeclaim.yaml
kubectl delete -f manifests/07-storage/02-hostpath-persistentvolume.yaml
```

## 3.7 — StatefulSet (stage 08)

📖 [`manifests/08-statefulsets/README.md`](../manifests/08-statefulsets/README.md)

```bash
kubectl delete deployment postgres -n notes-platform
kubectl apply -f manifests/08-statefulsets/01-postgres-headless-service.yaml
kubectl apply -f manifests/08-statefulsets/02-postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
kubectl get statefulset,pods,pvc -n notes-platform
```

▸ **What it does:** replaces the Deployment with a StatefulSet. **Delete the
Deployment first** — both create pods with the same labels, and running both
gives you two databases behind one Service.

▸ **Expected output:** a pod named exactly `postgres-0`, and a PVC named
`postgres-data-postgres-0` — `<template>-<statefulset>-<ordinal>`.

▸ **Note:** the StatefulSet creates its **own** claim, so notes written to the
stage 07 volume stay behind in the orphaned `postgres-data` PVC. That is a real
property of the model, not a lesson artefact; a genuine migration would be
`pg_dump`/`pg_restore` or a volume snapshot.

```bash
kubectl delete pvc postgres-data -n notes-platform    # the orphaned stage 07 claim
```

▸ **Confirm the identity guarantee:**

```bash
kubectl delete pod postgres-0 -n notes-platform
kubectl wait --for=condition=Ready pod/postgres-0 -n notes-platform --timeout=180s
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -n notes-platform -- \
  nslookup postgres-0.postgres-headless.notes-platform.svc.cluster.local
```

▸ **Expected output:** the pod returns as `postgres-0` (same name, new IP), and
the per-pod DNS name resolves.

▸ **If it fails:** NXDOMAIN means `serviceName` does not match the headless
Service's name, or the Service is not headless (`clusterIP: None`).

## 3.8 — Ingress (stage 09)

📖 [`manifests/09-ingress/README.md`](../manifests/09-ingress/README.md)

```bash
kubectl get ingressclass                                  # installed in step 1.3
kubectl apply -f manifests/09-ingress/02-notes-ingress.yaml
kubectl get ingress -n notes-platform
kubectl describe ingress notes-ingress -n notes-platform
```

▸ **What it does:** creates the HTTP routing rules. `describe` shows the
resolved backends — **they must list pod IPs**.

▸ **Expected output:** `CLASS: nginx`, `ADDRESS: localhost`, and both rules
resolving to endpoints.

▸ **If it fails:** an empty `ADDRESS` after a minute means no controller adopted
it — check `kubectl get ingressclass` and `spec.ingressClassName`.

```bash
echo "127.0.0.1 notes.local" | sudo tee -a /etc/hosts
curl -s http://notes.local/api/notes | head -c 120; echo
```

▸ **No sudo?** The controller matches the `Host` header, so DNS is optional:

```bash
curl -s -H 'Host: notes.local' http://localhost/api/notes | head -c 120; echo
```

▸ **If it fails:** `Connection refused` on port 80 means the cluster was not
created from `clusters/kind-ingress.yaml`. `404` means no rule matched your Host
header. `503` means the rule matched but the backend has no ready endpoints.

## 3.9 — NodePort and LoadBalancer (stage 10)

📖 [`manifests/10-loadbalancer/README.md`](../manifests/10-loadbalancer/README.md)

```bash
kubectl apply -f manifests/10-loadbalancer/01-notes-web-nodeport.yaml
kubectl apply -f manifests/10-loadbalancer/02-notes-web-loadbalancer.yaml
kubectl get svc -n notes-platform
```

▸ **Expected output:** `notes-web-lb` shows `EXTERNAL-IP: <pending>` — **correct
on Kind**, because no cloud controller manager exists to fulfil the request — and
`80:31544/TCP`, proving a LoadBalancer includes a NodePort.

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
docker exec kubernetes-lab-control-plane curl -s -o /dev/null -w '%{http_code}\n' "http://${NODE_IP}:30080/"
```

▸ **What it does:** reaches the NodePort from inside the Kind network, since the
node's IP is only routable within Docker.

▸ **Expected output:** `200`.

## 3.10 — Probes and the init container (stage 11)

📖 [`manifests/11-health-checks/README.md`](../manifests/11-health-checks/README.md)

```bash
kubectl apply -f manifests/11-health-checks/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n notes-platform --timeout=300s
kubectl apply -f manifests/11-health-checks/notes-api-deployment.yaml
kubectl apply -f manifests/11-health-checks/notes-web-deployment.yaml
kubectl rollout status deployment/notes-api -n notes-platform
kubectl rollout status deployment/notes-web -n notes-platform

kubectl describe pod -n notes-platform -l app.kubernetes.io/name=notes-api \
  | grep -E 'Liveness|Readiness|Startup'
```

▸ **What it does:** adds the init container and the three probes. The `grep`
prints all three probe definitions with their thresholds — read them back as
sentences.

▸ **Watch the init container do real work:**

```bash
kubectl scale statefulset/postgres --replicas=0 -n notes-platform
kubectl rollout restart deployment/notes-api -n notes-platform
kubectl get pods -n notes-platform -l app.kubernetes.io/name=notes-api
kubectl logs -n notes-platform -l app.kubernetes.io/name=notes-api -c wait-for-postgres --tail=3
kubectl scale statefulset/postgres --replicas=1 -n notes-platform
kubectl rollout status deployment/notes-api -n notes-platform
```

▸ **Expected output:** `Init:0/1` and `waiting for postgres…:5432` — **not**
`CrashLoopBackOff`. The `-c` flag is required to read an init container's logs.

## 3.11 — The combined manifest (stage 19)

📖 [`manifests/19-final/README.md`](../manifests/19-final/README.md)

```bash
kubectl kustomize manifests/19-final/            # preview BEFORE applying
kubectl apply -k manifests/19-final/
kubectl apply -k manifests/19-final/             # again — everything "unchanged"
```

▸ **What it does:** `kubectl kustomize` renders the result; `-k` renders and
applies. Running it twice shows convergence — `apply` sends a patch only where
the live object genuinely differs.

▸ **Expected output:** the second run prints `unchanged` on every line.

▸ **If it fails:** *"field is immutable"* on a selector means someone set
`includeSelectors: true` in the kustomization.

---

# Part 4 — Validate

Everything `validate.sh` asserts, by hand.

## Step 4.1 — Everything exists

```bash
kubectl get all,pvc,ingress,configmap,secret -n notes-platform
```

▸ **Expected output:** 1 StatefulSet (`1/1`), 2 Deployments (`2/2` each), 5 pods
`Running`, 6 Services, 1 PVC `Bound`, 1 Ingress.

▸ **Note `get all` is a lie** — it omits ConfigMaps, Secrets, PVCs and Ingresses,
which is why they are listed explicitly here.

## Step 4.2 — Every pod is Ready, not merely Running

```bash
kubectl get pods -n notes-platform \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

▸ **What it does:** prints the `Ready` **condition**, not the phase. `Running`
means the process started; `Ready` means a probe said it can serve.

▸ **Expected output:** `True` on every line.

▸ **If it fails:** `0/1 Running` is a readiness failure —
`kubectl describe pod <pod> -n notes-platform | grep -A5 Events`.

## Step 4.3 — Storage is bound

```bash
kubectl get pvc -n notes-platform
kubectl describe pvc postgres-data-postgres-0 -n notes-platform | tail -5
```

▸ **Expected output:** `Bound`, with a `volumeName` of `pvc-…`.

▸ **If it fails:** `Pending` **after** the pod exists means no StorageClass, an
unsatisfiable size or access mode, or no provisioner running. The reason is in
`describe`, never in `get`.

## Step 4.4 — Services have endpoints

```bash
for svc in postgres postgres-headless notes-api notes-web; do
  echo -n "$svc: "
  kubectl get endpointslices -n notes-platform \
    -l "kubernetes.io/service-name=${svc}" \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}'
  echo
done
```

▸ **What it does:** the label `kubernetes.io/service-name` is how EndpointSlices
are linked to their Service. Empty output is the most common silent failure in
Kubernetes.

▸ **Expected output:** pod IPs on every line.

## Step 4.5 — The data really is in PostgreSQL

```bash
kubectl exec statefulset/postgres -n notes-platform -- \
  psql -U notes -d notes -c 'SELECT count(*) FROM notes'
```

▸ **What it does:** proves the whole chain — the pod is up, the password from the
Secret works, the volume is mounted, and the seed script ran.

▸ **If it fails:** *"password authentication failed"* means the Secret and the
initialised database disagree (failure lab 6).

## Step 4.6 — The application answers, from inside the cluster

```bash
kubectl run validate-curl --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 -n notes-platform -- \
  curl -fsS -m 10 http://notes-web.notes-platform.svc.cluster.local/api/notes
```

▸ **What it does:** runs a throwaway pod inside the cluster so the request
exercises CoreDNS, the Services, the EndpointSlices and all three tiers. `--rm`
deletes it afterwards; `-f` makes curl exit non-zero on an HTTP error.

▸ **Expected output:** a JSON array of notes.

## Step 4.7 — The Ingress answers from outside

```bash
curl -fsS -H 'Host: notes.local' http://localhost/api/notes | head -c 120; echo
curl -s -o /dev/null -w 'ui: %{http_code}\n' -H 'Host: notes.local' http://localhost/
```

▸ **Expected output:** JSON, then `ui: 200`.

▸ **If it fails:** see the 404 / 502 / 503 table in
[stage 09 §9](../manifests/09-ingress/README.md).

## Step 4.8 — Use it in a browser

```bash
open http://notes.local        # macOS; xdg-open on Linux
```

▸ Add a note. Refresh a few times and watch the **served by pod** line change as
the ingress controller balances across API replicas — while the note list stays
identical, because all of them read the same database. **That contrast with
Project 01, where every replica had its own in-memory list, is the point of this
project.**

## Step 4.9 — Debug fallback: bypass everything

```bash
kubectl port-forward statefulset/postgres 5432:5432 -n notes-platform &
sleep 2
PGPASSWORD='dev-password-not-for-production' psql -h 127.0.0.1 -U notes -d notes -c 'SELECT * FROM notes'
kill %1
```

▸ **What it does:** tunnels straight to the database pod through the API server,
skipping the Ingress, the Services and both application tiers. If this works and
the UI does not, the problem is above the database. (Needs a local `psql`; if you
do not have one, use `kubectl exec` as in step 4.5.)

---

# Part 5 — Cleanup

## Step 5.1 — Delete the namespace

```bash
kubectl delete namespace notes-platform --wait=true
```

▸ **What it does:** the namespace controller enumerates every namespaced resource
type and deletes what it finds — pods, Services, ConfigMaps, the Secret, the
Ingress, **and the PVCs**. Deletion is asynchronous; `--wait=true` blocks until it
is finished.

▸ **Expected output:** `namespace "notes-platform" deleted` after a few seconds.

▸ **If it hangs:** something has a finalizer that is not completing.

```bash
kubectl get namespace notes-platform -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## Step 5.2 — Delete the cluster-scoped objects

```bash
kubectl delete persistentvolume notes-hostpath-demo --ignore-not-found
kubectl delete storageclass notes-platform-retain --ignore-not-found
```

▸ **What it does:** namespaces do not contain these. **This project is the first
one in the repository that leaves cluster-scoped debris**, which is why the habit
matters from here on.

▸ `--ignore-not-found` makes the command idempotent — no error if you already
deleted them.

## Step 5.3 — Check for orphaned volumes

```bash
kubectl get pv
```

▸ **What it does:** PVs created by the `standard` class have
`reclaimPolicy: Delete` and vanish with their claims. Anything from a `Retain`
class stays in phase **`Released`**, holding disk, forever.

▸ **Expected output:** `No resources found`.

▸ **If any remain:**

```bash
kubectl delete pv <name>
```

▸ On a cloud this is not a tidiness matter — orphaned volumes are a line on your
bill every month.

## Step 5.4 — Optional: remove the ingress controller

```bash
kubectl delete namespace ingress-nginx
```

▸ **Only if you are finished with it.** It is cluster software shared by later
projects, which is why `cleanup.sh` leaves it running.

## Step 5.5 — Nuclear option

```bash
kind delete cluster --name kubernetes-lab
docker rmi notes-api:1.0.0 notes-web:1.0.0
```

▸ Removes the cluster entirely, images and all. Rebuilding takes about a minute
— which is the point of a disposable cluster.

---

# Command reference used in this project

| Command | What it does |
|---|---|
| `kubectl apply -f <file>` | Declarative create-or-update; idempotent |
| `kubectl apply -k <dir>` | The same, through a kustomization |
| `kubectl kustomize <dir>` | Render a kustomization without applying |
| `kubectl get <kind> -o wide` | Adds IP and node columns |
| `kubectl get <kind> -o jsonpath='{…}'` | Extract one field, script-friendly |
| `kubectl describe <kind> <name>` | Full state **plus the Events** — read the bottom first |
| `kubectl logs <pod> [-c <container>]` | Container logs; `-c` is required for init containers |
| `kubectl logs --previous` | The **crashed** container's logs, not the running one |
| `kubectl exec <pod> -- <cmd>` | Run a command inside a container |
| `kubectl port-forward <res> <local>:<remote>` | Tunnel to a pod or Service through the API server |
| `kubectl rollout status <kind>/<name>` | Block until a rollout completes |
| `kubectl rollout restart <kind>/<name>` | Restart pods via a template annotation — a normal rolling update |
| `kubectl scale <kind>/<name> --replicas=N` | Change the replica count |
| `kubectl set env <kind>/<name> K=V` | Imperatively patch an env var |
| `kubectl patch <kind> <name> -p '{…}'` | Targeted update; `--type=json` for precise paths |
| `kubectl wait --for=condition=Ready pod/<name>` | Block until a condition holds |
| `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | A Service's real backend set |
| `kubectl get events --sort-by=.lastTimestamp` | Recent cluster events, newest last |
| `kubectl api-resources --namespaced=false` | Which kinds are cluster-scoped |
| `kubectl auth can-i <verb> <resource>` | Check RBAC, optionally `--as` another identity |
| `kubectl run <name> --rm -it --image=<img> -- <cmd>` | Throwaway debug pod |
| `kubectl delete namespace <ns>` | Delete everything namespaced in one command |
| `kind load docker-image <img> --name <cluster>` | Copy a local image into the cluster's nodes |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Stage 19 — Final](../manifests/19-final/README.md)** | [Project 02](../README.md) | **[Failure labs](../failure-labs/labs.md)** ▶ |
