# Advanced Exercises — Project XX

---

## Exercise 1 — HPA + PodDisruptionBudget under load

**Task:** configure an HPA (2→10 on 70% CPU) and a PDB (`minAvailable: 2`). Generate load until it scales, then
`kubectl drain` a node and explain what the PDB did.

**Success:** replicas increase under load; the drain respects `minAvailable` and evicts pods gradually.

**Hint:** HPA needs Metrics Server **and** CPU `requests` — without requests there is no percentage to compute.

**Think about:** what happens if `minAvailable` equals `replicas`? (Try it. The drain will hang — that's a real
outage-during-maintenance scenario.)

---

## Challenge — Zero-trust networking

**Task:** apply a default-deny NetworkPolicy in the namespace, then allow **only** frontend → backend and
backend → database. Everything else must fail.

**Success:** `curl` from frontend to backend works; frontend to database is refused; DNS still resolves.

**Hint:** the classic mistake is forgetting egress to CoreDNS on port 53 — everything breaks in a way that looks like
a DNS bug.

---

<!-- 4–6 exercises. Advanced = design decisions with trade-offs, plus one open-ended challenge. -->
