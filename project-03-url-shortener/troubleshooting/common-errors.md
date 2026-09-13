# Common Errors — Project 03

[⬅ Project 03](../README.md)

Symptom → investigate → root cause → fix. For deliberate breakage see [`failure-labs/labs.md`](../failure-labs/labs.md).

**The universal first commands:**

```bash
kubectl config current-context                                     # right cluster?
kubectl get pods -n url-shortener -o wide
kubectl describe pod <pod> -n url-shortener                        # Events at the bottom
kubectl get events -n url-shortener --sort-by=.lastTimestamp | tail -20
```

---

## Cluster and add-ons (EKS)

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `eksctl create` fails, `VpcLimitExceeded` / EIP limit | CloudFormation events | Account quota | Delete unused VPCs, or request a quota increase |
| `kubectl`: `the server has asked for the client to provide credentials` | `aws sts get-caller-identity` | Expired or different AWS credentials | Refresh credentials / `AWS_PROFILE` |
| `kubectl`: `no such host` for the cluster endpoint | `aws eks list-clusters` | The cluster was deleted; stale context | `aws eks update-kubeconfig --name kubernetes-lab --region us-east-1` |
| Pods `Pending`: `Too many pods` | `kubectl describe node` | t3.medium allows 17 pods (VPC CNI ENI limit) | Scale the node group to 3, or use larger instances |
| `ImagePullBackOff` | `kubectl describe pod` | Tag never pushed, repo name wrong, private repo | `docker manifest inspect <image>` |

## DNS and Services

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `failed to resolve host 'postgres'` | `kubectl get svc -n url-shortener` | No Service of that name (stage 03 before 04) | Create the Service |
| Resolves in one namespace, NXDOMAIN in another | `cat /etc/resolv.conf` in the pod | Short names complete only within the caller's namespace | Use `<svc>.<ns>` or the FQDN |
| busybox `nslookup a.b` says NXDOMAIN, app resolves fine | — | busybox does not apply the search list to dotted names | Test with the app's resolver or an FQDN |
| Name resolves, connection refused/timeout | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | No ready endpoints, or wrong `targetPort` | Compare selector with pod labels; check named ports |
| ExternalName: connection refused | `kubectl get svc analytics -o yaml` | Client dials a port the target does not expose — ExternalName maps no ports | Use the target Service's port in the URL |
| `redis-0.redis-headless` NXDOMAIN | `kubectl get svc redis-headless` | Service not headless, or `serviceName` mismatch | `clusterIP: None`; `serviceName: redis-headless` |

## Configuration and Secrets

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `CreateContainerConfigError` | `kubectl describe pod` | Missing ConfigMap/Secret or key (names it) | Apply it first; check key spelling |
| Edited ConfigMap, nothing changed | `kubectl exec … printenv` | Env read at container start; subPath files never update | Roll the workload; use versioned/generated ConfigMaps |
| Replicas behave differently | `/api/info` from each pod → `config_version`, `code_length` | Mutable ConfigMap edited, some pods restarted | Immutable + versioned config; roll everything |
| `field is immutable when immutable is set` | — | Editing an immutable ConfigMap | Create a new version; point workloads at it |
| `password authentication failed` | `kubectl logs statefulset/postgres` | Secret changed after the database was initialised | `ALTER USER` in the DB, or restore the old Secret |
| Redis `NOAUTH` in probes / `redis-cli` | `kubectl exec redis-0 -- env \| grep REDISCLI` | `REDISCLI_AUTH` missing | Add it from the Secret |

## Storage (EBS)

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| PVC `Pending`, **no pod yet** | `kubectl describe pvc` | `WaitForFirstConsumer` — **correct** | Create the consumer |
| PVC `Pending`: `no storage class is set` | `kubectl get storageclass` | No `storageClassName`, no default class on EKS | Name `url-shortener-gp3` |
| PVC `Pending`: `waiting for a volume to be created … by external provisioner` | `kubectl get csidriver`; `kubectl logs -n kube-system deploy/ebs-csi-controller -c csi-provisioner` | EBS CSI driver missing or no IAM permission | Install the add-on with its Pod Identity role |
| Pod `Pending`: `volume node affinity conflict` | `kubectl get pv <pv> -o yaml \| grep -A6 nodeAffinity` | No schedulable node in the volume's AZ | Uncordon / add capacity in that AZ |
| `Multi-Attach error for volume` | `kubectl get pods -o wide` | RollingUpdate started a new pod on another node | `strategy: Recreate`, or a StatefulSet |
| `initdb: directory … exists but is not empty` | `kubectl logs` | `PGDATA` is the mount point (`lost+found`) | `PGDATA=/var/lib/postgresql/data/pgdata` |
| Redis `Permission denied` writing `/data` | `kubectl exec … ls -ld /data` | New EBS filesystem owned by root | `fsGroup: 1000` |
| Links gone after moving to a StatefulSet | `kubectl get pvc` | The StatefulSet created **new** claims | Migrate data (`pg_dump`), then delete old PVCs |
| `relation "links" does not exist` | `kubectl logs deploy/shortener-api -c migrate` | New empty database, migrations not re-run | Roll the API (stage 11's init container does this automatically) |

## Redis replication

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `X-Click-Counted: false`, `READONLY` | `/api/info` → `redis_write.role` | Writes via a load-balanced name | `REDIS_WRITE_HOST=redis-0.redis-headless…` |
| `master_link_status:down` | `kubectl logs redis-1` | Primary name unresolvable, or `masterauth` wrong | Fix the headless Service / Secret |
| Replica returns stale data briefly | — | Asynchronous replication / initial sync | Expected; read from the primary when freshness matters |
| Clicks lost while `redis-0` restarts | — | No failover in this design | Expected; Sentinel/operator/ElastiCache in production |

## Ingress and ALB

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| Ingress has no ADDRESS | `kubectl describe ingress`; `kubectl logs -n kube-system deploy/aws-load-balancer-controller` | Controller missing; wrong `ingressClassName` | Install controller; `ingressClassName: alb` |
| Event `couldn't auto-discover subnets` | — | Public subnets lack `kubernetes.io/role/elb=1` | Tag them (eksctl does this for its own VPC) |
| Event `AccessDenied` | `eksctl get podidentityassociation --cluster kubernetes-lab --region us-east-1` | Controller has no IAM role | Recreate the association; `serviceAccount.create=false` |
| `Could not resolve host` for the ALB | wait | DNS not propagated (first 1–3 min) | Retry |
| Requests **time out** | `curl https://checkip.amazonaws.com` vs `inbound-cidrs` | Your IP not allowed | Re-annotate with your current IP |
| **503** | `aws elbv2 describe-target-health` | No healthy targets: no ready pods, or health-check path fails | Fix readiness / `healthcheck-path` |
| **502** | same | Target refuses: wrong `targetPort`, app not listening | Fix the Service port |
| **404** plain body | `kubectl get ingress -o yaml` | No rule matched (e.g. a `host:` rule and the ALB hostname) | Remove `host` or send the Host header |
| Pods `READINESS GATES 0/1` | `kubectl describe pod` → conditions | ALB health check not passing yet | Wait ~20 s; else check `healthcheck-path` |
| Namespace stuck `Terminating` | `kubectl get ns url-shortener -o jsonpath='{.status.conditions}'` | Ingress finalizer, controller gone | Reinstall the controller; avoid removing the finalizer (orphans the ALB) |
| `eksctl delete cluster` fails on the VPC stack | EC2 console → Load Balancers, Network Interfaces | An orphaned ALB/ENI still in a subnet | Delete it, re-run |

## Probes and init containers

| Symptom | Investigate | Likely cause | Fix |
|---|---|---|---|
| `Init:0/1` | `kubectl logs <pod> -c migrate` | Waiting for PostgreSQL | Usually correct; check `POSTGRES_HOST` if it never ends |
| `Init:Error` / `Init:CrashLoopBackOff` | same | Migration failed / gave up | Fix the cause; the app container never started |
| `0/1 Running` | `kubectl describe pod` | Readiness failing — for the API, PostgreSQL | Check `postgres-0` first |
| `RESTARTS` rising, exit 137 | `kubectl describe pod` → `Last State` | Liveness failing, or OOM (`Reason: OOMKilled`) | Liveness on `/livez` only; Redis `maxmemory` < limit |
| Rollout stuck | `kubectl rollout status`; new pod events | New pod never Ready, `maxUnavailable: 0` holds | `kubectl rollout undo` |

### Exit codes

| Code | Means |
|---|---|
| `0` | Clean exit — for a long-running container the command is wrong |
| `1` | Application error — `kubectl logs --previous` |
| `137` | SIGKILL — liveness probe or OOM kill |
| `143` | SIGTERM — normal shutdown |
