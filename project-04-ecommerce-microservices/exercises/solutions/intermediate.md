# Solutions — Intermediate

[⬅ Exercises](../intermediate.md)

---

## 1. Add a `reviews` service safely

Four objects: a Deployment + Service (`reviews`, port 8080), and three policy changes:

```yaml
# allow-internet-to-public-services is NOT changed — reviews is internal.
# 1. storefront may call reviews: add to allow-storefront-egress
    - to: [ { podSelector: { matchLabels: { app.kubernetes.io/name: reviews } } } ]
      ports: [ { protocol: TCP, port: 8080 } ]
# 2. reviews accepts storefront only
kind: NetworkPolicy
metadata: { name: allow-storefront-to-reviews, namespace: ecommerce }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: reviews } }
  policyTypes: [Ingress]
  ingress: [ { from: [ { podSelector: { matchLabels: { app.kubernetes.io/name: storefront } } } ], ports: [ { protocol: TCP, port: 8080 } ] } ]
# 3. reviews may reach postgres (egress) AND postgres accepts reviews (add to allow-apps-to-postgres `from`)
```

**Why:** both ends of every edge. Forgetting #3's second half is the classic miss.

---

## 2. Change the timeout everywhere, safely

Edit `manifests/19-final/config/ecommerce.env` → `UPSTREAM_TIMEOUT_SECONDS=5`, then render and apply. The hashed
name changes, so all five Deployments roll. `kubectl rollout undo deployment/order` returns that one to the
previous ReplicaSet — which still references the previous ConfigMap.

---

## 3. Admin API on its own host

Add a second path under the existing `host: admin.shop.local` rule, **before** `/`:

```yaml
    - host: admin.shop.local
      http:
        paths:
          - { path: /api/catalog, pathType: Prefix, backend: { service: { name: catalog, port: { number: 8080 } } } }
          - { path: /,            pathType: Prefix, backend: { service: { name: order,   port: { number: 8080 } } } }
```

---

## 4. DNS over TCP

Ordinary A lookups fit in a UDP response, so removing TCP 53 appears harmless. TCP is used when a response is
truncated (large records, many A records for a headless Service with many pods, DNSSEC) — then lookups fail
intermittently, only for some names. Keep both.
