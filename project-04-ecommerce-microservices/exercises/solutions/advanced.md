# Solutions — Advanced

[⬅ Exercises](../advanced.md)

---

## 1. Survive a slow payment service

Several layers, best in combination:

| Change | Effect |
|---|---|
| Keep `UPSTREAM_TIMEOUT_SECONDS` small (3) | Threads are freed after 3 s instead of 8 |
| Serve `/healthz` from a **separate** thread pool or process (or raise probe `timeoutSeconds`) | Health checks no longer queue behind checkouts |
| Split checkout and read paths into separate Deployments (`order-writer`, `order-reader`) | A payment slowdown cannot touch the order list |
| A circuit breaker around payment | After N failures, fail fast for a cooldown instead of waiting |
| More threads/replicas (Project 05) | Raises the load needed to exhaust the pool |

The split is the structural fix; the others reduce the blast radius.

---

## 2. Database per service

Two StatefulSets (`catalog-db`, `orders-db`), two Secrets with different users, `POSTGRES_HOST` per Deployment
(owned config now), and policies:

```yaml
allow-catalog-to-catalog-db:  podSelector name=catalog-db, ingress from name=catalog :5432
allow-order-to-orders-db:     podSelector name=orders-db,  ingress from name=order   :5432
# plus egress on each app to only its own db
```

Proof: `kubectl exec deploy/catalog -- python -c "import socket;s=socket.socket();s.settimeout(3);s.connect(('orders-db',5432))"` → timeout.

---

## 3. Make a label an identity

- **RBAC:** only the CD pipeline's identity may create pods/Deployments in `ecommerce` (Project 07).
- **Admission policy** (ValidatingAdmissionPolicy / Kyverno / Gatekeeper): a pod labelled `name=order` must use
  `serviceAccountName: order-sa` and the approved image.
- **Pod Security Admission** `restricted` to limit what a forged pod could do anyway.
- **mTLS** (service mesh): payment authorises the caller's **certificate** identity, not its IP.

---

## 4. Policies as a test

```bash
#!/usr/bin/env bash
# expected.txt: "src dst:port OPEN|----" per line
fail=0
while read -r src dst want; do
  h=${dst%%:*}; p=${dst##*:}
  got=$(kubectl exec -n ecommerce deploy/$src -- python -c "
import socket; s=socket.socket(); s.settimeout(2)
try: s.connect(('$h',$p)); print('OPEN')
except Exception: print('----')")
  [[ "$got" == "$want" ]] || { echo "MISMATCH $src → $dst: want $want got $got"; fail=1; }
done < expected.txt
exit $fail
```

Delete `allow-cart-egress` and the `cart → redis:6379` cell flips to `----`.
