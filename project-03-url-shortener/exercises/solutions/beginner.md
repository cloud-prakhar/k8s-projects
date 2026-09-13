# Solutions — Beginner

[⬅ Exercises](../beginner.md)

---

## 1. Read a pod's DNS configuration

```bash
kubectl exec -n url-shortener deploy/shortener-api -c shortener-api -- cat /etc/resolv.conf
```

```
search url-shortener.svc.cluster.local svc.cluster.local cluster.local ec2.internal
nameserver 10.100.0.10
options ndots:5
```

| Line | Why |
|---|---|
| `nameserver 10.100.0.10` | CoreDNS's ClusterIP (`kube-dns` Service), from the kubelet's `clusterDNS` |
| `url-shortener.svc.cluster.local` | The pod's own namespace — first, so short Service names resolve locally |
| `svc.cluster.local` | Lets `<svc>.<namespace>` work |
| `cluster.local` | The cluster domain |
| `ec2.internal` | Inherited from the **node's** resolver: the VPC's DHCP options in us-east-1 |
| `ndots:5` | Names with < 5 dots try every suffix before being tried as typed |

```bash
kubectl exec -n url-shortener deploy/shortener-api -c shortener-api -- python -c '
import socket
for n in ["postgres","postgres.url-shortener","analytics-collector","analytics-collector.analytics"]:
    try: print(n, socket.gethostbyname(n))
    except OSError as e: print(n, e)'
```

`analytics-collector` fails: the search list only completes names in `url-shortener`.

**Common wrong answer:** using `kubectl run … busybox nslookup analytics-collector.analytics` and concluding it
does not resolve. busybox does not apply the search list to dotted names.

> **Follow-up:** how many DNS queries does resolving `kubernetes.io` cost from this pod?
> *(Up to five name forms × A and AAAA before the real answer.)*

---

## 2. Find the EBS volumes

```bash
for pvc in postgres-data-postgres-0 redis-data-redis-0 redis-data-redis-1; do
  pv=$(kubectl get pvc $pvc -n url-shortener -o jsonpath='{.spec.volumeName}')
  vol=$(kubectl get pv $pv -o jsonpath='{.spec.csi.volumeHandle}')
  zone=$(kubectl get pv $pv -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
  pod=${pvc#*-data-}
  node=$(kubectl get pod $pod -n url-shortener -o jsonpath='{.spec.nodeName}')
  nodezone=$(kubectl get node $node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  echo "$pvc  $vol  volume-az=$zone  pod=$pod  node-az=$nodezone"
done
```

**Why it works:** the CSI driver records the EBS volume ID as `volumeHandle` and pins the PV to its AZ with node
affinity; the scheduler honours it, so node-az always equals volume-az.

> **Follow-up:** confirm in AWS: `aws ec2 describe-volumes --volume-ids <vol> --query 'Volumes[0].Attachments'`.

---

## 3. Which Redis member answered?

```bash
ALB=$(kubectl get ingress url-shortener-ingress -n url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in $(seq 1 10); do
  curl -s "http://$ALB/api/info" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("read:",d["redis_read"]["role"],"write:",d["redis_write"]["role"])'
done | sort | uniq -c
```

**Why it works:** the API opens a new Redis connection per call. The read host is the ClusterIP, so kube-proxy
picks either member per connection; the write host is `redis-0`'s per-pod name.

---

## 4. Decode a Secret

```bash
kubectl get secret redis-secret -n url-shortener -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d; echo
kubectl auth can-i get secrets -n url-shortener
kubectl auth can-i get secrets -n url-shortener --as=system:serviceaccount:url-shortener:default
```

`yes` for you (the cluster creator has `cluster-admin` through its EKS access entry), `no` for the ServiceAccount.
**base64 is encoding; the permission to `get secrets` is the real control.**

---

## 5. See the ALB's targets

```bash
kubectl get targetgroupbindings -n url-shortener
for tg in $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'urlshort')].TargetGroupArn" --output text); do
  echo "== $tg"; aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
done
kubectl get pods -n url-shortener -o custom-columns=NAME:.metadata.name,IP:.status.podIP
```

**Why:** `target-type: ip` registers pod IPs from each Service's EndpointSlices.

---

## 6. Count the objects

```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 -I{} sh -c 'kubectl get {} -n url-shortener --ignore-not-found -o name 2>/dev/null' | sort
kubectl get all,cm,secret -n analytics
kubectl get storageclass url-shortener-gp3; kubectl get pv
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=url-shortener --query 'Volumes[].VolumeId'
aws resourcegroupstaggingapi get-resources --tag-filters Key=ingress.k8s.aws/stack,Values=url-shortener/url-shortener-ingress --query 'ResourceTagMappingList[].ResourceARN'
```

**Common wrong answer:** `kubectl get all` — it omits ConfigMaps, Secrets, PVCs, Ingresses, EndpointSlices and
TargetGroupBindings, and never shows cluster-scoped or AWS resources.
