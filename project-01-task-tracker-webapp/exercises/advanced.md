# Advanced Exercises — Project 01

---

## Exercise 1 — Design the probes for a slow-starting app

**Task:** suppose `task-api` took 45 seconds to boot and could hang under load. Write the three probes with
justified numbers, and explain what each would do during: (a) a normal start, (b) a 60-second boot, (c) a
five-minute dependency outage.

**Success:** a probe block where you can defend every field, including why you did **not** use
`initialDelaySeconds`.

**Think about:** what's the worst outcome of each probe being too aggressive versus too lenient?

---

## Exercise 2 — Make the API safely horizontally scalable

**Task:** the API can't scale past 1 replica correctly because tasks live in memory. Without adding a database,
describe **three** different ways to make it correct at 3 replicas, with the trade-offs of each.

**Success:** three genuinely different approaches (e.g. shared external store, sticky sessions, single-writer with
read replicas) and an argument for which you'd pick.

**Think about:** which Kubernetes primitive does each one need? Which are honest solutions and which just move the
problem?

---

## Exercise 3 — Survive a node failure

**Task:** on the single-node cluster, `docker stop kubernetes-lab-control-plane`. Predict what happens before you
run it, then run it and check.

**Success:** your prediction matches, and you can list exactly what you'd need to survive this.

**Hint:** `docker start` brings it back.

**Think about:** which of those mitigations are Kubernetes features and which are infrastructure decisions?
(Projects 05 and 09 build them out.)

---

## Exercise 4 — Close the last zero-downtime gap

**Task:** even with readiness probes, a Pod can receive requests for a moment *after* SIGTERM, because endpoint
removal and process shutdown race. Demonstrate the gap, then close it.

**Success:** you can explain the race and implement the standard fix.

**Hint:** `preStop` with a sleep, plus `terminationGracePeriodSeconds`. Why does sleeping help when the app is about
to die anyway?

**Think about:** why is this in Project 05 rather than here?

---

## Challenge — Build the whole project from scratch, blind

**Task:** delete the namespace. Without looking at `manifests/`, recreate the entire working application from memory:
namespace, both Deployments with probes, both Services, ConfigMap, Secret.

**Rules:** `kubectl explain` and `--dry-run=client -o yaml` are allowed. The stage READMEs are not.

**Success:** `./scripts/validate.sh` passes against manifests you wrote yourself.

**Think about:** which fields did you have to look up? Those are the ones to review before an interview.
