# Intermediate Exercises — Project XX

---

## Exercise 1 — Add readiness and liveness probes

**Task:** add a readiness probe on `/healthz` and a liveness probe on `/livez` to the backend, then prove the
readiness probe removes a pod from the Service without restarting it.

**Success:** breaking `/healthz` makes the pod `0/1 READY` and drops it from the EndpointSlice; the container does
**not** restart.

**Hint:** `kubectl exec` into the pod to break the health endpoint; watch `kubectl get endpointslices -w`.

**Think about:** what would have happened if you'd pointed the *liveness* probe at `/healthz` instead?

---

<!-- 5–8 exercises. Intermediate = multiple resources interacting, requires reading describe output. -->
