# Advanced Exercises — Project 02

[⬅ Project 02](../README.md) · Solutions: [`solutions/advanced.md`](solutions/advanced.md)

Open-ended. Several have more than one defensible answer — the reasoning matters
more than the YAML.

---

## Exercise 1 — Zero-downtime rollout, measured

Prove with numbers that a `notes-api` rollout drops **zero** requests. Then
remove the readiness probe, repeat the measurement, and quantify the difference.

**Deliverable:** two numbers and one sentence explaining the mechanism.

---

## Exercise 2 — A backup and a restore you have actually tested

A PVC is not a backup. Build one:

1. a `CronJob` that runs `pg_dump` into a second PVC
2. a documented restore procedure
3. **proof it works** — drop the table, restore, show the notes are back

---

## Exercise 3 — Kustomize overlays for two environments

Restructure `19-final/` into `base/` plus `overlays/dev` and `overlays/prod`,
where prod has 4 API replicas, `APP_ENV=production`, and a 5Gi volume.

**Constraint:** no duplicated manifests. `kubectl kustomize overlays/prod` must
render correctly.

---

## Exercise 4 — Make the database unreachable from everything except the API

Any pod in the cluster can currently open a connection to PostgreSQL. Fix that.

**Verify:** a test pod cannot connect, and `notes-api` still can.

> Requires a CNI that enforces NetworkPolicy. Kind's default (kindnet) does
> **not**. Part of this exercise is discovering that, and saying how you would
> verify enforcement rather than assuming it.

---

## Exercise 5 — Survive a node failure

On the two-node cluster, arrange things so that losing the node running
`postgres-0` does not lose the data. Explain honestly what is and is not possible
with `local-path` storage, and what you would change on a real cluster.

---

## Exercise 6 — Add a read-through cache

Put Redis in front of PostgreSQL for `GET /api/notes`, as a StatefulSet with its
own headless Service. Address a specific member by its per-pod DNS name.

**Then answer:** what new failure modes did you just introduce, and how would you
detect a stale cache?

---

## Exercise 7 — Connection pooling

The API opens a new database connection per request. Measure the cost, then put
PgBouncer between the API and PostgreSQL and measure again.

**Deliverable:** before/after numbers, and an explanation of what a pool changes
about the failure behaviour you relied on in stage 07.

---

## Exercise 8 — TLS on the Ingress

Serve `https://notes.local` with a self-signed certificate, and redirect HTTP to
HTTPS. Then describe exactly what would change with cert-manager and a real
domain.

---

## Exercise 9 — Design review

Write a one-page review of this project's architecture as if it were a pull
request for a production system. Name the five most serious problems in priority
order, and for each: the failure it causes, and the fix.

**Constraint:** be specific. "Add monitoring" is not a finding; "no alert exists
for a PVC above 90% full, so the database fills its disk silently" is.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Intermediate](intermediate.md)** | [Project 02](../README.md) | **[Solutions](solutions/README.md)** ▶ |
