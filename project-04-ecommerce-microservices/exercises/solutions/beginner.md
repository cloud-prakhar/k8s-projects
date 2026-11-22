# Solutions — Beginner

[⬅ Exercises](../beginner.md)

---

## 1. Draw the call graph from the cluster

```bash
for d in storefront catalog cart order payment; do
  echo "== $d"
  kubectl exec -n ecommerce deploy/$d -- python -c \
    "import urllib.request,json; print(json.dumps(json.load(urllib.request.urlopen('http://localhost:8080/whoami'))['dependencies']))"
done
```

Each service's `/whoami` lists what *it* depends on: storefront → catalog, cart, orders; catalog → postgres;
cart → redis; order → postgres, payment; payment → nothing.

**Common wrong answer:** reading the Services — they say what exists, not who calls whom.

---

## 2. Shared or owned?

```bash
kubectl get deploy order -n ecommerce -o jsonpath='{.spec.template.spec.containers[0].envFrom}{"\n"}{.spec.template.spec.containers[0].env}' | python3 -m json.tool
```

| Variable | Source |
|---|---|
| `POSTGRES_HOST/PORT/USER`, `PAYMENT_URL`, `UPSTREAM_TIMEOUT_SECONDS`, … | shared ConfigMap (`envFrom`) |
| `POSTGRES_DB=orders`, `RUN_MIGRATIONS=false` | the Deployment (owned) |
| `POSTGRES_PASSWORD` | `Secret/postgres-secret` |
| `POD_NAME` | Downward API |

---

## 3. Find the ALB's target groups

```bash
kubectl get targetgroupbindings -n ecommerce
```

Four: one per **backend Service referenced by an Ingress rule** — storefront, catalog, cart, order. `payment` has no
rule, so no target group: it is not on the internet.

---

## 4. Prove a policy is enforced

```bash
kubectl run rogue --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n ecommerce -- \
  curl -s -m 5 -o /dev/null -w 'exit=%{exitcode}\n' http://payment:8080/healthz
```

`exit=28` — curl's timeout. The node agent's eBPF filter **drops** the SYN; nothing replies, so there is no RST
("refused"). Resolves-but-times-out is the fingerprint of a policy denial.

---

## 5. Which policies select `payment`?

```bash
kubectl get networkpolicy -n ecommerce -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    sel=p["spec"]["podSelector"].get("matchLabels",{}); exp=p["spec"]["podSelector"].get("matchExpressions",[])
    hit = not sel and not exp or sel.get("app.kubernetes.io/name")=="payment" or any("payment" in e.get("values",[]) for e in exp)
    if hit: print(p["metadata"]["name"], p["spec"]["policyTypes"])'
```

`default-deny-all ['Ingress', 'Egress']` and `allow-order-to-payment ['Ingress']` — plus `allow-dns-egress`
(selects every pod, Egress only).
