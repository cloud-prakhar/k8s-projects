# Stage 19 — The Complete Manifest

[⬅ Project 02](../../README.md) · Stage 11 of 11

[00 Namespace](../00-namespace/README.md) › [03 Deployments](../03-deployments/README.md) › [04 Services](../04-services/README.md) › [05 ConfigMaps](../05-configmaps/README.md) › [06 Secrets](../06-secrets/README.md) › [07 Storage](../07-storage/README.md) › [08 StatefulSets](../08-statefulsets/README.md) › [09 Ingress](../09-ingress/README.md) › [10 LoadBalancer](../10-loadbalancer/README.md) › [11 Probes](../11-health-checks/README.md) › **19 Final**

> **The problem:** the final state of this platform is spread across seven
> directories. `notes-api` is a merge of stages 03, 05, 06 and 11; the database
> is a merge of 08 and 11; and three of the files you applied along the way were
> superseded or were teaching exhibits. Rebuilding this cluster means knowing
> which file wins, and in which order.

---

## 1. WHY combine now (and not earlier)?

Teaching and operating want opposite things from a manifest.

| | Teaching stages | Operating |
|---|---|---|
| Files | One resource per file, one idea per stage | One desired state |
| Order | The order is the lesson | Order must not matter |
| Superseded versions | Kept, so you can see the diff | Deleted, so there is no ambiguity |

Combining earlier would have hidden the failures. Not combining at all leaves you
with a directory tree only its author can apply.

**What this file gives you:** apply it against an empty cluster, a
half-configured one, or one that is already correct, and you converge to the same
place. That is what "declarative" means in practice, and it is the property CI/CD
and GitOps are built on (Project 10).

---

## 2. WHAT is Kustomize?

**Kustomize** is a template-free customisation tool built into `kubectl` (`-k`).
It takes plain, valid YAML and applies **transformations** — set a namespace,
add labels, pin image tags, patch fields, change replica counts — without the
original file containing a single placeholder.

> **Analogy:** a stencil laid over a finished drawing, not a fill-in-the-blanks
> form. The base manifest is a complete, applyable document on its own.
>
> **Technically:** `kubectl kustomize` reads `kustomization.yaml`, loads the
> `resources`, applies the transformers, and prints the result. Nothing is
> rendered by string substitution, so the base can never become invalid YAML.

| Kustomize | Helm |
|---|---|
| Overlays on valid YAML | Go templates rendered into YAML |
| Built into `kubectl` | A separate binary and a release lifecycle |
| Great for "the same app, three environments" | Great for "a packaged app other people install" |

Project 10 uses both, properly, with base/overlay directories per environment.

---

## 3. HOW does it work here?

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: notes-platform

resources:
  - complete-production-manifest.yaml

labels:
  - pairs:
      app.kubernetes.io/managed-by: kustomize
    includeSelectors: false      # ⚠️ never true — see below

images:
  - name: notes-api
    newTag: "1.0.0"
  - name: notes-web
    newTag: "1.0.0"
  - name: postgres
    newTag: "17.5-alpine"
```

| Field | What it does |
|---|---|
| `namespace` | Stamps the namespace onto every resource, so the base does not have to repeat it |
| `resources` | The files to load. **Only paths at or below this directory** — Kustomize refuses `../` on purpose, so a kustomization is self-contained and can be vendored |
| `labels` | Adds labels to every object |
| `includeSelectors: false` | **Critical.** `true` would also rewrite `spec.selector.matchLabels` — which is **immutable** on Deployments and StatefulSets, so every future `apply` would be rejected |
| `images` | Rewrites image tags without editing the manifest. This is the field a CI pipeline or an environment overlay overrides |

### What is deliberately not in the combined manifest

| Left out | Why |
|---|---|
| `07-storage/01-…-emptydir.yaml` | Superseded — it loses data |
| `02-hostpath-persistentvolume.yaml`, `03-…-claim.yaml` | Exhibits, and `hostPath` must never reach a real cluster |
| `04-storageclass.yaml` | A comparison exhibit, and cluster-scoped |
| `05-postgres-data-persistentvolumeclaim.yaml` | The StatefulSet's `volumeClaimTemplate` creates its own claim |
| `10-loadbalancer/*` | The Ingress is the real front door; those showed what sits underneath |
| `09-ingress/01-ingressclass-reference.yaml` | Installed with the controller — infrastructure, not application |

Twelve documents remain: Namespace, 2 ConfigMaps, 1 Secret, 4 Services, 1
StatefulSet, 2 Deployments, 1 Ingress.

> **Prerequisite:** the NGINX Ingress Controller must already be installed, or
> the Ingress is created successfully and routes nothing. It is cluster software
> with its own lifecycle, which is exactly why it is not in this file.

---

## 4. Apply

```bash
# See exactly what would be sent — do this before EVERY apply
kubectl kustomize manifests/19-final/

# Apply it
kubectl apply -k manifests/19-final/
```

▸ **What `-k` does:** runs the kustomize build and pipes the result to `apply`.
`kubectl apply -f manifests/19-final/complete-production-manifest.yaml` works too
and skips the transformations.

▸ **Order within the file matters only once:** the Namespace is the first
document, because the API server processes a multi-document file in order and
everything after it is namespaced.

---

## 5. Validate

```bash
kubectl apply -k manifests/19-final/
./scripts/validate.sh
```

```bash
kubectl get all,pvc,ingress,configmap,secret -n notes-platform
```

| Check | Expected |
|---|---|
| `statefulset/postgres` | `1/1` |
| `deployment/notes-api`, `notes-web` | `2/2` each |
| `pvc/postgres-data-postgres-0` | `Bound` |
| `ingress/notes-ingress` | `ADDRESS` populated |
| `curl -H 'Host: notes.local' http://localhost/api/notes` | JSON array of notes |

---

## 6. Observe

### Applying it again changes nothing

```bash
kubectl apply -k manifests/19-final/
```

```
namespace/notes-platform unchanged
configmap/notes-config unchanged
statefulset.apps/postgres unchanged
deployment.apps/notes-api unchanged
…
```

▸ `unchanged` on every line. `apply` compares your manifest, the live object and
the last-applied annotation, and sends a patch only for real differences. **This
is why a scheduled `apply` is safe** — and it is the whole idea behind a GitOps
reconcile loop.

### The transformations are visible in the output

```bash
kubectl kustomize manifests/19-final/ | grep -E 'managed-by|image:'
```

▸ `app.kubernetes.io/managed-by: kustomize` on every object, and pinned image
tags — none of which appear in `complete-production-manifest.yaml`.

### Prove it converges from a broken state

```bash
kubectl scale deployment/notes-api --replicas=7 -n notes-platform
kubectl delete configmap notes-config -n notes-platform
kubectl apply -k manifests/19-final/
kubectl get deployment notes-api -n notes-platform
kubectl get configmap notes-config -n notes-platform
```

▸ Back to 2 replicas, ConfigMap restored, without you diagnosing anything. Drift
correction *is* the apply.

### Where a real repository would go next

```bash
# base/ + overlays/dev + overlays/prod, each with a kustomization.yaml
# overlays/prod/kustomization.yaml would carry:
#   replicas: [{name: notes-api, count: 6}]
#   patches:  [{path: resources-patch.yaml}]
```

Project 10 builds exactly that, and puts a GitOps controller in front of it.

---

## 7. Production notes

> 🧪 **DEMO / LEARNING CONFIGURATION**
> A Secret committed to Git, one environment, `local-path` storage, no TLS, no
> resource limits, and a single-instance database.

> 🏭 **PRODUCTION CONSIDERATIONS**
> - **The Secret does not belong in this file.** Use External Secrets, Sealed
>   Secrets or SOPS so what is committed is a *reference*, not a credential.
> - Base + overlays per environment. Never maintain parallel copies of a
>   manifest by hand.
> - `kubectl diff -k` in CI on every pull request, so reviewers see the *effect*
>   of a change rather than the YAML diff.
> - Pin images by **digest** in production overlays; tags are mutable.
> - `--prune` (or a GitOps controller) so deleting a resource from Git actually
>   deletes it from the cluster. Without it, removed objects linger forever.
> - Keep cluster-scoped infrastructure — ingress controllers, StorageClasses,
>   CRDs — in a separate repository or root application with its own review
>   rules. It has a different blast radius and a different audience.
> - Add the pieces this project deliberately postponed: resource limits and HPA
>   (Project 05), NetworkPolicy and RBAC (Projects 04, 07), PDBs and anti-affinity
>   (Project 09), TLS and real DNS (Project 10).

---

## 8. The next problem

You can now build a three-tier, stateful, externally-reachable application from
one file, and you understand every object in it.

What you cannot yet do is answer these:

- The API opens a **new database connection per request**, and every one of them
  re-resolves DNS. What does that cost, and what would a cache in front of the
  database change?
- Two datastores with genuinely different jobs — a durable one and a fast one —
  need different storage, different scaling and different failure behaviour. How
  do you address **one specific member** of a replicated cache?
- Config that must never change silently under a running fleet needs
  `immutable: true` and a rollout that is triggered *by the change itself*.

That is Project 03: a URL shortener with PostgreSQL **and** Redis, per-pod DNS
for a real StatefulSet cluster, immutable ConfigMaps, and `checksum/config`
rollout triggers.

---

## 📚 Official documentation

Everything above is self-contained — these are for going deeper, not for filling gaps.
*(All links verified 2026-08-28.)*

| Reference | What it adds |
|---|---|
| [Declarative management with Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) | Every transformer, bases and overlays, generators |
| [Kustomization file reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/) | The complete field list, including `labels` vs the older `commonLabels` |
| [Managing workloads](https://kubernetes.io/docs/concepts/cluster-administration/manage-deployment/) | Bulk apply, organising manifests, `--prune` |
| [Objects in Kubernetes](https://kubernetes.io/docs/concepts/overview/working-with-objects/) | Desired state, `apply` semantics, the last-applied annotation |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[11 Probes](../11-health-checks/README.md)** | [Project 02](../../README.md) · [Manual steps](../../scripts/manual-steps.md) | **[Project 03 →](../../../docs/ROADMAP.md#project-03--url-shortener)** ▶ |
