# Advanced Exercises — Project 03

[⬅ Project 03](../README.md) · Solutions: [`solutions/advanced.md`](solutions/advanced.md)

---

## Exercise 1 — Manual Redis failover

Simulate losing the primary for good: promote `redis-1` to primary, make the API write to it, and make `redis-0`
rejoin as a replica when it returns. Then explain why this design makes that hard, and what would do it properly.

**Verify:** after the failover, clicks are counted; `redis-0` shows `role:slave` with `master_host` pointing at
`redis-1`.

---

## Exercise 2 — Fix cache invalidation

Lab 11 showed stale redirects after a target URL changes. Design (and, if you like, implement in `app.py`) an update
endpoint that cannot serve a stale target for more than a second on any replica — including when reads hit the
replica.

**Verify:** update a link, then loop 50 redirects through the ALB — none return the old `Location`.

---

## Exercise 3 — Point `postgres` at a managed database

Without changing any ConfigMap or Deployment, make the API use an external PostgreSQL (for the exercise, a second
PostgreSQL StatefulSet in a new namespace `shared-db` stands in for RDS). Plan the data migration so no link is lost.

**Verify:** `/api/info` still shows `postgres.url-shortener.svc.cluster.local` as the host; the old StatefulSet is
scaled to 0; all links resolve.

---

## Exercise 4 — Zero-error rollouts behind the ALB

Stage 11 measured `88 × 302, 1 × 502, 1 × 000` during an API rollout. Change the API Deployment so a restart under
the same load produces no errors, and explain every value you chose.

**Verify:** 120 requests at 1/s during `kubectl rollout restart` → only `302`.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Intermediate](intermediate.md)** | [Project 03](../README.md) | **[Interview questions](../interview-questions/questions.md)** ▶ |
