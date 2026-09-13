# Stage 19 — The Complete Manifest, with generated ConfigMaps

[⬅ Project 03](../../README.md) · Stage 10 of 10

[00 Namespace](../00-namespace/README.md) › [03 Deployments](../03-deployments/README.md) › [04 Services](../04-services/README.md) › [05 ConfigMaps](../05-configmaps/README.md) › [06 Secrets](../06-secrets/README.md) › [07 Storage](../07-storage/README.md) › [08 StatefulSets](../08-statefulsets/README.md) › [09 Ingress](../09-ingress/README.md) › [11 Probes](../11-health-checks/README.md) › **19 Final**

> **The problem:** the working platform is spread across nine directories. `shortener-api` is stage 11 on top of
> 08, 06 and 05; Redis is stage 11 but its config is 05; the Ingress is 09 plus an annotation typed by hand. And
> three ConfigMaps are versioned by names *you* invented (`-v1`, `-v2`) with a checksum *you* computed. Rebuilding
> it means knowing which file wins — and remembering to bump a version and a hash on the next change.

---

## 1. WHY combine now (and why generate config)?

| | Teaching stages | Operating |
|---|---|---|
| Files | One resource per file, one idea per stage | One desired state |
| Order | The order is the lesson | Order must not matter |
| Superseded versions | Kept, so you can see the change | Gone, so nothing is ambiguous |
| Config versions | Named by hand: `-v1`, `-v2`, `checksum/config` | **Generated from content** |

Stage 05 proved that a config change must be (a) an immutable object and (b) a pod-template change. Doing that by
hand is exactly the kind of step that gets forgotten on the fifth change. A **Kustomize `configMapGenerator`**
makes it automatic.

---

## 2. WHAT is Kustomize (and a configMapGenerator)?

**Kustomize** is built into `kubectl` (`-k`). It loads plain, valid YAML and applies transformations — labels, image
tags, patches — without templates.

A **configMapGenerator** builds ConfigMaps from files and does three things you did by hand in stage 05:

| Stage 05, by hand | Generator, automatically |
|---|---|
| Invent `shortener-config-v2` | Name = `shortener-config-` + **hash of the content** (`shortener-config-6229k6fc48`) |
| `immutable: true` | `generatorOptions.immutable: true` |
| Edit every Deployment to reference `-v2` | **Rewrites every reference** (envFrom, configMapKeyRef, volumes) to the hashed name |
| Compute `sha256` for `checksum/config` | Not needed — a changed file is a changed *name*, which is a changed pod template |

> **Analogy:** instead of printing "edition 2" on a laminated sheet and walking round telling everyone, the sheet's
> title *is* a fingerprint of its text. Change a word and it is automatically a different sheet — and every worker's
> instructions already name the new one.

---

## 3. HOW does it work here?

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - complete-production-manifest.yaml

generatorOptions:
  immutable: true

configMapGenerator:
  - name: shortener-config
    namespace: url-shortener
    envs:
      - config/shortener.env        # KEY=VALUE per line
  - name: redis-config
    namespace: url-shortener
    files:
      - config/redis.conf           # one key named redis.conf

labels:
  - pairs:
      app.kubernetes.io/managed-by: kustomize
    includeSelectors: false

images:
  - name: cloudprakhargupta/url-shortener
    newName: cloudprakhargupta/url-shortener
  - name: postgres
    newTag: "17.5-alpine"
  - name: redis
    newTag: "8.2.9-alpine"
```

| Field | What it does | What breaks if it's wrong |
|---|---|---|
| *(no top-level `namespace:`)* | Objects keep their own namespaces | Setting it moves the analytics collector into `url-shortener` and breaks the ExternalName target |
| `configMapGenerator[].namespace` | The generated ConfigMap's namespace | Omitted ⇒ generated without namespace ⇒ lands in your current context's namespace |
| `envs` | `KEY=VALUE` file → keys | A line without `=` is rejected at build time |
| `files` | File → one key named after the file | — |
| `generatorOptions.immutable` | Every generated ConfigMap immutable | — |
| `labels.includeSelectors: false` | Label objects, not selectors | `true` rewrites **immutable** selectors; every later apply fails |
| `images` | Retarget registries/tags | Change `newName` to publish from ECR — never edit the manifest |

### What is in the manifest, and what is not

| In `complete-production-manifest.yaml` | Deliberately absent |
|---|---|
| 2 Namespaces (with the readiness-gate label) | Mutable `shortener-config`, `-v1`, `-v2` — replaced by generated ConfigMaps |
| StorageClass `url-shortener-gp3` | `checksum/config` annotations — the hashed name does the job |
| 2 Secrets | Stand-alone `postgres-data`/`redis-data` PVCs — claim templates own storage |
| 8 Services (4 ClusterIP, 2 headless, 1 ExternalName, collector) | Deployment versions of both datastores |
| 2 StatefulSets, 3 Deployments | The load balancer controller — cluster software with its own lifecycle |
| 1 Ingress | |

> ⚠️ **This manifest is only valid through Kustomize.** `kubectl apply -f complete-production-manifest.yaml` alone
> creates workloads that reference ConfigMaps named `shortener-config` and `redis-config`, which do not exist —
> every pod sits in `CreateContainerConfigError`.

---

## 4. Apply

```bash
kubectl kustomize manifests/19-final/ | less          # ALWAYS look first

MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ \
  | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32#" \
  | kubectl apply -f -
```

▸ **Why not plain `kubectl apply -k`?** It would reset `inbound-cidrs` to `0.0.0.0/0` — the value in Git, because
your IP does not belong in Git. Rendering, substituting and piping keeps one source of truth *and* a per-operator
value. (A real repository would carry an overlay per environment with the CIDR in it.) `scripts/deploy.sh` does
exactly these three steps.

Applied over the stage 11 state, this **rolls every workload** once — their ConfigMap references changed from
`shortener-config-v2` to `shortener-config-6229k6fc48`. Afterwards the hand-versioned ConfigMaps have no consumers:

```bash
kubectl delete configmap shortener-config-v1 shortener-config-v2 redis-config -n url-shortener
```

---

## 5. Validate

```bash
./scripts/validate.sh
kubectl get configmaps -n url-shortener
kubectl get deployment shortener-api -n url-shortener -o jsonpath='{.spec.template.spec.containers[0].envFrom}{"\n"}'
```

```
NAME                          DATA   AGE
kube-root-ca.crt              1      30m
redis-config-mm468kgbth       1      5m
shortener-config-6229k6fc48   15     5m

[{"configMapRef":{"name":"shortener-config-6229k6fc48"}}]
```

```bash
curl -s "http://$ALB/api/info" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["config_version"], d["redis_write"]["host"], d["redis_write"]["role"])'
```

```
final redis-0.redis-headless.url-shortener.svc.cluster.local master
```

---

## 6. Observe

### A config change is a rollout — with no hand-written version

```bash
sed -i 's/^CACHE_TTL_SECONDS=300/CACHE_TTL_SECONDS=600/' manifests/19-final/config/shortener.env
kubectl kustomize manifests/19-final/ | grep -m1 'name: shortener-config-'
```

▸ A **different** hash. Apply it (§4) and `shortener-api`, `shortener-web` and `postgres` roll — they reference the
new name. Redis does not, because `redis.conf` did not change. Put the value back and apply again: the hash returns
to `6229k6fc48`, and that ConfigMap still exists, so **`kubectl rollout undo` would have restored it too**.

### Applying twice converges

```bash
kubectl get statefulset postgres redis -n url-shortener -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.generation} {end}{"\n"}'
# apply again (§4)
kubectl get statefulset postgres redis -n url-shortener -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.generation} {end}{"\n"}'
```

▸ Measured: most lines print `unchanged`; the two Secrets and two StatefulSets print `configured`. **Nothing
actually changed** — the generation numbers are identical, no pod restarted, and `kubectl diff` over the same input
is empty. The `configured` lines are client-side apply comparing its `last-applied` annotation with fields the API
server fills in (`stringData` is folded into `data`; claim templates get defaults). `generation` and `kubectl diff`
are the honest tests; the `apply` summary is not.

### Drift is corrected by applying

```bash
kubectl scale deployment/shortener-api -n url-shortener --replicas=5
# apply again (§4)
kubectl get deployment shortener-api -n url-shortener
```

▸ Back to `2/2`. Re-applying the desired state *is* the drift repair — the idea a GitOps controller automates
(Project 10).

---

## 7. Production notes

> 🧪 **DEMO / LEARNING CONFIGURATION**
> Secrets in Git, one environment, a `sed` for the CIDR, Docker Hub images, manual `kubectl apply`.

> 🏭 **PRODUCTION CONSIDERATIONS**
> - **Base + overlays** (`dev`, `staging`, `prod`), each supplying its own config env file, CIDRs, replica counts
>   and image tags. The `sed` becomes an overlay patch.
> - **Secrets out of this repository** — External Secrets Operator pulling from AWS Secrets Manager.
> - **Images from ECR, pinned by digest** in the prod overlay (`images[].digest`).
> - **`kubectl diff -k` in CI**, and a GitOps controller (Argo CD, Flux) doing the apply with pruning (Project 10).
> - **Prune old generated ConfigMaps** — but keep as many as `revisionHistoryLimit`, or `rollout undo` points at a
>   deleted ConfigMap.
> - **Server-side apply** (`kubectl apply --server-side`) avoids most of the `configured` noise above and gives
>   per-field ownership.

---

## 8. The next problem

You can run a two-datastore application on EKS, explain every DNS name it resolves, give each replica of a
replicated store its own disk and identity, keep configuration from drifting, and put an ALB in front of it.

Everything here is still **one** application with **one** API. What you have not faced:

- Five services calling each other — `catalog`, `cart`, `order`, `payment` — where "any pod can reach any pod"
  stops being acceptable. Today any pod in the cluster can connect to this PostgreSQL.
- One entry point routing by **path and host** for many teams' services.
- A failure in one service cascading into all the others.

That is Project 04: e-commerce microservices, east-west traffic, and NetworkPolicy.

---

## 📚 Official documentation

Everything above is self-contained — these are for going deeper, not for filling gaps.
*(All links verified 2026-09-13.)*

| Reference | What it adds |
|---|---|
| [Declarative management with Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) | Generators, name-suffix hashing, bases and overlays |
| [configMapGenerator reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/) | Every generator field, including `namespace` and options |
| [ConfigMaps — immutable](https://kubernetes.io/docs/concepts/configuration/configmap/) | Why immutable ConfigMaps pair naturally with hashed names |
| [kubectl rollout](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/) | `history` and `undo` across config versions |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[11 Probes](../11-health-checks/README.md)** | [Project 03](../../README.md) · [Manual steps](../../scripts/manual-steps.md) | **[Project 04 →](../../../docs/ROADMAP.md#project-04--e-commerce-microservices)** ▶ |
