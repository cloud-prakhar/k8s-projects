# Solutions — Beginner

---

## 1. Scale the web tier

```bash
# Imperative
kubectl scale deployment task-web --replicas=5 -n task-tracker

# Declarative
sed -i 's/replicas: 2/replicas: 5/' manifests/11-health-checks/task-web-deployment.yaml
kubectl apply -f manifests/11-health-checks/task-web-deployment.yaml
```

**Why it works:** both set `spec.replicas`. The Deployment passes it to the current ReplicaSet, whose controller
creates Pods until observed == desired. `replicas` is not part of the Pod template, so **no new ReplicaSet and no
rollout** — the existing Pods are untouched.

**Which survives `apply`?** Only the declarative one. `kubectl scale` edits the live object; the next
`apply -f` sets `replicas` back to whatever the file says. This divergence between cluster and Git is exactly what
GitOps prevents by making Git the only writer (Project 10).

**Common wrong answer:** editing with `kubectl edit`. Same problem — invisible to Git, lost on the next apply.

**Follow-up:** what happens if you `kubectl scale` a Deployment that an HPA also manages? (They fight; the HPA wins.)

---

## 2. Find which Pod served you

```bash
kubectl port-forward svc/task-web 8080:80 -n task-tracker &
sleep 2
for i in $(seq 1 10); do
  curl -s localhost:8080/api/info | python3 -c 'import sys,json;print(json.load(sys.stdin)["pod"])'
done
kill %1
```

**Why it works:** `POD_NAME` is injected via the Downward API (`fieldRef: metadata.name`) — nothing at image-build
time could know it. Each `curl` opens a new TCP connection, and kube-proxy picks a backend per **connection**.

**Why isn't it even?** iptables mode picks randomly per connection, not round-robin. Over 10 samples you'll often see
4/3/3 or worse. With HTTP keep-alive you'd see **one** Pod for every request, because balancing happens at connection
setup, not per request. Per-request balancing needs an L7 proxy or a service mesh.

**Follow-up:** how would you make requests deliberately sticky? (`sessionAffinity: ClientIP` — but prefer stateless.)

---

## 3. Read config from a running container

```bash
kubectl exec deployment/task-api -n task-tracker -- env | grep -E 'APP_ENV|LOG_LEVEL'
kubectl exec deployment/task-web -n task-tracker -- env | grep TASK_API_URL
```

**Why it works:** `kubectl exec deployment/<name>` picks one Pod from the Deployment. `env` prints the container's
actual environment — ground truth, not what the manifest claims.

**Proving provenance:**

```bash
kubectl get deployment task-api -n task-tracker -o jsonpath='{.spec.template.spec.containers[0].envFrom}'
kubectl get configmap task-tracker-config -n task-tracker -o yaml
```

**Follow-up:** why is `env` a bad place for a credential? (Visible here, in `/proc/<pid>/environ`, in crash dumps,
and inherited by child processes.)

---

## 4. Change the log level

```bash
kubectl patch configmap task-tracker-config -n task-tracker -p '{"data":{"LOG_LEVEL":"debug"}}'
kubectl rollout restart deployment/task-api -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker
kubectl logs deployment/task-api -n task-tracker --tail=20
```

**Why the ConfigMap edit alone isn't enough:** environment variables are passed at `exec()` time and the Linux
process environment is immutable afterwards. Kubernetes cannot reach into a running process to change it. The
ConfigMap object changed; the running containers did not.

**Why `rollout restart` and not `delete pod`:** it patches the template with a `restartedAt` annotation → new
ReplicaSet → normal rolling update, honouring `maxSurge`/`maxUnavailable`. Deleting Pods is a blunt instrument that
can drop capacity.

**Volume-mounted ConfigMaps behave differently** — the kubelet refreshes the files (~60s), so the *file* changes
without a restart. Whether the app notices depends on whether it re-reads it.

**Follow-up:** see intermediate exercise 2 for making this automatic.

---

## 5. Roll back

```bash
kubectl set image deployment/task-api task-api=task-api:9.9.9 -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker --timeout=30s   # times out
kubectl get pods -n task-tracker                                            # ImagePullBackOff

kubectl rollout history deployment/task-api -n task-tracker
kubectl rollout undo deployment/task-api -n task-tracker
kubectl rollout status deployment/task-api -n task-tracker
```

**What `undo` actually does:** nothing is "restored". The previous ReplicaSet still exists, scaled to 0, holding the
previous Pod template intact. Undo scales it back up and the current one down. That's why rollback takes seconds and
why `revisionHistoryLimit: 0` would make it impossible.

**Why the app never went down:** `maxUnavailable: 0` means no old Pod is removed until a replacement is Ready. The
broken Pods never became Ready, so the rollout stalled and the old ones kept serving.

**Follow-up:** `kubectl rollout undo --to-revision=N` for a specific revision. What's in `CHANGE-CAUSE` and how do you
populate it? (An annotation — or under GitOps, the commit itself.)

---

## 6. Prove self-healing

```bash
kubectl get pods -n task-tracker -o wide          # note name + IP
POD=$(kubectl get pod -n task-tracker -l app.kubernetes.io/name=task-api -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD -n task-tracker
kubectl get pods -n task-tracker -o wide          # new name, new IP, RESTARTS 0
```

Contrast with a container restart:

```bash
kubectl exec $POD -n task-tracker -- kill 1 || true
kubectl get pod $POD -n task-tracker              # SAME name and IP, RESTARTS 1
```

**The distinction:**

| | Container restart | Pod replacement |
|---|---|---|
| Trigger | Process exits, or liveness fails | Pod deleted, node lost, evicted |
| Who acts | kubelet | ReplicaSet controller |
| Name / IP | Unchanged | **Both change** |
| `RESTARTS` | Increments | 0 on the new Pod |

**Follow-up:** which of these does a rolling update use? (Replacement — new Pods from a new ReplicaSet.)

---

## 7. Namespace hygiene

```bash
kubectl config set-context --current --namespace=task-tracker
kubectl get pods
kubectl config set-context --current --namespace=default    # back
```

**Why this repo still writes `-n` everywhere:** explicitness is a safety habit. The day your context silently points
at production, a command you thought was scoped to a lab isn't. Being explicit costs five characters.

**Follow-up:** how do you see the current namespace without changing it?
`kubectl config view --minify -o jsonpath='{..namespace}'`
