# Kubernetes Resource Coverage Matrix

Which project teaches which resource, and at what depth.

| Symbol | Meaning |
|---|---|
| 🟩 | **Taught** — introduced from the problem it solves, with full manifest + explanation + failure lab |
| 🟨 | **Used** — appears and is briefly explained, but was taught in depth elsewhere |
| 🔵 | **Concept only** — explained in prose/diagram, not deployed (cost or platform constraint) |
| — | Not present |

> Reminder: projects are self-contained. A 🟨 still carries a short recap so you never have to leave the project.

---

## Workloads

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Pod | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| ReplicaSet | 🟩 | 🟨 | — | — | 🟨 | — | — | — | 🟨 | 🟨 |
| Deployment | 🟩 | 🟨 | 🟨 | 🟩 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| StatefulSet | — | 🟩 | 🟩 | 🟨 | — | — | — | 🟨 | 🟨 | 🟨 |
| DaemonSet | — | — | — | — | — | — | — | 🟩 | 🟨 | 🟨 |
| Job | — | — | 🟨 | — | — | 🟩 | — | — | — | 🟨 |
| CronJob | — | — | — | — | — | 🟩 | — | 🟨 | — | 🟨 |
| Static pod / `nodeName` | — | — | — | — | — | — | — | — | 🔵 | — |

## Networking

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ClusterIP Service | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| NodePort Service | — | 🟩 | 🟨 | — | 🟨 | — | — | 🟨 | — | 🟨 |
| LoadBalancer Service | 🔵 | 🟩¹ | — | 🟨 | 🟨 | — | — | — | — | 🟩 |
| Headless Service | — | 🟩 | 🟩 | 🟨 | — | — | — | 🟨 | 🟨 | 🟨 |
| ExternalName Service | — | — | 🟩 | 🟨 | — | — | — | — | — | 🟨 |
| Ingress | — | 🟩 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 |
| Ingress Controller | — | 🟩 | 🟨 | 🟨 | 🟨 | — | — | 🟨 | — | 🟩² |
| IngressClass | — | 🟩 | 🟨 | 🟨 | — | — | — | — | — | 🟨 |
| EndpointSlice | 🟩 | 🟨 | 🟨 | 🟩 | 🟨 | — | — | 🟨 | 🟨 | — |
| CoreDNS / service discovery | 🟩 | 🟨 | 🟩 | 🟩 | — | 🟨 | — | 🟨 | — | 🟨 |
| NetworkPolicy | — | — | — | 🟩 | — | — | 🟩 | 🟨 | — | 🟨 |
| Port forwarding | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 |
| Session affinity | — | — | — | 🟨 | 🔵 | — | — | — | — | 🟨 |
| CNI internals | 🔵 | — | — | 🔵 | — | — | 🔵 | — | 🔵 | 🔵 |

¹ On Kind via Cloud Provider KIND / MetalLB, with the differences from a real cloud LB made explicit.
² AWS Load Balancer Controller provisioning a real ALB.

## Configuration

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ConfigMap (env) | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| ConfigMap (volume / subPath) | — | 🟩 | 🟨 | 🟨 | — | 🟨 | — | 🟩 | — | 🟨 |
| Immutable ConfigMap | — | — | 🟩 | 🟨 | — | — | — | — | — | 🟨 |
| Secret (env / volume) | 🟩 | 🟨 | 🟨 | 🟨 | — | 🟨 | 🟩 | 🟨 | — | 🟨 |
| imagePullSecrets | — | — | — | — | — | — | 🟩 | — | — | 🟨 |
| TLS Secret | — | — | — | 🟨 | — | — | 🟨 | — | — | 🟩 |
| External secret managers | 🔵 | 🔵 | — | — | — | — | 🔵 | — | — | 🟩 |
| `checksum/config` rollout trigger | — | — | 🟩 | 🟨 | 🟨 | — | — | 🟨 | — | 🟨 |

## Storage

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| emptyDir | — | 🟩 | 🟨 | — | 🟨 | 🟩 | 🟨 | 🟨 | — | 🟨 |
| hostPath (demo only) | — | 🟩 | — | — | — | — | ⚠️🔵 | 🟨 | — | — |
| PersistentVolume | — | 🟩 | 🟨 | 🟨 | — | 🟨 | — | 🟨 | — | 🟨 |
| PersistentVolumeClaim | — | 🟩 | 🟩 | 🟨 | — | 🟩 | — | 🟨 | — | 🟩 |
| StorageClass | — | 🟩 | 🟨 | — | — | — | — | 🟨 | — | 🟩³ |
| Dynamic provisioning | — | 🟩 | 🟨 | 🟨 | — | 🟨 | — | 🟨 | — | 🟩 |
| Access modes | — | 🟩 | 🟨 | — | — | 🟩 | — | — | — | 🟨 |
| Reclaim policy | — | 🟩 | 🟨 | — | — | — | — | — | — | 🟨 |
| `volumeClaimTemplates` | — | 🟩 | 🟩 | — | — | — | — | 🟨 | 🟨 | 🟨 |
| Projected volumes | — | — | — | — | — | 🟩 | 🟨 | — | — | — |
| Volume snapshots | — | — | — | — | — | — | — | — | — | 🔵 |

³ `gp3` StorageClass backed by the EBS CSI driver.

## Scaling & Resources

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Manual / replica scaling | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | — | — | 🟨 | 🟨 |
| CPU/memory requests | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| CPU/memory limits | — | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| QoS classes | — | — | — | — | 🟩 | — | 🟨 | — | 🟨 | — |
| LimitRange | — | — | — | — | 🟩 | — | 🟩 | — | — | 🟨 |
| ResourceQuota | — | — | — | — | 🟨 | — | 🟩 | — | — | 🟨 |
| Metrics Server | — | — | — | — | 🟩 | — | — | 🟩 | 🟨 | 🟨 |
| HorizontalPodAutoscaler | — | — | — | 🟨 | 🟩 | 🟨 | — | 🟨 | 🟨 | 🟩 |
| HPA on custom metrics | — | — | — | — | 🔵 | — | — | 🔵 | — | 🔵 |
| VerticalPodAutoscaler | — | — | — | — | 🔵 | — | — | — | — | 🔵 |
| Cluster Autoscaler / Karpenter | — | — | — | — | — | — | — | — | 🔵 | 🟩 |

## Reliability

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Self-healing / restart policy | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | — | — | 🟨 | — |
| Readiness probe | 🟩 | 🟩 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 |
| Liveness probe | 🟩 | 🟩 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| Startup probe | 🟩 | — | 🟨 | — | 🟩 | — | — | 🟨 | — | 🟨 |
| Rolling update strategy | 🟩 | 🟨 | 🟨 | 🟨 | 🟩 | — | — | 🟨 | 🟨 | 🟨 |
| Rollback | 🟩 | 🟨 | — | 🟨 | 🟩 | — | — | — | — | 🟩 |
| PodDisruptionBudget | — | — | — | — | 🟩 | — | — | — | 🟩 | 🟨 |
| Graceful termination / preStop | — | — | 🟨 | — | 🟩 | 🟨 | — | — | 🟨 | 🟨 |
| Canary / blue-green | — | — | — | 🔵 | 🟩 | — | — | — | — | 🟩 |

## Scheduling

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| nodeSelector | — | — | — | — | 🟨 | — | — | 🟨 | 🟩 | 🟨 |
| Node affinity | — | — | — | — | — | — | — | 🟨 | 🟩 | 🟨 |
| Pod affinity | — | — | — | — | — | — | — | — | 🟩 | — |
| Pod anti-affinity | — | — | 🟨 | — | 🟨 | — | — | — | 🟩 | 🟩 |
| Taints & tolerations | — | — | — | — | — | — | — | 🟩⁴ | 🟩 | 🟨 |
| Topology spread constraints | — | — | — | — | — | — | — | — | 🟩 | 🟩 |
| PriorityClass / preemption | — | — | — | — | — | 🟨 | — | — | 🟩 | 🟨 |
| Cordon / drain / eviction | — | — | — | — | 🟩 | — | — | — | 🟩 | 🟨 |

⁴ node-exporter DaemonSet tolerating control-plane taints.

## Security

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Namespace | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 |
| ServiceAccount | — | — | — | — | — | 🟨 | 🟩 | 🟩 | — | 🟩⁵ |
| Role / RoleBinding | — | — | — | — | — | — | 🟩 | 🟨 | — | 🟨 |
| ClusterRole / ClusterRoleBinding | — | — | — | — | — | — | 🟩 | 🟩 | — | 🟨 |
| `kubectl auth can-i` | — | — | — | — | — | — | 🟩 | 🟨 | — | 🟨 |
| Pod/container securityContext | — | — | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 |
| runAsNonRoot / readOnlyRootFilesystem | — | — | — | — | 🟨 | 🟨 | 🟩 | 🟨 | — | 🟨 |
| Linux capabilities / seccomp | — | — | — | — | — | — | 🟩 | 🔵 | — | 🟨 |
| Pod Security Standards | — | — | — | — | — | — | 🟩 | 🟨 | — | 🟨 |
| Image scanning / trusted images | 🔵 | — | — | 🔵 | — | — | 🟩 | — | — | 🔵 |
| IRSA / workload identity | — | — | — | — | — | — | 🔵 | — | — | 🟩 |

⁵ ServiceAccount annotated for IRSA / EKS Pod Identity.

## Advanced Pod Configuration

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Init containers | — | 🟩 | 🟩 | 🟨 | — | 🟩 | 🟨 | 🟨 | — | 🟨 |
| Sidecar containers | — | — | 🟨 | — | — | 🟩 | 🟨 | 🟩 | — | 🟨 |
| Lifecycle hooks (postStart/preStop) | — | — | — | — | 🟩 | 🟩 | — | — | 🟨 | 🟨 |
| Downward API | 🟩 | — | — | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | — | — |
| Ephemeral debug containers | — | 🔵 | — | 🟨 | — | — | — | 🟩 | — | — |

## Delivery & Observability

| Resource | P01 | P02 | P03 | P04 | P05 | P06 | P07 | P08 | P09 | P10 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Labels / selectors / annotations | 🟩 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 |
| Kustomize | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 |
| Helm | — | — | — | — | — | — | — | 🟨⁶ | — | 🟩 |
| GitOps / reconcile loop | — | — | — | — | — | — | — | — | — | 🟩 |
| `logs` / `describe` / `events` | 🟩 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | 🟩 | 🟨 | 🟨 |
| `kubectl top` | — | — | — | — | 🟩 | — | — | 🟩 | 🟨 | 🟨 |
| Prometheus | — | — | — | — | 🔵 | — | — | 🟩 | 🟨 | 🟨 |
| Grafana | — | — | — | — | — | — | — | 🟩 | — | 🟨 |
| Alerting rules | — | — | — | — | — | — | — | 🟩 | — | 🔵 |
| Application metrics endpoint | — | — | 🟨 | 🟨 | 🟩 | 🟨 | — | 🟩 | — | 🟨 |
| Centralised logging | — | — | — | — | — | 🔵 | — | 🟩 | — | 🔵 |
| CloudWatch Container Insights | — | — | — | — | — | — | — | 🔵 | — | 🟩 |

⁶ Ingress controller / kube-prometheus installed via Helm, with `helm template` shown to demystify it.

---

## Coverage Self-Check

Every row above must contain **at least one 🟩** before the repository is considered complete. Rows that are 🔵-only
today and the plan to fix them:

| Gap | Current | Plan |
|---|---|---|
| VerticalPodAutoscaler | 🔵 | Candidate future "cost & capacity" project |
| Volume snapshots / backup-restore | 🔵 | Candidate future "disaster recovery" project |
| CNI internals | 🔵 | Deep dive in `docs/networking-basics.md`; not deployable content |
| Service mesh | — | Candidate future project |
| CRDs / Operators | — | Candidate future project |

Update this file **in the same commit** as any new project (see [CONTRIBUTING.md](../CONTRIBUTING.md)).
