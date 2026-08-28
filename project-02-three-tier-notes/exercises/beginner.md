# Beginner Exercises — Project 02

[⬅ Project 02](../README.md) · Solutions: [`solutions/beginner.md`](solutions/beginner.md)

Try each one before opening the solution. Every answer is verifiable with a
command — if you cannot check it, you have not finished.

---

## Exercise 1 — Scale the API tier

Scale `notes-api` to 4 replicas, confirm all four are receiving traffic, then
scale back to 2.

**Verify:** the EndpointSlice lists four IPs, and repeated requests to
`/api/info` return more than one pod name.

---

## Exercise 2 — Prove the data is shared

Add a note through the UI. Then show that **every** `notes-api` replica returns
it, and explain in one sentence why this differs from Project 01, where each
replica had its own task list.

**Verify:** `note_count` from `/api/info` is identical no matter which pod
answers.

---

## Exercise 3 — Find where the data physically lives

Starting from the PVC, trace the storage all the way to a directory on a Kind
node, and list its contents.

**Verify:** you can see a `pgdata` directory containing PostgreSQL's files.

---

## Exercise 4 — Read the config out of a running container

Without looking at any YAML, determine from the **running cluster**:

1. which database host `notes-api` is configured with
2. which ConfigMap that value came from
3. whether the password is visible in the container's environment

---

## Exercise 5 — Delete the database pod and time the outage

Delete `postgres-0`, and measure how long the API is unavailable. Then explain
which two mechanisms decided that duration.

**Verify:** you can name the probe settings that control it.

---

## Exercise 6 — Connect to PostgreSQL directly

Open a `psql` session inside the database pod and:

1. list the tables
2. show the indexes on `notes`
3. insert a note by hand and see it appear in the UI

**Bonus:** which of those indexes proves the ConfigMap-mounted `init.sql` ran?

---

## Exercise 7 — Change a config value and make it take effect

Change `LOG_LEVEL` to `debug` and get the running pods to actually use it —
without deleting any pods, and with no downtime.

**Verify:** `kubectl exec … env | grep LOG_LEVEL` shows `debug`, and the API's
logs are chattier.

---

## Exercise 8 — Route a new path through the Ingress

Add a rule so `http://notes.local/whoami` reaches `notes-web`'s `/whoami`
endpoint, and confirm it returns the pod name.

**Verify:** `curl -H 'Host: notes.local' http://localhost/whoami` prints
`pod=notes-web-…`.

---

## Exercise 9 — Namespace hygiene

List **every** object this project created in `notes-platform` — including the
kinds `kubectl get all` does not show. Then count them.

**Verify:** your list includes the PVC, both ConfigMaps, the Secret and the
Ingress.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Failure labs](../failure-labs/labs.md)** | [Project 02](../README.md) | **[Intermediate](intermediate.md)** ▶ |
