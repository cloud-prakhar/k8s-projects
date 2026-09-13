# Solutions — Intermediate

[⬅ Exercises](../intermediate.md)

---

## 1. Change the cache TTL safely

```bash
sed -i 's/^CACHE_TTL_SECONDS=300/CACHE_TTL_SECONDS=60/' manifests/19-final/config/shortener.env
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32#" | kubectl apply -f -
kubectl rollout status deployment/shortener-api -n url-shortener
```

**Why it works:** the generator names the ConfigMap after its content, so the new file produces
`shortener-config-<new-hash>`; every reference is rewritten, the pod templates change, and all pods roll together.

**Revert:** `kubectl rollout undo deployment/shortener-api -n url-shortener` — the previous ReplicaSet references the
previous generated ConfigMap, which still exists unchanged. (Then revert the file too, or the next apply undoes the
undo.)

**Common wrong answer:** `kubectl edit configmap shortener-config-<hash>` — rejected, it is immutable. Editing a
mutable copy reproduces Lab 2.

> **Follow-up:** why do `postgres` pods roll too? *(Its env references the same ConfigMap for `POSTGRES_DB`/`USER`.)*

---

## 2. Move analytics without a rollout

```bash
kubectl get service analytics-collector -n analytics -o yaml \
  | sed 's/name: analytics-collector$/name: collector-v2/' \
  | grep -v -E 'clusterIP|resourceVersion|uid|creationTimestamp' | kubectl apply -f -
kubectl patch service analytics -n url-shortener --type merge \
  -p '{"spec":{"externalName":"collector-v2.analytics.svc.cluster.local"}}'
```

**Why it works:** the API calls `http://analytics.url-shortener.svc.cluster.local/events` and resolves it on every
request. CoreDNS immediately returns the new CNAME. No pod restarts.

> **Follow-up:** what would you need to change if `collector-v2` listened on port 8080? *(The client URL — an
> ExternalName cannot remap ports.)*

---

## 3. Scale Redis to three members

```bash
kubectl scale statefulset/redis -n url-shortener --replicas=3
kubectl rollout status statefulset/redis -n url-shortener
kubectl exec -n url-shortener redis-2 -- redis-cli info replication | grep -E 'role|master_host|master_link_status'
kubectl get pvc -n url-shortener
./scripts/validate.sh
```

**Why it works:** ordinal 2's start-up script is not `0`, so it appends `replicaof redis-0.redis-headless…`. A new
claim `redis-data-redis-2` → a new EBS volume. With two nodes, anti-affinity is only *preferred*, so `redis-2` shares
a node with one of the others.

**Scale back:** `kubectl scale … --replicas=2`, then `kubectl delete pvc redis-data-redis-2 -n url-shortener` — scale
down does not delete the claim (or the volume's bill).

---

## 4. Grow the PostgreSQL volume

```bash
kubectl patch pvc postgres-data-postgres-0 -n url-shortener -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl get pvc postgres-data-postgres-0 -n url-shortener -w       # CAPACITY → 2Gi
kubectl exec -n url-shortener postgres-0 -- df -h /var/lib/postgresql/data
kubectl get pod postgres-0 -n url-shortener
```

**Why it works:** `allowVolumeExpansion: true` on the class; the EBS CSI driver calls `ModifyVolume`, then the node
plugin grows the ext4 filesystem online.

**Common wrong answer:** editing `volumeClaimTemplates` in the StatefulSet — rejected, it is immutable. (Update it
in Git too, via delete-orphan + re-create, so future ordinals match.)

> **Follow-up:** can you shrink it back? *(No — EBS volumes and PVCs cannot shrink.)*

---

## 5. Restrict the ALB to two addresses

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ \
  | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32,203.0.113.0/24#" | kubectl apply -f -
H=$(kubectl get ingress url-shortener-ingress -n url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
LB=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$H'].LoadBalancerArn" --output text)
for sg in $(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].SecurityGroups[]' --output text); do
  aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text
done
```

**Why:** `inbound-cidrs` is a comma-separated list; the controller reconciles the managed security group.
**Declaratively** means through the rendered manifest, not `kubectl annotate` — otherwise the next apply resets it.
