# Intermediate Exercises — Project 02

[⬅ Project 02](../README.md) · Solutions: [`solutions/intermediate.md`](solutions/intermediate.md)

These need more than one command, and several require you to reason about *why*
before you type anything.

---

## Exercise 1 — Survive a StatefulSet deletion

Write a note, delete the StatefulSet entirely, recreate it, and show the note is
still there. Then explain which object made that possible and why it was not
garbage-collected.

---

## Exercise 2 — Migrate the data to a new volume

The stage 08 transition orphaned the old `postgres-data` PVC. Do a real
migration this time: create a second claim, move the contents of the `notes`
table into a database backed by it, and switch over.

**Constraint:** no data loss, and you may not edit the `volumeClaimTemplate` of
the existing StatefulSet.

---

## Exercise 3 — Make `type: LoadBalancer` actually work

Get `notes-web-lb` an `EXTERNAL-IP` on your Kind cluster, and reach the UI
through it. Then explain what changed — and what did **not**.

---

## Exercise 4 — Host-based routing

Add a second hostname, `api.notes.local`, that routes **everything** to
`notes-api`, while `notes.local` keeps its existing `/` and `/api` split.

**Verify:** `curl -H 'Host: api.notes.local' http://localhost/api/info` works,
and `curl -H 'Host: api.notes.local' http://localhost/` returns the API's 404,
not the web UI.

---

## Exercise 5 — Prove the readiness/liveness distinction with numbers

Take the database away and measure:

1. how long until the API pods leave the EndpointSlice
2. how many times they restart

Then change the liveness probe to `/healthz`, repeat, and record both numbers
again. Explain the difference using only the probe fields.

---

## Exercise 6 — A StorageClass with Retain

Move the database onto the `notes-platform-retain` StorageClass. Then delete the
PVC and show the data is still on the node.

**Then clean up properly** — including the `Released` PV.

---

## Exercise 7 — Force a rollout when a ConfigMap changes

Right now, editing `notes-config` requires you to remember
`kubectl rollout restart`. Make the change itself trigger the rollout.

**Hint:** a pod-template annotation containing a hash of the ConfigMap.

---

## Exercise 8 — Scale the StatefulSet and explain the result

Scale `postgres` to 3, then show that you have **three separate databases**, not
one replicated database. Explain in three sentences what a StatefulSet does and
does not give you, and what would be needed to make this real replication.

**Then scale back down and clean up the orphaned PVCs.**

---

## Exercise 9 — Find every place the database password exists

On a live cluster, list every location the password can be read from, and for
each one name the control that would stop an attacker in production.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Beginner](beginner.md)** | [Project 02](../README.md) | **[Advanced](advanced.md)** ▶ |
