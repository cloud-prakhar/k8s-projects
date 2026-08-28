# Stage 19 — The Complete Manifest

[⬅ Project 01](../../README.md) · Stage 9 of 9

[00 Namespace](../00-namespace/README.md) › [01 Pods](../01-pods/README.md) › [02 ReplicaSets](../02-replicasets/README.md) › [03 Deployments](../03-deployments/README.md) › [04 Services](../04-services/README.md) › [05 ConfigMaps](../05-configmaps/README.md) › [06 Secrets](../06-secrets/README.md) › [11 Probes](../11-health-checks/README.md) › **19 Final**


> **The problem:** the true desired state of `task-api` now lives in *three* places — the ConfigMap wiring from
> stage 05, the Secret wiring from stage 06, and the probes from stage 11. Applying stages in the wrong order gives
> you a different cluster. That is fine for learning and unacceptable for operating.

---

## 1. WHY combine now (and not earlier)?

Numbered stages exist so each resource arrives with the problem it solves. Once you understand them, that layout has
two operational flaws:

| Flaw | Consequence |
|---|---|
| Apply order matters | Applying `03-deployments` after `11-health-checks` silently removes your probes |
| The same object is defined several times | "What is actually deployed?" has no single answer in Git |

Production wants the opposite: **one declarative description of the end state**, applied in any order, idempotently.

## 2. WHAT is Kustomize?

A template-free way to compose manifests, built into `kubectl` (`-k`). It reads plain YAML, applies transformations
(common labels, name prefixes, image tags, patches), and prints the result. No templating language, no runtime — the
output is ordinary YAML you can inspect.

> **Mental model:** a build step for YAML. It never runs in your cluster; it only produces what gets sent.
> Technically: `kubectl apply -k` renders the kustomization client-side, then POSTs the rendered objects.

Helm is the alternative — templating plus release lifecycle and a package registry. Kustomize is simpler and needs no
extra tooling, which is why it comes first here; Helm arrives in Projects 08 and 10.

## 3. HOW does it work here?

`resources:` lists the final version of each object — the stage-11 Deployments, not the stage-03 ones. Transformers
then stamp labels and pin image tags across all of them.

> ⚠️ `includeSelectors: false` matters. With `true`, Kustomize would inject its labels into
> `spec.selector.matchLabels` — which is **immutable** on a Deployment. Your next `apply` fails with
> `field is immutable`, and the fix is deleting and recreating the Deployment.

## 4. Apply

```bash
# See exactly what would be sent — do this before every apply
kubectl kustomize manifests/19-final/

# Apply it
kubectl apply -k manifests/19-final/
```

## 5. Validate

```bash
kubectl get all -n task-tracker
kubectl get deploy task-api -n task-tracker -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'; echo
kubectl get deploy -n task-tracker -l app.kubernetes.io/managed-by=kustomize
```

Expected: 3 `task-api` + 2 `task-web` Pods `Running` and `1/1 READY`, probes present, both Deployments carrying the
`managed-by=kustomize` label.

## 6. Observe

Applying this after working through stages 00→11 should report mostly `unchanged` — proof that your incremental path
and the combined manifest describe the same cluster.

```bash
kubectl apply -k manifests/19-final/
# deployment.apps/task-api unchanged
```

## 7. Production notes

> 🧪 **DEMO** — one flat kustomization, a Secret committed to Git, images pinned to a tag.

> 🏭 **PRODUCTION** — split into `base/` + `overlays/{dev,staging,prod}` so environments differ only by patch; pin
> images by **digest** (`@sha256:…`); keep Secrets out of Git entirely (External Secrets Operator, Sealed Secrets, or
> a cloud secret manager); and let a GitOps controller apply this rather than a human running `kubectl`.
> Projects 05 and 10 build all of that out.

---

## 📚 Official documentation

Everything above is self-contained — these are for going deeper, not for filling gaps.
*(All links verified 2026-08-09.)*

| Reference | What it adds |
|---|---|
| [Declarative management with Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) | `kubectl apply -k`, generators, transformers |
| [Kustomization file reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/) | Every field, including `labels` and `images` |
| [Declarative object management](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/) | How `apply` computes a three-way merge |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[11 Probes](../11-health-checks/README.md)** | [Project 01](../../README.md) · [Manual steps](../../scripts/manual-steps.md) | **[Project 02 →](../../../project-02-three-tier-notes/README.md)** ▶ |
