# Beginner Exercises — Project 04

[⬅ Project 04](../README.md) · Solutions: [`solutions/beginner.md`](solutions/beginner.md)

Try each one before opening the solution. Every answer is verifiable with a command.

---

## Exercise 1 — Draw the call graph from the cluster

Without reading any code, list which service calls which, using only `kubectl` and the services' `/whoami`
endpoints.

**Verify:** your graph matches the one in the project README: storefront → catalog, cart, order; order → payment.

---

## Exercise 2 — Shared or owned?

For every environment variable of the `order` container, say whether it comes from the shared ConfigMap, the
Deployment itself, a Secret or the Downward API.

**Verify:** `kubectl get deploy order -n ecommerce -o yaml` agrees with your table.

---

## Exercise 3 — Find the ALB's target groups

List the target groups the ALB controller created, and explain why there are four and not five.

**Verify:** `kubectl get targetgroupbindings -n ecommerce` shows four; none for `payment`.

---

## Exercise 4 — Prove a policy is enforced, not just present

Show, with one command, that a pod which is not `order` cannot reach `payment` — and explain why the result is a
timeout rather than "connection refused".

**Verify:** the command exits with curl's timeout code (28) or equivalent.

---

## Exercise 5 — Which policies select `payment`?

List every NetworkPolicy that selects the payment pods, and say which direction each isolates.

**Verify:** two — `default-deny-all` (ingress + egress) and `allow-order-to-payment` (ingress).

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Failure labs](../failure-labs/labs.md)** | [Project 04](../README.md) | **[Intermediate](intermediate.md)** ▶ |
