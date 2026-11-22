# Intermediate Exercises — Project 04

[⬅ Project 04](../README.md) · Solutions: [`solutions/intermediate.md`](solutions/intermediate.md)

---

## Exercise 1 — Add a `reviews` service safely

A new `reviews` service (use the `catalog` image with `POSTGRES_DB=catalog` as a stand-in) must be callable by the
storefront only, and may read PostgreSQL. Add it without weakening any existing rule.

**Verify:** storefront → reviews works; order → reviews and a rogue pod → reviews time out.

---

## Exercise 2 — Change the upstream timeout everywhere, safely

Raise `UPSTREAM_TIMEOUT_SECONDS` to 5 for every service in one change that rolls every consumer, and can be
undone with one command per Deployment.

**Verify:** every service reports 5; `kubectl rollout undo` on one restores 3 for it.

---

## Exercise 3 — Expose an admin API on its own host

Route `Host: admin.shop.local` path `/api/catalog` to `catalog` in addition to the existing admin rule, without
changing what shoppers see.

**Verify:** `curl -H 'Host: admin.shop.local' $ALB/api/catalog/products` works; the hostless routes are unchanged.

---

## Exercise 4 — Tighten DNS egress to one port per protocol, and prove TCP matters

Show that removing TCP 53 from `allow-dns-egress` does not break ordinary lookups — then explain when it would.

**Verify:** a normal lookup still works; you can name the case (large/truncated responses) that would fail.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Beginner](beginner.md)** | [Project 04](../README.md) | **[Advanced](advanced.md)** ▶ |
