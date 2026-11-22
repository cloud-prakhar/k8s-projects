# 📖 Glossary

[🏠 Reference home](README.md) · Every term used in both modules, in plain language

[Module 1 — Control Room](01-control-room-for-containers/README.md) · [Module 2 — Deploy Apps](02-deploy-apps-the-kubernetes-way/README.md)

---

Each entry links to the page that explains it in depth.

## A–C

| Term | Plain-language meaning | Learn it on |
|---|---|---|
| **Annotation** | A free-text key/value note on an object, read by tools and humans, never used for selecting | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **API group** | A family of related object types, e.g. `apps` (Deployments) or the core group (Pods) | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **API server** (`kube-apiserver`) | The cluster's front door. Every request goes through it, and only it talks to etcd. | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **`apiVersion`** | The `group/version` an object belongs to, e.g. `apps/v1` | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **CIDR** | Notation for an address range, e.g. `10.244.0.0/16` (≈65k addresses) | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **base64** | A text *encoding* used in Secret YAML. Reversible by anyone; **not** encryption. | [Secrets](02-deploy-apps-the-kubernetes-way/05-secrets.md) |
| **CNI** | Container Network Interface: the standard for plugins that give Pods IPs and connect them | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Cluster** | A set of nodes managed together by Kubernetes | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **ConfigMap** | An object holding non-sensitive settings, injected into Pods as env vars or files | [ConfigMaps](02-deploy-apps-the-kubernetes-way/04-configmaps.md) |
| **Container** | A running instance of an image: an isolated Linux process | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **Container runtime** | Node software that pulls images and runs containers, e.g. containerd, CRI-O | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **containerd** | The most common container runtime, used by Kind and EKS | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **Control loop / reconciliation** | Observe → compare desired vs actual → act → repeat | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **Control plane** | The "brain" components: API server, etcd, scheduler, controller manager | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Controller** | A program running one control loop for one kind of object | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Controller manager** | One program bundling many controllers (Deployment, ReplicaSet, Node…) | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **CrashLoopBackOff** | A container keeps crashing, and Kubernetes waits longer between restarts | [Pods](02-deploy-apps-the-kubernetes-way/02-pods.md) |
| **CRI** | Container Runtime Interface: the standard API between the kubelet and the runtime | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |

## D–I

| Term | Plain-language meaning | Learn it on |
|---|---|---|
| **Declarative** | Describe the end result ("3 replicas") and let the system get there | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **Deployment** | Keeps N identical Pods running; handles rolling updates and rollback | [Deployments](02-deploy-apps-the-kubernetes-way/03-deployments.md) |
| **Desired state** | What you asked for, in `spec` | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **Digest** | `@sha256:…` — a content fingerprint of an image; can never point to different content | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **etcd** | The key-value database that stores all cluster state | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Events** | Timestamped notes about what happened to an object; the bottom of `kubectl describe` | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **hostNetwork** | A Pod that uses its node's IP and ports instead of its own (control-plane Pods, kube-proxy, CNI agents) | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Headless Service** | A Service with `clusterIP: None`, used here to give StatefulSet Pods stable DNS names | [StatefulSets](02-deploy-apps-the-kubernetes-way/06-statefulsets.md) |
| **High availability (HA)** | Running several copies of something so one failure doesn't stop it | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **IPAM** | IP Address Management: the part of a CNI plugin that picks a free IP for each Pod | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Image** | A read-only, layered package of an app and everything it needs | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **ImagePullBackOff** | The node can't pull the image, and Kubernetes is retrying slower and slower | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **`imagePullPolicy`** | When to pull: `IfNotPresent`, `Always`, `Never` | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **Immutable** | Can't be changed after creation (e.g. a Deployment's selector, or a ConfigMap with `immutable: true`) | [ConfigMaps](02-deploy-apps-the-kubernetes-way/04-configmaps.md) |
| **Imperative** | Give step-by-step commands (`kubectl run`, `kubectl scale`) | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |

## K–O

| Term | Plain-language meaning | Learn it on |
|---|---|---|
| **Kind** | "Kubernetes in Docker": a cluster whose nodes are Docker containers, for learning | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **`kind`** (field) | The type of an object: `Pod`, `Deployment`… | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **kube-proxy** | Node component that programs network rules for Services | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **kubectl** | The command-line client that talks to the API server | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **kubelet** | The agent on every node that starts and watches that node's Pods | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Label / selector** | Key/value tags on objects, and the queries that find objects by those tags | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **Leader election** | Several copies of a component agree that only one is active at a time | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Lease** | A small object used as a "talking stick" for leader election and node heartbeats | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Manifest** | A YAML/JSON file describing one or more objects | [Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md) |
| **`maxSurge` / `maxUnavailable`** | How many extra or missing Pods a rolling update may use | [Deployments](02-deploy-apps-the-kubernetes-way/03-deployments.md) |
| **Multi-master** | A cluster with several control-plane nodes (official term: HA control plane) | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Namespace** | A virtual folder inside a cluster that scopes object names | [Namespaces](02-deploy-apps-the-kubernetes-way/01-namespaces.md) |
| **Node** | One machine (VM or physical) in the cluster | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Object** | A persistent record of intent stored in etcd (a Pod, a Deployment…) | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **OCI** | Open Container Initiative: the open standard for image format and runtimes | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **Owner reference** | A child object's pointer to its parent, which enables automatic clean-up | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |

## P–Z

| Term | Plain-language meaning | Learn it on |
|---|---|---|
| **pause container** | A tiny container that holds a Pod's network namespace, so the IP survives app-container restarts | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **PersistentVolumeClaim (PVC)** | A Pod's request for a disk that survives restarts | [StatefulSets](02-deploy-apps-the-kubernetes-way/06-statefulsets.md) |
| **Pod** | The smallest unit Kubernetes runs: one or more containers sharing an IP and volumes | [Pods](02-deploy-apps-the-kubernetes-way/02-pods.md) |
| **Pod CIDR** | The address range Pod IPs come from (Kind default `10.244.0.0/16`) | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Quorum** | The majority of etcd members (`floor(N/2)+1`) needed to elect a leader and commit writes | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Raft** | The consensus algorithm etcd uses to keep its members consistent | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Registry** | A server that stores images (Docker Hub, GHCR, ECR…) | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **ReplicaSet** | Keeps N identical Pods running. Created by a Deployment, one per version. | [Deployments](02-deploy-apps-the-kubernetes-way/03-deployments.md) |
| **Resource** (API) | An API endpoint holding objects of one kind, listed by `kubectl api-resources` | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **Rollback** | Return a Deployment to a previous revision (`kubectl rollout undo`) | [Deployments](02-deploy-apps-the-kubernetes-way/03-deployments.md) |
| **Rolling update** | Replace old Pods with new ones gradually, without downtime | [Deployments](02-deploy-apps-the-kubernetes-way/03-deployments.md) |
| **runc** | The low-level runtime that asks the Linux kernel to create a container process | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **Scheduler** (`kube-scheduler`) | Picks a node for each new Pod (filter → score → bind) | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |
| **Secret** | An object for sensitive values (passwords, keys), handled more carefully than ConfigMaps | [Secrets](02-deploy-apps-the-kubernetes-way/05-secrets.md) |
| **Service CIDR** | The range virtual Service IPs come from (Kind `10.96.0.0/16`, kubeadm `10.96.0.0/12`) | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Sidecar** | A helper container in the same Pod as the main app | [Pods](02-deploy-apps-the-kubernetes-way/02-pods.md) |
| **`spec` / `status`** | Desired state (written by you) / actual state (written by the cluster) | [API Resources](01-control-room-for-containers/04-api-resources-and-object-definitions.md) |
| **Split-brain** | Two halves of a cluster both acting as "in charge". Quorum prevents it. | [HA Control Plane](01-control-room-for-containers/05-high-availability-control-plane.md) |
| **Static Pod** | A Pod the kubelet starts from a file on the node, used for control-plane components | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **StatefulSet** | Runs Pods with stable names, one disk each, and ordered operations | [StatefulSets](02-deploy-apps-the-kubernetes-way/06-statefulsets.md) |
| **Tag** | A movable, human-friendly image label (`:1.27-alpine`). Never use `:latest`. | [Images & Runtime](01-control-room-for-containers/03-images-and-container-runtime.md) |
| **tmpfs** | A RAM-backed filesystem. Mounted Secrets use it, so they never touch the node's disk. | [Secrets](02-deploy-apps-the-kubernetes-way/05-secrets.md) |
| **VPC CNI** | AWS's CNI plugin: gives EKS Pods real IP addresses from the VPC subnet | [Networking & IPs](01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md) |
| **Worker node** | A node that runs application Pods | [Architecture](01-control-room-for-containers/02-kubernetes-architecture.md) |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Module 2 · 06 StatefulSets](02-deploy-apps-the-kubernetes-way/06-statefulsets.md)** | [🏠 Reference home](README.md) | **[Module 1 · 01 Fundamentals](01-control-room-for-containers/01-kubernetes-fundamentals.md)** ▶ |
