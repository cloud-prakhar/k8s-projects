# Cluster Configurations

Reusable Kind cluster definitions. Each project's README states which one it needs.

| Config | Nodes | Ports 80/443 | Zone labels | Used by |
|---|---|---|---|---|
| [`kind-single-node.yaml`](kind-single-node.yaml) | 1 (control-plane) | ❌ | ❌ | P01 |
| [`kind-ingress.yaml`](kind-ingress.yaml) | 2 (cp + worker) | ✅ | ❌ | P02, P03, P04, P06 |
| [`kind-multi-node.yaml`](kind-multi-node.yaml) | 4 (cp + 3 workers) | ✅ | ✅ `zone-a/b/c` | P05, P07, P08, P09 |

All three use the cluster name `kubernetes-lab`, so the kube-context is always `kind-kubernetes-lab`.

---

## Usage

```bash
# Create
kind create cluster --name kubernetes-lab --config clusters/kind-ingress.yaml

# Confirm you're pointed at it
kubectl config current-context           # → kind-kubernetes-lab
kubectl get nodes -o wide

# Recreate from scratch (faster and safer than debugging a polluted cluster)
kind delete cluster --name kubernetes-lab
kind create cluster --name kubernetes-lab --config clusters/kind-multi-node.yaml
```

> ⚠️ `extraPortMappings` and node labels are **creation-time only**. You cannot add them to a running cluster —
> switching projects sometimes means recreating. That takes about a minute.

---

## Add-ons

### NGINX Ingress Controller (needed by any project using Ingress)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

kubectl get ingressclass          # your Ingress must reference this class
```

Applying an Ingress before the controller's admission webhook is ready produces
`failed calling webhook "validate.nginx.ingress.kubernetes.io"` — that's what the `wait` prevents.

### Metrics Server (needed by `kubectl top` and HPA)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Kind's kubelet serving certs aren't signed by the cluster CA, so metrics-server
# refuses to scrape until you tell it to skip that verification. Lab-only.
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system
kubectl top nodes
```

### Policy-enforcing CNI (needed for NetworkPolicy labs)

Kind's default CNI (kindnet) **accepts NetworkPolicy objects and ignores them** — you can apply a `default-deny` and
watch traffic flow anyway. Projects 04 and 07 install Calico and prove enforcement before teaching the rules.

### LoadBalancer support

`type: LoadBalancer` stays `<pending>` on Kind forever unless you install Cloud Provider KIND or MetalLB. That is
correct behaviour, not a bug — see [`docs/local-vs-cloud.md`](../docs/local-vs-cloud.md#3-external-access--the-four-options-honestly).

---

## Hosts file

Host-based Ingress routing needs your machine to resolve the demo hostnames:

```bash
sudo tee -a /etc/hosts <<'ENTRIES'
127.0.0.1  notes.local shop.local short.local tasks.local grafana.local
ENTRIES
```

Alternative: use `nip.io` (`app.127.0.0.1.nip.io`) and skip `/etc/hosts` entirely.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kind create` fails immediately | Docker not running | `docker ps` |
| Cluster exists already | Name clash | `kind get clusters`, reuse or delete |
| `localhost:80` refused | Cluster created without `extraPortMappings` | Recreate with `kind-ingress.yaml` |
| Pods `Pending` on a single-node cluster | Not enough CPU/memory allocated to Docker | Raise Docker Desktop / WSL resource limits |
| `ImagePullBackOff` for a local image | Image not loaded into the node | `kind load docker-image <img> --name kubernetes-lab` |
| `kubectl` targets the wrong cluster | Stale context | `kubectl config use-context kind-kubernetes-lab` |


---

## Official references

*(All links verified 2026-08-09.)*

| Reference | What it covers |
|---|---|
| [Kind — quick start](https://kind.sigs.k8s.io/docs/user/quick-start/) | Cluster creation, multi-node config, `kind load docker-image` |
| [Kind — Ingress](https://kind.sigs.k8s.io/docs/user/ingress/) | `extraPortMappings`, the `ingress-ready` node label, NGINX setup |
| [Kind — LoadBalancer](https://kind.sigs.k8s.io/docs/user/loadbalancer/) | Why `type: LoadBalancer` stays `<pending>`, and how to fix it locally |
| [ingress-nginx installation](https://kubernetes.github.io/ingress-nginx/deploy/) | The controller manifest used above, per provider |
| [Metrics Server](https://kubernetes-sigs.github.io/metrics-server/) | Requirements, including the Kind TLS caveat |
| [Cluster networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/) | The Pod-network model and CNI requirements |
| [Network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | States plainly that a policy-enforcing CNI is required |
