# Intermediate Exercises — Project 03

[⬅ Project 03](../README.md) · Solutions: [`solutions/intermediate.md`](solutions/intermediate.md)

---

## Exercise 1 — Change the cache TTL safely

Change `CACHE_TTL_SECONDS` to `60` on the final state so that **every** API pod picks it up together, and so that a
single command can revert it.

**Verify:** `/api/info` shows `cache_ttl_seconds: 60` from both pods; `kubectl rollout undo` brings back `300`.

---

## Exercise 2 — Move analytics without a rollout

The analytics team moves their collector to a new Service named `collector-v2` in their namespace. Make the
shortener follow **without restarting any shortener pod**.

**Verify:** the API pods' `AGE` is unchanged, and `analytics_failed` does not rise after the switch.

---

## Exercise 3 — Scale Redis to three members

Add a second replica. Confirm it replicates, confirm writes still go to the primary, and account for what new AWS
resource appeared.

**Verify:** `redis-2` has `master_link_status:up`; a third EBS volume exists; `validate.sh` passes.

---

## Exercise 4 — Grow the PostgreSQL volume

Grow `postgres-data-postgres-0` from 1 GiB to 2 GiB without restarting PostgreSQL.

**Verify:** `df -h` inside `postgres-0` shows ~2 GiB, and the pod's `RESTARTS` and `AGE` did not change.

---

## Exercise 5 — Restrict the ALB to two addresses

Allow your current IP and one more CIDR (say `203.0.113.0/24`) through the ALB, declaratively.

**Verify:** the ALB's managed security group lists both CIDRs on port 80.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Beginner](beginner.md)** | [Project 03](../README.md) | **[Advanced](advanced.md)** ▶ |
