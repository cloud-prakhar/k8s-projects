# Intermediate Exercises — Project 01

---

## Exercise 1 — Diagnose a broken Service, blind

**Task:** have someone (or a script) run **one** of these, then diagnose it without knowing which:

```bash
kubectl patch svc task-api -n task-tracker -p '{"spec":{"selector":{"app.kubernetes.io/name":"wrong"}}}'
kubectl patch svc task-api -n task-tracker -p '{"spec":{"ports":[{"name":"http","port":8080,"targetPort":9999}]}}'
kubectl scale deployment task-api --replicas=0 -n task-tracker
```

**Success:** you name the cause before fixing it, and you can say which command distinguished it from the others.

**Hint:** endpoints populated or empty splits the three into two groups. What splits the remaining pair?

**Think about:** write down the decision tree. That's your debugging runbook.

---

## Exercise 2 — Make a config change roll out automatically

**Task:** without a manual `rollout restart`, make a `LOG_LEVEL` change take effect on running Pods.

**Success:** editing the ConfigMap and applying the Deployment triggers a rollout on its own.

**Hint:** a Pod-template change triggers a rollout. What could you put in the template that derives from the
ConfigMap's contents?

**Think about:** this is what Helm and Kustomize do with a `checksum/config` annotation. Why is that better than
remembering to restart?

---

## Exercise 3 — Zero-downtime proof

**Task:** prove your rollout is genuinely zero-downtime. Run a continuous request loop while rolling `task-api`, and
record every status code.

Then **remove the readiness probe** and repeat.

**Success:** you have two result sets, and you can explain the difference.

**Hint:** `while true; do curl -s -o /dev/null -w "%{http_code} " …; sleep 0.2; done`

**Think about:** with no probe, why does `maxUnavailable: 0` stop being a guarantee?

---

## Exercise 4 — Readiness without restart

**Task:** make one API Pod leave the Service **without** restarting it or changing its Deployment, then bring it back.

**Success:** the Pod shows `0/1 READY`, `RESTARTS: 0`, and its IP disappears from the EndpointSlice.

**Hint:** the app has an endpoint for exactly this. Watch with
`kubectl get endpointslices -n task-tracker -w`.

**Think about:** what would a real application use this for? (Graceful drain, cache warm-up, dependency loss.)

---

## Exercise 5 — Two versions, one Service

**Task:** create a second Deployment `task-api-canary` whose Pods carry the labels the `task-api` Service selects.
Send traffic and observe.

**Success:** `/api/info` sometimes returns a canary Pod name.

**Hint:** the Service selects **Pods by label**. It has no idea Deployments exist.

**Think about:** how would you control the traffic split? What can't you do with this approach? (This is the
foundation of canary deployments — Project 05.)

---

## Exercise 6 — Minimal RBAC-free debugging

**Task:** using only `kubectl describe` and `kubectl get events`, identify each of the three failures in
[failure labs 2, 6 and 9](../failure-labs/labs.md) — no `logs`, no `exec`.

**Success:** you name the root cause of each from `describe` output alone.

**Think about:** which failures *can't* be diagnosed without logs, and why?
