# Failure Labs — Project 03

[⬅ Project 03](../README.md)

Twelve deliberate breakages on a working EKS deployment. Each one: **break → symptom → investigate → root cause →
fix → what you learned.**

> **Start from a working state:** `./scripts/validate.sh` must pass first, and again after each fix — it exits
> non-zero when something is genuinely broken, so it is also how you confirm a repair.

Set these once per shell:

```bash
NS=url-shortener
ALB=$(kubectl get ingress url-shortener-ingress -n $NS -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
CODE=$(kubectl exec -n $NS postgres-0 -- psql -U shortener -d shortener -tAc 'SELECT code FROM links LIMIT 1')
FINAL="kubectl kustomize manifests/19-final/ | sed \"s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: \$(curl -s https://checkip.amazonaws.com)/32#\" | kubectl apply -f -"
```

`eval "$FINAL"` restores the complete final state — the universal fix.

| # | You break | You should see | You learn |
|---|---|---|---|
| [1](#lab-1--a-name-in-the-wrong-namespace) | A hostname's namespace | `failed to resolve host` | Search lists are per namespace |
| [2](#lab-2--config-drift) | A mutable ConfigMap under a live fleet | `404 302 404 302` | Immutable, versioned config |
| [3](#lab-3--writes-to-a-replica) | Redis write host | ~50% `READONLY` | Reads and writes need different names |
| [4](#lab-4--per-pod-dns-that-does-not-exist) | `serviceName` | Replica link down | Per-pod DNS needs a headless governing Service |
| [5](#lab-5--no-storageclass) | A PVC's class | `Pending`, no storage class set | EKS has no default class |
| [6](#lab-6--the-volume-is-in-another-az) | The volume's AZ | `volume node affinity conflict` | EBS is zonal |
| [7](#lab-7--alb-502-vs-503) | Port, replicas, health path | 502 / 503 | Which layer sends which code |
| [8](#lab-8--liveness-pointed-at-a-dependency) | Liveness path | Restart storm, exit 137 | Liveness checks the process only |
| [9](#lab-9--a-migration-that-cannot-run) | Migration DB host | `Init:0/1` → `Init:Error` | Init failures block start, not traffic |
| [10](#lab-10--the-alias-points-nowhere) | ExternalName target | `analytics_failed` climbs | Aliases move without rollouts |
| [11](#lab-11--cache-and-database-disagree) | A row in PostgreSQL | Stale redirect | Cache invalidation is your job |
| [12](#lab-12--how-an-alb-gets-orphaned) | *(observe only)* | Finalizer on the Ingress | Cleanup order on EKS |

---

## Lab 1 — A name in the wrong namespace

**Break:**

```bash
kubectl set env deployment/shortener-api -n $NS -c shortener-api \
  POSTGRES_HOST=postgres.analytics.svc.cluster.local
kubectl rollout status deployment/shortener-api -n $NS --timeout=120s
```

**Symptom:** the rollout **never completes** — the new pod's `migrate` init container waits; old pods keep serving.

**Investigate:**

```bash
kubectl get pods -n $NS -l app.kubernetes.io/name=shortener-api
kubectl logs -n $NS -l app.kubernetes.io/name=shortener-api -c migrate --tail=1
```

Hmm — `migrate` logs are fine: `set env -c shortener-api` changed only the **app** container. Look there:

```bash
kubectl describe pod -n $NS -l app.kubernetes.io/name=shortener-api | grep -A2 'Readiness probe failed' | head -3
```

`Readiness probe failed: HTTP probe failed with statuscode: 503` — and `/healthz` says
`failed to resolve host 'postgres.analytics.svc.cluster.local'`.

**Root cause:** the FQDN names the `analytics` namespace, which has no `postgres` Service. DNS returns NXDOMAIN, the
readiness probe fails, `maxUnavailable: 0` holds the rollout, and users see nothing.

**Fix:** `kubectl rollout undo deployment/shortener-api -n $NS`

**What you learned:** the namespace in an FQDN is load-bearing; and a correct readiness probe turned a broken
config into a stalled rollout instead of an outage.

---

## Lab 2 — Config drift

Stage 05 §9 in full — do it again on the final state, where you can see why generated names prevent it.

**Break:** create a mutable copy of the live config and point one Deployment at it:

```bash
CM=$(kubectl get deploy shortener-api -n $NS -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
kubectl get configmap $CM -n $NS -o json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);d["metadata"]={"name":"drifty","namespace":"url-shortener"};d.pop("immutable",None);print(json.dumps(d))' \
  | kubectl apply -f -
kubectl set env deployment/shortener-api -n $NS --from=configmap/drifty --overwrite >/dev/null 2>&1 || true
kubectl patch deployment shortener-api -n $NS --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/envFrom/0/configMapRef/name","value":"drifty"}]'
kubectl rollout status deployment/shortener-api -n $NS
kubectl patch configmap drifty -n $NS --type merge -p '{"data":{"CODE_LENGTH":"10"}}'
kubectl delete pod -n $NS "$(kubectl get pods -n $NS -l app.kubernetes.io/name=shortener-api -o jsonpath='{.items[0].metadata.name}')"
sleep 30
```

**Symptom:**

```bash
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' "http://$ALB/r/$CODE"; done; echo
```

`404 302 404 302 …`

**Investigate:** `curl -s "http://$ALB/r/$CODE"` a few times → `"expected_length":10` from one pod name, a redirect
from the other.

**Root cause:** a mutable ConfigMap edited under a running fleet reaches only pods that restart afterwards.

**Fix:** `eval "$FINAL"; kubectl delete configmap drifty -n $NS`

**What you learned:** with a `configMapGenerator`, the ConfigMap is immutable and its name is its content — this
edit is not possible to make.

---

## Lab 3 — Writes to a replica

**Break:**

```bash
kubectl set env deployment/shortener-api -n $NS -c shortener-api REDIS_WRITE_HOST=redis.url-shortener.svc.cluster.local
kubectl rollout status deployment/shortener-api -n $NS
```

**Symptom:**

```bash
for i in $(seq 1 12); do curl -s -o /dev/null -D - "http://$ALB/r/$CODE" | grep -i x-click-counted; done | sort | uniq -c
```

Roughly half `X-Click-Counted: false`. Redirects all work.

**Investigate:** `curl -sI "http://$ALB/r/$CODE" | grep -i x-click-error` →
`You can't write against a read only replica.`; `/api/info` → `stats.redis_write_errors` climbing.

**Root cause:** the ClusterIP load-balances each new connection across primary and replica.

**Fix:** `kubectl rollout undo deployment/shortener-api -n $NS`

**What you learned:** a ClusterIP answers "any member". Writes need "**this** member" — a per-pod name.

---

## Lab 4 — Per-pod DNS that does not exist

**Break:**

```bash
kubectl patch service redis-headless -n $NS --type merge -p '{"spec":{"clusterIP":""}}' 2>&1 | tail -1
```

`clusterIP` is immutable, so the realistic mistake is recreating it wrong:

```bash
kubectl delete service redis-headless -n $NS
kubectl create service clusterip redis-headless --tcp=6379:6379 -n $NS
kubectl patch service redis-headless -n $NS --type merge \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"redis","app.kubernetes.io/instance":"redis"}}}'
kubectl delete pod redis-1 -n $NS
sleep 30
```

**Symptom:** both Redis pods are `1/1 Running` — `redis-cli ping` passes on each. But **every** click is now
uncounted: the API writes to `redis-0.redis-headless…`, the same name that just stopped existing.

```bash
for i in 1 2 3 4; do curl -s -o /dev/null -D - "http://$ALB/r/$CODE" | grep -i x-click-counted; done
```

```
X-Click-Counted: false
X-Click-Counted: false
X-Click-Counted: false
X-Click-Counted: false
```

**Investigate:**

```bash
kubectl logs redis-1 -n $NS | tail -3
kubectl exec -n $NS deploy/shortener-api -c shortener-api -- python -c "import socket;print(socket.gethostbyname('redis-0.redis-headless'))"
kubectl get service redis-headless -n $NS
```

```
* Connecting to MASTER redis-0.redis-headless.url-shortener.svc.cluster.local:6379
# Unable to connect to MASTER: Invalid argument
```

The API's resolver says `Name or service not known`, and the Service now has a `CLUSTER-IP`. (Redis reports the
failed lookup as `Invalid argument` — know both phrasings.)

**Root cause:** per-pod A records exist only under a **headless** Service. A ClusterIP Service called
`redis-headless` publishes one VIP and no per-pod names.

**Fix:** `kubectl delete service redis-headless -n $NS && eval "$FINAL"` then `kubectl delete pod redis-1 -n $NS`.
Give the replica a few seconds to resync before `master_link_status` reads `up`.

**What you learned:** "headless" is a property of the Service (`clusterIP: None`), not of its name.

---

## Lab 5 — No StorageClass

**Break:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lab5, namespace: url-shortener}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
EOF
```

**Symptom:** `kubectl get pvc lab5 -n $NS` → `Pending`, forever.

**Investigate:** `kubectl describe pvc lab5 -n $NS | tail -1` →
`no persistent volumes available for this claim and no storage class is set`; `kubectl get storageclass` → no
`(default)`.

**Root cause:** EKS creates `gp2` without the default annotation. A class-less claim only binds to a pre-made PV.

**Fix:** `kubectl delete pvc lab5 -n $NS` — and always set `storageClassName`.

---

## Lab 6 — The volume is in another AZ

**Break:**

```bash
NODE=$(kubectl get pod postgres-0 -n $NS -o jsonpath='{.spec.nodeName}')
kubectl cordon "$NODE"
kubectl delete pod postgres-0 -n $NS
sleep 20
```

**Symptom:** `postgres-0` `Pending`; the API returns 503; `validate.sh` fails.

**Investigate:**

```bash
kubectl describe pod postgres-0 -n $NS | grep -A2 FailedScheduling
PV=$(kubectl get pvc postgres-data-postgres-0 -n $NS -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity}{"\n"}'
kubectl get nodes -L topology.kubernetes.io/zone
```

`1 node(s) had volume node affinity conflict, 1 node(s) were unschedulable`.

**Root cause:** the EBS volume exists in one AZ; the only node there is cordoned; a node in another AZ cannot attach
it. An AZ outage looks exactly like this.

**Fix:** `kubectl uncordon "$NODE"` — `postgres-0` schedules and reattaches.

**What you learned:** in-cluster databases on EBS are only as available as one AZ.

---

## Lab 7 — ALB 502 vs 503

**502 — endpoints exist, the port is wrong:**

```bash
kubectl patch service shortener-api -n $NS --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
sleep 45; curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/api/info"
eval "$FINAL"
```

**503 — no healthy targets:**

```bash
kubectl scale deployment/shortener-web -n $NS --replicas=0
sleep 25; curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"
kubectl scale deployment/shortener-web -n $NS --replicas=2
```

**503 — targets exist but fail the ALB's own health check:**

```bash
kubectl annotate ingress url-shortener-ingress -n $NS alb.ingress.kubernetes.io/healthcheck-path=/nope --overwrite
sleep 60; curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"
for tg in $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'urlshort')].TargetGroupArn" --output text); do
  aws elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.[State,Reason]' --output text; done
eval "$FINAL"
```

**What you learned:** `502` = a target was tried and failed; `503` = there was nothing healthy to try. The ALB's
health check is independent of Kubernetes probes.

---

## Lab 8 — Liveness pointed at a dependency

**Break:**

```bash
kubectl patch deployment shortener-api -n $NS --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}]'
kubectl rollout status deployment/shortener-api -n $NS
kubectl scale statefulset/postgres -n $NS --replicas=0
sleep 90
kubectl get pods -n $NS -l app.kubernetes.io/name=shortener-api
```

**Symptom:** `RESTARTS` rising on every API pod.

**Investigate:** `kubectl describe pod -n $NS -l app.kubernetes.io/name=shortener-api | grep -E 'Liveness probe failed|Exit Code' | head -4` → `Exit Code: 137`.

**Root cause:** liveness failed because a *dependency* failed; restarting the API fixes nothing and every pod enters
back-off.

**Fix:** `kubectl scale statefulset/postgres -n $NS --replicas=1 && eval "$FINAL"`

---

## Lab 9 — A migration that cannot run

**Break:**

```bash
kubectl patch deployment shortener-api -n $NS --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"POSTGRES_HOST","value":"postgres.nowhere.svc.cluster.local"}}]'
kubectl get pods -n $NS -l app.kubernetes.io/name=shortener-api -w      # Ctrl-C after ~3 min
```

**Symptom:** a new pod in `Init:0/1`. After two minutes (60 attempts × 2 s) the init container gives up and exits 1;
the kubelet restarts it, so the pod shows `Init:Error` for a moment and then `Init:0/1` again with `RESTARTS 1`, `2`,
… and growing back-off (`Init:CrashLoopBackOff`). The old pods keep serving; the ALB never sees the new pod.

```
shortener-api-7cd4496654-fpnn5   0/1   Init:0/1   1 (29s ago)   2m30s
shortener-api-dc95675b5-d7g9x    1/1   Running    0             16m
shortener-api-dc95675b5-scmjp    1/1   Running    0             16m
```

**Investigate:** `kubectl logs <new-pod> -n $NS -c migrate --tail=1` →
`database not reachable attempt=26/60 err=failed to resolve host 'postgres.nowhere.svc.cluster.local'`.

**Fix:** `kubectl rollout undo deployment/shortener-api -n $NS`

**What you learned:** `Init:` statuses mean the app never started — look at the init container's logs, not the app's.

---

## Lab 10 — The alias points nowhere

**Break:**

```bash
kubectl patch service analytics -n $NS --type merge -p '{"spec":{"externalName":"collector.does-not-exist.svc.cluster.local"}}'
for i in $(seq 1 5); do curl -s -o /dev/null "http://$ALB/r/$CODE"; done
sleep 3
```

**Symptom:** redirects unaffected.

**Investigate:**

```bash
for i in 1 2 3; do curl -s "http://$ALB/api/info" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["pod"],d["stats"]["analytics_failed"],d["stats"]["analytics_last_error"])'; done
```

`analytics_failed` > 0, `Failed to resolve 'analytics.url-shortener.svc.cluster.local'`.

**Fix:** `eval "$FINAL"` — and note that **no API pod restarted**, in either direction.

---

## Lab 11 — Cache and database disagree

**Break:** change a link's target directly in PostgreSQL:

```bash
curl -s -o /dev/null "http://$ALB/r/$CODE"            # make sure it is cached
kubectl exec -n $NS postgres-0 -- psql -U shortener -d shortener -c \
  "UPDATE links SET target_url='https://example.com/changed' WHERE code='$CODE'"
curl -sI "http://$ALB/r/$CODE" | grep -iE '^(location|x-cache)'
```

**Symptom:** `Location` is still the **old** URL, `X-Cache: HIT`.

**Investigate:** `curl -s "http://$ALB/api/links/$CODE"` → `target_url` is the new one (from PostgreSQL) while
`cache_ttl_remaining` shows how long the old one will be served.

**Root cause:** the cache is written on create and on miss, never invalidated on update. For up to
`CACHE_TTL_SECONDS` (300) users get the stale target. Two API replicas can briefly serve *different* answers if one
read from a replica that has not caught up.

**Fix:** `kubectl exec -n $NS redis-0 -- redis-cli del link:$CODE` — then decide on a real policy (delete-on-write,
shorter TTL, versioned keys).

---

## Lab 12 — How an ALB gets orphaned

**Observe only — do not break this one on a cluster you care about.**

```bash
kubectl get ingress url-shortener-ingress -n $NS -o jsonpath='{.metadata.finalizers}{"\n"}'
```

`["ingress.k8s.aws/resources"]`

**The failure, described:** run `helm uninstall aws-load-balancer-controller -n kube-system` and then
`kubectl delete namespace url-shortener`. The namespace hangs in `Terminating` because nothing will clear the
finalizer. Someone "fixes" it by removing the finalizer by hand; the namespace disappears; **the ALB, its target
groups and security groups remain in AWS**, billing, and their subnets block `eksctl delete cluster`.

**Investigate an orphan:**

```bash
aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=kubernetes-lab \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

**Fix / habit:** delete Ingresses (and `LoadBalancer` Services) **first**, wait for the delete to return, then remove
controllers, then the cluster. `scripts/cleanup.sh` does exactly this.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Manual steps](../scripts/manual-steps.md)** | [Project 03](../README.md) | **[Exercises — Beginner](../exercises/beginner.md)** ▶ |
