# Module 2 — Deploy Apps the Kubernetes Way

[🏠 Reference home](../README.md) · Module 2 of 2

[Module 1 — Control Room](../01-control-room-for-containers/README.md) › **Module 2 — Deploy Apps**

---

## The story of this module

In Module 1 you learned how Kubernetes *thinks*. Now you'll use it. Across these six pages we build one small
application, a **Bookstore**, one object at a time. Each page adds exactly one thing, because the previous step
left a real problem behind.

| Page | We add… | Because without it… |
|---|---|---|
| 01 | **Namespace** `bookstore` | Our objects are mixed in with everyone else's in `default` |
| 02 | **Pod** running the web server | *(starting point)* We need something running at all |
| 03 | **Deployment** for the web server | A deleted or crashed Pod is simply gone, and there's only one copy |
| 04 | **ConfigMap** with settings and the web page | Changing a setting means rebuilding the image |
| 05 | **Secret** with the database password | Passwords would sit in plain text in Git and ConfigMaps |
| 06 | **StatefulSet** running PostgreSQL | A database in a Deployment loses its identity and its data |

## What we build, piece by piece

```mermaid
flowchart TB
    YOU["👩‍💻 You<br/>kubectl"]:::external

    subgraph NS["📦 Namespace: bookstore (page 01)"]
        direction TB
        subgraph WEB["Web tier"]
            DEP["Deployment/web<br/>replicas: 3 (page 03)"]:::workload
            RS["ReplicaSet/web-xxxx"]:::workload
            P1["Pod/web-…-a"]:::pod
            P2["Pod/web-…-b"]:::pod
            P3["Pod/web-…-c"]:::pod
        end
        CM["ConfigMap/web-config<br/>settings + index.html (page 04)"]:::config
        SEC["Secret/db-credentials<br/>POSTGRES_PASSWORD (page 05)"]:::config
        subgraph DB["Database tier"]
            STS["StatefulSet/postgres<br/>replicas: 1 (page 06)"]:::workload
            PG["Pod/postgres-0"]:::pod
            PVC[("PVC/data-postgres-0<br/>1Gi")]:::storage
        end
    end

    YOU --> NS
    DEP --> RS --> P1 & P2 & P3
    CM -.->|"env + mounted file"| P1
    SEC -.->|"env"| PG
    STS --> PG --> PVC

    classDef external fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef workload fill:#fef9c3,stroke:#ca8a04,stroke-width:2px,color:#713f12
    classDef pod      fill:#ffedd5,stroke:#ea580c,stroke-width:2px,color:#7c2d12
    classDef config   fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#831843
    classDef storage  fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
```

## Pages in this module

| # | Page | Key question | Time |
|---|---|---|---|
| 01 | [Namespaces](01-namespaces.md) | How do I give my app its own space? | 15 min |
| 02 | [Pods](02-pods.md) | What is the smallest unit Kubernetes runs? | 30 min |
| 03 | [Deployments](03-deployments.md) | How do I get self-healing, scaling, updates and rollback? | 35 min |
| 04 | [ConfigMaps](04-configmaps.md) | How do I separate configuration from the image? | 25 min |
| 05 | [Secrets](05-secrets.md) | How do I handle passwords and keys? | 25 min |
| 06 | [StatefulSets](06-statefulsets.md) | How do I run a database that keeps its data and identity? | 30 min |

## The Kubernetes way, in one sentence each

1. **Group it**: every app gets its own namespace.
2. **Never run bare Pods**: let a controller (Deployment or StatefulSet) own them.
3. **Describe, don't command**: YAML in Git, `kubectl apply -f`.
4. **Build once, configure everywhere**: the same image, with different ConfigMaps per environment.
5. **Keep secrets out of images and Git**: use Secrets.
6. **Pin every image tag**: never `:latest`.
7. **Label everything**: labels are how objects find each other.

> 🧪 **Try it:** Every page's `Try it` builds on the previous one, all inside the `bookstore` namespace. To start over
> at any time, run `kubectl delete namespace bookstore`. That one command removes everything in this module.

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Module 1 · 06 Networking & IPs](../01-control-room-for-containers/06-cluster-networking-and-ip-allocation.md)** | [Reference home](../README.md) | **[01 Namespaces](01-namespaces.md)** ▶ |
