# Failure Labs — Project XX

Breaking Kubernetes on purpose is the fastest way to learn to debug it. Each lab follows the same shape:

**Break → Observe the symptom → Investigate → Root cause → Fix → What you learned**

> Do these in order. Restore each fix before starting the next lab, or run `./scripts/deploy.sh` to reset.

---

## Lab 1 — <Name>

**Break it**

```bash
# the exact command
```

**Symptom**

```
# what the learner will actually see
```

**Investigate**

```bash
kubectl get pods -n <ns>
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous
kubectl get events -n <ns> --sort-by=.lastTimestamp
```

**Root cause**

<one paragraph, mechanism-level — not "the config was wrong" but *why the control plane behaved this way*>

**Fix**

```bash
# the exact command
```

**What you learned**

<the transferable rule>

---

<!-- Repeat for at least 6 labs. Suggested coverage per project:
     ImagePullBackOff · CrashLoopBackOff · Service with no endpoints · wrong targetPort
     · missing ConfigMap/Secret key · failing readiness probe · Pending PVC · OOMKilled
     · insufficient CPU · DNS failure · NetworkPolicy blocking traffic · Ingress 404 -->

---

## Debugging Cheat Sheet

| Question | Command |
|---|---|
| What state is it in? | `kubectl get pods -n <ns> -o wide` |
| Why is it in that state? | `kubectl describe pod <pod> -n <ns>` (read **Events** at the bottom) |
| What did the app say? | `kubectl logs <pod> -n <ns>` |
| What did it say before it crashed? | `kubectl logs <pod> -n <ns> --previous` |
| Is the Service wired up? | `kubectl get endpointslices -n <ns>` |
| Can I reach it directly? | `kubectl port-forward pod/<pod> 8080:8080 -n <ns>` |
| Can pods resolve each other? | `kubectl exec -it <pod> -n <ns> -- nslookup <svc>` |
| What happened recently? | `kubectl get events -n <ns> --sort-by=.lastTimestamp` |
| Is it resource-starved? | `kubectl top pods -n <ns>` |
| What fields does this have? | `kubectl explain <kind>.spec --recursive` |
