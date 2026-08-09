# Stage NN — <Resource Name>

<!-- BREADCRUMB — mandatory, see docs/CONVENTIONS.md §9.1.
     Current stage bold and unlinked; all others linked. Show the WHOLE chain. -->
<!-- Replace with real links once the sibling stage directories exist: -->
`[⬅ Project XX](../../README.md) · Stage N of M`

`[00 Namespace](../00-namespace/README.md) › ... › **NN <This Stage>** › ... › [19 Final](../19-final/README.md)`

<!--
  Copy this file into each manifests/NN-*/ directory as README.md.
  All 10 sections are mandatory and must stay in this order.
  Delete this comment block.
-->

> **Previous stage left us with:** <the failure or limitation the learner just observed>

---

## 1. What Are We Creating?

`<Kind>` — one sentence.

---

## 2. Why Do We Need It?

The **application problem**, in plain language, before any YAML appears.

> Example: "Our frontend needs to call the backend. Right now it uses the Pod IP `10.244.1.7`. Pod IPs are assigned at
> creation and change every time a Pod is recreated — which happens on every crash, every rollout, and every reschedule."

---

## 3. What Happens Without It?

The concrete failure, with the command that shows it and the output the learner will actually see.

```bash
kubectl delete pod <name> -n <ns>
kubectl get pod -n <ns> -o wide     # note the new IP — the frontend is now pointing at nothing
```

---

## 4. Manifest

```yaml
# NN-<topic>/<file>.yaml
# WHY: <one line>
apiVersion: <group/version>
kind: <Kind>
metadata:
  name: <name>
  namespace: <ns>
  labels:
    app.kubernetes.io/name: <name>
    app.kubernetes.io/instance: <name>
    app.kubernetes.io/component: <frontend|backend|database|…>
    app.kubernetes.io/part-of: <project>
    app.kubernetes.io/version: "<x.y.z>"
  annotations:
    kubernetes.io/description: "<what this object is for>"
    lab.k8s-project/stage: "NN-<topic>"
spec: {}
```

---

## 5. Manifest Breakdown

| Field | Value | What it does | What breaks if it's wrong |
|---|---|---|---|
| `apiVersion` | | Which API group/version serves this kind | `no matches for kind` |
| `kind` | | The object type | |
| `metadata.name` | | Cluster-unique within the namespace | |
| `metadata.namespace` | | Where it lives | Object created in `default` and "disappears" |
| `spec.…` | | | |

Explore any field yourself:

```bash
kubectl explain <kind>.spec --recursive | less
```

---

## 6. Apply

```bash
kubectl apply -f manifests/NN-<topic>/<file>.yaml

# See the request the server would accept, without creating anything
kubectl apply -f manifests/NN-<topic>/<file>.yaml --dry-run=server -o yaml
```

---

## 7. Validate

```bash
kubectl get <kind> -n <ns>
kubectl describe <kind>/<name> -n <ns>
```

**What good looks like:**

```
NAME     ...
<name>   ...
```

**Red flags:** <what a broken state prints instead>

---

## 8. Test / Observe

Prove the behaviour rather than trusting it.

```bash
# e.g. delete a Pod and watch the controller replace it
kubectl delete pod <name> -n <ns>
kubectl get pods -n <ns> -w
```

> 🧪 **Try it:** <a small experiment that makes the mechanism visible>

---

## 9. Troubleshooting

| Symptom | Command | Root cause | Fix |
|---|---|---|---|
| | `kubectl describe …` | | |
| | `kubectl logs --previous …` | | |
| | `kubectl get events --sort-by=.lastTimestamp` | | |

---

## 10. Production Notes

> 🧪 **DEMO / LEARNING CONFIGURATION**
> <what is simplified here and why that's fine in a lab>

> 🏭 **PRODUCTION CONSIDERATIONS**
> <what must change, and why>

---

## 12. The next problem

<The limitation this stage exposes, stated as a concrete failure the learner can see. This IS the transition —
never write "next we will look at X".>

→ **`../NN+1-<topic>/README.md`** (link it once the directory exists)

---

## 📚 Official documentation

<!-- Mandatory — see docs/CONVENTIONS.md §10.
     3–6 PRIMARY sources only (kubernetes.io/docs, or the tool's own site).
     ⚠️ curl every URL for a 200 BEFORE committing. Never write a link from memory.
     Stamp the date you verified them. -->

Everything above is self-contained — these are for going deeper, not for filling gaps.
*(All links verified YYYY-MM-DD.)*

| Reference | What it adds |
|---|---|
| [<Page title as the page titles itself>](https://kubernetes.io/docs/concepts/...) | <why THIS reader would click it> |

---

<!-- NAV FOOTER — mandatory, see docs/CONVENTIONS.md §9.2 -->

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **`../NN-1-<topic>/README.md`** | Project XX · Manual steps | **`../NN+1-<topic>/README.md`** ▶ |
