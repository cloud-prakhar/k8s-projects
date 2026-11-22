# Advanced Exercises — Project 04

[⬅ Project 04](../README.md) · Solutions: [`solutions/advanced.md`](solutions/advanced.md)

---

## Exercise 1 — Survive a slow payment service

With `PAYMENT_LATENCY_MS=8000`, 30 concurrent checkouts make `order` pods NotReady (stage 11 §8). Change the
system — not the payment latency — so that the order *list* and the admin host keep working during the slowdown.

**Verify:** under the same load, `GET /api/orders` keeps returning 200.

---

## Exercise 2 — Database per service

Split PostgreSQL into `catalog-db` and `orders-db` StatefulSets, each with its own Secret and user, and rewrite the
NetworkPolicies so each service can reach only its own database.

**Verify:** `catalog` cannot open a connection to `orders-db` (timeout), and `validate.sh` passes after updating it.

---

## Exercise 3 — Make a label an identity

Break 4 in stage 15 showed a pod labelled `order` can call payment. Describe, and where possible implement, the
controls that stop an arbitrary workload from carrying that label.

**Verify:** you can name at least two layers (RBAC on pod creation; admission policy restricting labels / a
ServiceAccount-per-service check; mTLS identity).

---

## Exercise 4 — Policies as a test

Turn the stage 15 reachability matrix into a script that exits non-zero if the cluster's actual reachability
differs from an expected matrix you keep in the repository.

**Verify:** deleting `allow-cart-egress` makes the script fail and name the cell that changed.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Intermediate](intermediate.md)** | [Project 04](../README.md) | **[Interview questions](../interview-questions/questions.md)** ▶ |
