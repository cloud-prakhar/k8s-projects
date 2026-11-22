# Failure Labs — Project 04

[⬅ Project 04](../README.md)

Ten deliberate breakages on a working deployment. Each one: **break → symptom → investigate → root cause → fix →
what you learned.**

> **Start from a working state:** `./scripts/validate.sh` must pass first, and again after each fix — it exits
> non-zero when something is genuinely broken, so it is also how you confirm a repair.

Set these once per shell:

```bash
NS=ecommerce
ALB=$(kubectl get ingress ecommerce-ingress -n $NS -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
BODY='{"session":"lab","items":[{"sku":"SKU-1001","name":"k","price_cents":8900,"quantity":1}]}'
FINAL="kubectl kustomize manifests/19-final/ | sed \"s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: \$(curl -s https://checkip.amazonaws.com)/32#\" | kubectl apply -f -"
```

`eval "$FINAL"` restores the complete final state — the universal fix.

| # | You break | You should see | You learn |
|---|---|---|---|
| [1](#lab-1--the-dns-egress-trap) | DNS egress | Every name fails in every service at once | Egress default-deny blocks DNS |
| [2](#lab-2--half-an-edge) | One side of an allowed edge | Timeout, although an allow exists | Egress on source **and** ingress on destination |
| [3](#lab-3--and-becomes-or) | The DNS rule's structure | Nothing — and a much wider rule | `from`/`to` list semantics |
| [4](#lab-4--the-deny-all-was-not-the-only-lock) | Delete the default-deny | `order` gets *more* broken | Any policy selecting a pod isolates it |
| [5](#lab-5--a-forged-label) | Nothing — just a label | A pod passes `allow-order-to-payment` | NetworkPolicy trusts labels |
| [6](#lab-6--the-service-link-collision) | `POSTGRES_PORT` unset | `POSTGRES_PORT=tcp://10.100.x.x:5432` in the pod | Kubernetes injects service-link env vars |
| [7](#lab-7--alb-404-502-503) | Path type, port, replicas | 404 / 502 / 503 per path | Which layer sends which code |
| [8](#lab-8--a-slow-dependency) | Payment latency | Unrelated endpoints 503 | Cascading failure through a thread pool |
| [9](#lab-9--envfrom-drops-a-renamed-key) | A ConfigMap key name | Checkout calls `127.0.0.1` | `envFrom` fails silently |
| [10](#lab-10--the-ownership-boundary-is-configuration) | `POSTGRES_DB` | Nothing fails | The boundary is a convention |

---

## Lab 1 — The DNS egress trap

**Break:**

```bash
kubectl delete networkpolicy allow-dns-egress -n $NS
sleep 20
```

**Symptom:** within seconds `cart`, `catalog` and `order` go `0/1`; the shop's panels all fail.

**Investigate:**

```bash
kubectl get pods -n $NS
kubectl exec -n $NS deploy/storefront -- python -c "import socket; print(socket.gethostbyname('catalog'))"
```

`gaierror … Name or service not known` — for **every** name, in every service.

**Root cause:** `default-deny-all` denies all egress, including UDP/TCP 53 to CoreDNS. Nothing can resolve any
Service name, so every dependency looks "down" at once. The symptom points at the services; the cause is one
missing policy.

**Fix:** `kubectl apply -f manifests/15-security/02-allow-dns-egress.yaml`

**What you learned:** after any egress default-deny, the first allow is DNS. When *everything* breaks at once, suspect
something *everything* shares.

---

## Lab 2 — Half an edge

**Break:**

```bash
kubectl delete networkpolicy allow-order-egress -n $NS
sleep 20
curl -s -m 15 -X POST "http://$ALB/api/orders" -H 'Content-Type: application/json' -d "$BODY"; echo
```

**Symptom:** `order` pods go `0/1` and checkout fails — although `allow-order-to-payment` and `allow-apps-to-postgres`
both still exist.

**Investigate:** `kubectl get networkpolicy -n $NS` — every *ingress* allow is present. `kubectl exec deploy/order -c
order -- python -c "import socket;s=socket.socket();s.settimeout(3);s.connect(('postgres',5432))"` → timeout.

**Root cause:** `order` is still egress-isolated (by `default-deny-all` and by `allow-dns-egress`, which selects every
pod), and nothing now permits its egress to PostgreSQL or payment. A connection needs **both** halves.

**Fix:** `kubectl apply -f manifests/15-security/05-allow-order-egress.yaml`

---

## Lab 3 — AND becomes OR

**Break:**

```bash
kubectl patch networkpolicy allow-dns-egress -n $NS --type=json -p '[
 {"op":"replace","path":"/spec/egress/0/to","value":[
   {"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}}},
   {"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]}]'
```

**Symptom:** none. DNS still works. Every pod may now send UDP/TCP 53 to **anything in kube-system**.

**Investigate:** `kubectl get networkpolicy allow-dns-egress -n $NS -o yaml` — two items under `to:`, not one.

**Root cause:** two list items are OR'd; two selectors inside one item are AND'd. One dash widened the rule.

**Fix:** `kubectl apply -f manifests/15-security/02-allow-dns-egress.yaml`

**What you learned:** policy bugs that *widen* access produce no symptom. Review policies as code.

---

## Lab 4 — The deny-all was not the only lock

Verified on this project's cluster while testing `validate.sh`.

**Break:**

```bash
kubectl delete networkpolicy default-deny-all allow-order-egress -n $NS
sleep 30
kubectl get pods -n $NS -l app.kubernetes.io/name=order
```

**Symptom:** `order` `0/2` — deleting the "deny" made things worse, not better.

**Root cause:** `allow-dns-egress` has `podSelector: {}` and `policyTypes: [Egress]`: it selects every pod for
egress, so every pod stays egress-isolated with only DNS allowed. Any policy that selects a pod for a direction
isolates it in that direction.

**Fix:** `kubectl apply -f manifests/15-security/`

---

## Lab 5 — A forged label

**Break (observe only):**

```bash
kubectl run fake-order --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n $NS \
  --labels=app.kubernetes.io/name=order -- \
  curl -s -m 5 -X POST http://payment:8080/api/payments/authorize \
    -H 'Content-Type: application/json' -H 'X-Calling-Service: fake' -d '{"amount_cents":1}'
```

**Symptom:** `{"authorized":true,…}` — verified on this project's cluster.

**Root cause:** NetworkPolicy authorises by label. Anyone who can create a pod with the right label in this
namespace passes.

**Fix / habit:** RBAC on pod creation, admission policy constraining labels to approved workloads, and mTLS for
identity (Project 07).

---

## Lab 6 — The service-link collision

Found during this project's verification — the stage 03 manifests set `POSTGRES_PORT` explicitly because of it.

**Break:**

```bash
kubectl run port-check --rm -i --restart=Never --image=busybox:1.36 -n $NS -- sh -c 'echo POSTGRES_PORT=$POSTGRES_PORT'
```

```
POSTGRES_PORT=tcp://10.100.30.153:5432
```

Now remove the explicit value from a running service:

```bash
kubectl patch configmap "$(kubectl get deploy catalog -n $NS -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')" -n $NS \
  --type json -p '[{"op":"remove","path":"/data/POSTGRES_PORT"}]' 2>&1 | tail -1
```

▸ Immutable — the final state protects you. To see the failure, run the catalog image in a test pod **without**
setting `POSTGRES_PORT` (service links are on by default) and read its log: the app builds its connection string
with `port=tcp://10.100.x.x:5432` and cannot connect.

> Verification note: the injected `POSTGRES_PORT=tcp://…` value above was observed on this project's cluster;
> the resulting connection error was not captured verbatim, so no exact message is quoted here.

**Root cause:** for every Service that exists when a pod starts, the kubelet injects `<NAME>_SERVICE_HOST`,
`<NAME>_PORT` and friends — a pre-DNS discovery mechanism. A Service called `postgres` therefore defines
`POSTGRES_PORT` in every **new** pod, colliding with any app that reads that variable.

**Fix:** set the variable explicitly (this project), or `enableServiceLinks: false` in the pod spec.

---

## Lab 7 — ALB 404, 502, 503

```bash
# 404 from the storefront: Exact instead of Prefix
kubectl patch ingress ecommerce-ingress -n $NS --type=json -p '[{"op":"replace","path":"/spec/rules/1/http/paths/1/pathType","value":"Exact"}]'
sleep 30; curl -s -o /dev/null -w '404? %{http_code}\n' "http://$ALB/api/cart/s-1"; eval "$FINAL"

# 503: no targets for one path — the others keep working
kubectl scale deployment/catalog -n $NS --replicas=0; sleep 30
curl -s -o /dev/null -w 'catalog %{http_code}  ' "http://$ALB/api/catalog/products"
curl -s -o /dev/null -w 'cart %{http_code}\n' "http://$ALB/api/cart/s-1"
kubectl scale deployment/catalog -n $NS --replicas=2

# 502: targets exist on the wrong port
kubectl patch service cart -n $NS --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
sleep 45; curl -s -o /dev/null -w '502? %{http_code}\n' "http://$ALB/api/cart/s-1"; eval "$FINAL"
```

**What you learned:** `404` = no rule matched (or the backend's own 404); `503` = no healthy target; `502` = a
target tried and failed. One ALB, independent target groups — a partial outage stays partial.

---

## Lab 8 — A slow dependency

Measured on this project's cluster (stage 11 §8 has the full tables).

**Break:**

```bash
CM=$(kubectl get deploy order -n $NS -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
# the generated ConfigMap is immutable, so override on the Deployments directly:
kubectl set env deployment/payment -n $NS PAYMENT_LATENCY_MS=8000
kubectl set env deployment/order -n $NS -c order UPSTREAM_TIMEOUT_SECONDS=60
kubectl rollout status deployment/order -n $NS
END=$(( $(date +%s) + 60 ))
for i in $(seq 1 50); do ( while [ $(date +%s) -lt $END ]; do
  curl -s -o /dev/null -m 70 -X POST "http://$ALB/api/orders" -H 'Content-Type: application/json' -d "$BODY"; done ) & done
sleep 25
kubectl get pods -n $NS -l app.kubernetes.io/name=order
curl -s -o /dev/null -m 10 -w 'order list %{http_code}\n' "http://$ALB/api/orders"
wait
```

**Symptom:** `order` pods `0/1`, the order list — which never calls payment — `503`; `kubectl get events` shows
readiness **and liveness** probe timeouts on `order`.

**Root cause:** every checkout holds one of `order`'s 8 threads for 8 s; probes queue behind them and time out.

**Fix:** `eval "$FINAL"` (restores the 3 s timeout and 0 latency). A timeout bounds the damage; capacity and
isolating health endpoints from request threads remove it.

---

## Lab 9 — `envFrom` drops a renamed key

**Break (stage 05 state, mutable ConfigMap):**

```bash
kubectl patch configmap ecommerce-config -n $NS --type json \
  -p '[{"op":"remove","path":"/data/PAYMENT_URL"},{"op":"add","path":"/data/PAYMENT_ENDPOINT","value":"http://payment:8080"}]'
kubectl rollout restart deployment/order -n $NS && kubectl rollout status deployment/order -n $NS
curl -s -H 'Host: admin.shop.local' "http://$ALB/whoami"
```

**Symptom:** `order` starts fine; `/whoami` reports `payment.url: http://127.0.0.1:8080`, unreachable.

**Root cause:** `envFrom` injects whatever keys exist; the app falls back to its default. `configMapKeyRef` would have
failed the container at start.

**Fix:** restore the key, or `eval "$FINAL"`.

---

## Lab 10 — The ownership boundary is configuration

**Break:**

```bash
kubectl set env deployment/order -n $NS -c order POSTGRES_DB=catalog
kubectl set env deployment/order -n $NS -c migrate POSTGRES_DB=catalog
kubectl rollout status deployment/order -n $NS
curl -s -m 15 -X POST "http://$ALB/api/orders" -H 'Content-Type: application/json' -d "$BODY"; echo
kubectl exec -n $NS postgres-0 -- psql -U ecommerce -d catalog -c '\dt'
```

**Symptom:** nothing fails. `\dt` in the **catalog** database now lists an `orders` table.

**Root cause:** nothing in Kubernetes or PostgreSQL enforces which service uses which database here — both use the
same user. The boundary is a value in a Deployment.

**Fix:** `eval "$FINAL"` then `kubectl exec -n $NS postgres-0 -- psql -U ecommerce -d catalog -c 'DROP TABLE orders'`.
Production: one database **user** per service with grants only on its own database.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Troubleshooting](../troubleshooting/common-errors.md)** | [Project 04](../README.md) | **[Exercises — Beginner](../exercises/beginner.md)** ▶ |
