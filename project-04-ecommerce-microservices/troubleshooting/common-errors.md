# Common Errors — Project 04

[⬅ Project 04](../README.md)

Symptom → investigate → root cause → fix. For deliberate breakage see [`failure-labs/labs.md`](../failure-labs/labs.md).

**The universal first commands:**

```bash
kubectl config current-context                                   # right cluster?
kubectl get pods -n ecommerce -o wide
kubectl describe pod <pod> -n ecommerce                          # Events at the bottom
kubectl get events -n ecommerce --sort-by=.lastTimestamp | tail -20
curl -s http://$ALB/whoami | python3 -m json.tool                # which hop is broken, from the storefront
```

---

## Which hop is broken?

With five services, find the hop before the cause:

| From | Command | Reads |
|---|---|---|
| outside | `curl -s -o /dev/null -w '%{http_code}' http://$ALB/<path>` | ALB-level status |
| storefront | `curl -s http://$ALB/whoami` | catalog / cart / order reachability |
| order | `curl -s -H 'Host: admin.shop.local' http://$ALB/whoami` | postgres / payment reachability |
| any pod | `kubectl exec deploy/<svc> -n ecommerce -- python -c "import socket;s=socket.socket();s.settimeout(3);s.connect(('<host>',<port>))"` | raw TCP |

---

## DNS and Services

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `Name or service not known` for one name | `kubectl get svc -n ecommerce` | No Service of that exact name | Create / rename it |
| `Name or service not known` for **every** name, in every service, at once | `kubectl get networkpolicy -n ecommerce` | Egress default-deny without `allow-dns-egress` | Apply `15-security/02-allow-dns-egress.yaml` |
| Resolves; connection **refused**; EndpointSlice empty | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | Selector mismatch, or no pod Ready | Compare selector and pod labels; check readiness |
| Resolves; refused; endpoints present | `kubectl get svc <svc> -o yaml` | Wrong `targetPort` | Fix the port |
| Resolves; **timeout** | `kubectl get networkpolicy -n ecommerce` | A policy is dropping it | Add the missing egress **and** ingress allow |

## Configuration and Secrets

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `CreateContainerConfigError` | `kubectl describe pod` | Missing ConfigMap / Secret / key (named) | Apply it first |
| A service talks to `127.0.0.1` | `kubectl exec … printenv` | Key renamed; `envFrom` dropped it silently | Restore the key |
| `database "orders" does not exist` | `kubectl logs statefulset/postgres` | Init script did not run (volume already initialised) | `CREATE DATABASE orders` by hand, or a fresh volume |
| `password authentication failed` | `kubectl logs deploy/catalog` | Secret changed after the database was initialised | `ALTER USER`, or restore the Secret |
| Redis probes `NOAUTH` | `kubectl exec redis-0 -- env \| grep REDISCLI` | `REDISCLI_AUTH` missing | Add it from the Secret |

## Storage and StatefulSets

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| PVC `Pending`, no pod yet | `kubectl describe pvc` | `WaitForFirstConsumer` — correct | Create the consumer |
| PVC `Pending`: `no storage class is set` | `kubectl get storageclass` | EKS has no default class | Name `ecommerce-gp3` |
| `Multi-Attach error` | `kubectl get pods -o wide` | RollingUpdate across nodes on one EBS volume | `Recreate`, or a StatefulSet |
| Redis `Permission denied` on `/data` | `kubectl exec redis-0 -- ls -ld /data` | New filesystem owned by root | `fsGroup: 1000` |
| `postgres-0` Pending: `volume node affinity conflict` | `kubectl get pv -o yaml` | No schedulable node in the volume's AZ | Uncordon / add capacity in that AZ |

## Ingress / ALB

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| Ingress has no ADDRESS | `kubectl describe ingress ecommerce-ingress -n ecommerce` | Controller missing, wrong class, subnets untagged | Install controller; `ingressClassName: alb` |
| curl to the ALB **times out** | `curl https://checkip.amazonaws.com` | Your IP not in `inbound-cidrs` | Re-annotate |
| 404 plain HTML | `kubectl get ingress -o yaml` | No rule matched path / Host | Fix path, `pathType`, host |
| 404 from the storefront for `/api/cart/x` | `pathType` | `Exact` on `/api/cart` | `Prefix` |
| 503 on one path only | `kubectl get endpointslices` | That backend has no healthy targets | Check that Deployment |
| 503 on every path after stage 15 | `kubectl get networkpolicy` | `allow-internet-to-public-services` missing | Apply it |
| Pods `0/1` with readiness gates `0/1` | `aws elbv2 describe-target-health` | ALB health checks failing (policy, path) | Fix path / policy |

## NetworkPolicy

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| Default-deny applied, traffic still flows | `kubectl get ds aws-node -n kube-system -o jsonpath='{..containers[*].name}'` | No `aws-eks-nodeagent`: enforcement off | `enableNetworkPolicy: "true"` on the vpc-cni add-on |
| An allow exists but the flow still times out | Both sides' policies | Egress on the source **or** ingress on the destination missing | Add the other half |
| A rule is wider than intended | `kubectl get networkpolicy <n> -o yaml` | `namespaceSelector` and `podSelector` in **separate** `-` items (OR) | Put them in one item (AND) |
| Policy matches no pods | `kubectl describe networkpolicy <n>` | Label typo in `podSelector` | Fix the label |
| New pods briefly reachable by anything | — | Standard enforcement mode (allow until programmed) | `NETWORK_POLICY_ENFORCING_MODE=strict` |
| A payment-only pod reachable after a Service port change | `kubectl get svc payment -o yaml` | Service port ≠ container port (VPC CNI requirement) | Make them equal |

## Probes and cascading failure

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `RESTARTS` climbing on every pod, exit 137 | `kubectl describe pod` | Liveness checks a dependency | Liveness → `/livez` |
| `Init:0/1` forever | `kubectl logs <pod> -c migrate` | PostgreSQL unreachable (Service, policy, password) | Fix the hop |
| Everything slow, nothing down | `curl .../whoami`, payment `/whoami` | Slow upstream holding threads | Bounded timeouts; see stage 11 §8 |
| Order list 503 while only checkout should be affected | `kubectl get pods -l app.kubernetes.io/name=order` | Thread pool exhausted ⇒ readiness timeouts | Timeouts, bulkheads, capacity |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Project README §14](../README.md#14-troubleshooting)** | [Project 04](../README.md) | **[Failure labs](../failure-labs/labs.md)** ▶ |
