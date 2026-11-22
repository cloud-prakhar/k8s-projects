# Manual Steps — Project 04

Every command the scripts run, written out by hand and explained. **You can complete this entire project without
executing a single script.**

> **Why this file exists:** a script that "just works" teaches you a shell script, not Kubernetes. It also means a
> broken script never blocks learning — the manual path always exists.

Every command below gets three things:

▸ **What it does** — the command and its flags, in plain language
▸ **Expected output** — what success actually prints
▸ **If it fails** — the most likely cause and the next command to run

| Part | Script equivalent | Time |
|---|---|---|
| [1 — Cluster setup](#part-1--cluster-setup) | *(none for the cluster)*; checks + controller install are in `deploy.sh` | 25 min |
| [2 — Build and push the images](#part-2--build-and-push-the-images) | `build-images.sh` | 10 min (optional) |
| [3 — Deploy, stage by stage](#part-3--deploy-stage-by-stage) | `deploy.sh` (final state only) | 3 h |
| [4 — Validate](#part-4--validate) | `validate.sh` | 10 min |
| [5 — Cleanup](#part-5--cleanup) | `cleanup.sh` + cluster deletion | 20 min |

The **why** for each resource lives in `manifests/NN-*/README.md`. This file owns the operational sequence. All
commands run from the **project directory** (`project-04-ecommerce-microservices/`) unless stated otherwise.

> 💰 **The meter starts in Part 1** — about $0.22/hour for the cluster, plus ~$0.023/hour for the ALB and a few
> cents for two 1 GiB EBS volumes. Do Part 5 the same day. Project 05 uses the same cluster; if you are going
> straight on, delete only this project in Part 5 and keep the cluster.

---

# Part 1 — Cluster setup

## Step 1.1 — Confirm your AWS identity

```bash
aws sts get-caller-identity
# using a named profile? export AWS_PROFILE=<profile> first
```

▸ **What it does:** asks AWS which identity your credentials belong to. Everything eksctl creates is created as it.

▸ **Expected output:** JSON with `Account` and `Arn`.

▸ **If it fails:** `Unable to locate credentials` — `aws configure`, `aws sso login`, or export `AWS_PROFILE`.
**Make sure this is a lab account, not production.**

## Step 1.2 — Create the cluster

```bash
cd ..                                              # repository root
eksctl create cluster --config-file clusters/eks-advanced.yaml --dry-run | head -40
eksctl create cluster --config-file clusters/eks-advanced.yaml
cd project-04-ecommerce-microservices
```

▸ **What it does:** `--dry-run` prints the fully expanded config and creates nothing. The real command builds,
through CloudFormation: a VPC, the EKS 1.36 control plane, three t3.medium nodes, and the add-ons — the VPC CNI
**with `enableNetworkPolicy: "true"`**, CoreDNS, kube-proxy, the Pod Identity agent, the EBS CSI driver with its
IAM role, and Metrics Server — plus a Pod Identity association for the load balancer controller.

▸ **Expected output** (about 17 minutes in this project's verification run), ending:

```
all tasks were completed successfully
EKS cluster "kubernetes-lab" in "us-east-1" region is ready
```

▸ **If it fails:** `AlreadyExistsException` — a stack of that name exists: `eksctl get cluster --region us-east-1`.
A VPC or EIP quota error — delete an unused VPC or request an increase. A failed create leaves stacks behind:
`eksctl delete cluster --config-file clusters/eks-advanced.yaml`.

> **Tip:** `eksctl create cluster … --kubeconfig ~/.kube/lab.yaml` writes the credentials to their own file and
> leaves your default context alone. Then `export KUBECONFIG=~/.kube/lab.yaml` in the shells you use for the lab.
> If your default kubeconfig also holds a production cluster, do this.

## Step 1.3 — Confirm you are pointed at the lab, and that policy will be enforced

```bash
kubectl config current-context
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'
kubectl get crd policyendpoints.networking.k8s.aws
kubectl get storageclass
```

▸ **What it does:** shows the context, the three nodes and their AZs, the containers in the VPC CNI's DaemonSet,
the CRD the policy controller uses, and the storage classes.

▸ **Expected output:**

```
<you>@kubernetes-lab.us-east-1.eksctl.io
ip-192-168-19-227.ec2.internal   Ready   …   us-east-1f
ip-192-168-26-13.ec2.internal    Ready   …   us-east-1f
ip-192-168-38-55.ec2.internal    Ready   …   us-east-1a
aws-node aws-eks-nodeagent
policyendpoints.networking.k8s.aws   …
gp2   kubernetes.io/aws-ebs   Delete   WaitForFirstConsumer   false
```

▸ **If it fails:** only `aws-node` (no `aws-eks-nodeagent`) — the network policy agent is off; every policy in
stage 15 would be ignored. Fix the add-on configuration before going further. A production context — stop and
switch.

## Step 1.4 — Install the AWS Load Balancer Controller

```bash
VPC_ID=$(aws eks describe-cluster --region us-east-1 --name kubernetes-lab \
           --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 --namespace kube-system \
  --set clusterName=kubernetes-lab \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 --set vpcId="$VPC_ID" \
  --wait --timeout 5m
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get ingressclass
```

▸ **What it does:** installs (or upgrades — idempotent) the controller pinned to chart 3.5.0, reusing the
ServiceAccount eksctl created **with** its IAM association.

▸ **Expected output:** `aws-load-balancer-controller 2/2` and `IngressClass/alb`.

▸ **If it fails:** Ingress events with `AccessDenied` — the Pod Identity association is missing:
`eksctl get podidentityassociation --cluster kubernetes-lab --region us-east-1`.

> Cluster software, shared by every project on this cluster. `cleanup.sh` leaves it running.

---

# Part 2 — Build and push the images

Already public as `cloudprakhargupta/ecommerce:{storefront,catalog,cart,order,payment}-1.0.0`. **You can skip this
part.**

## Step 2.1 — Build, push and verify

```bash
docker login
REPO=cloudprakhargupta/ecommerce            # change to your own
for s in storefront catalog cart order payment; do
  docker build -t "$REPO:$s-1.0.0" "application/$s"
  docker push "$REPO:$s-1.0.0"
done
for s in storefront catalog cart order payment; do docker manifest inspect "$REPO:$s-1.0.0" >/dev/null && echo "ok $s"; done
```

▸ **What it does:** two-stage builds running as UID 10001; pushes; then asks the registry for each manifest —
"I built it" is not "a node can pull it".

▸ **Expected output:** five `digest: sha256:…` lines, then five `ok`.

▸ **If it fails:** `denied` — you do not own `REPO`. With your own repo, change `images[].newName` in
`manifests/19-final/kustomization.yaml` and substitute it in the stage manifests with `sed` as you apply them.

> Want to see the app work before Kubernetes? [`application/README.md`](../application/README.md) runs the whole
> call graph in plain Docker.

---

# Part 3 — Deploy, stage by stage

Read each stage README **before** its commands. The failures are the lesson.

## 3.1 — Namespace (stage 00) · 📖 [README](../manifests/00-namespace/README.md)

```bash
kubectl apply -f manifests/00-namespace/
```

▸ **Expected:** `namespace/ecommerce created`.

## 3.2 — Deployments (stage 03) · 📖 [README](../manifests/03-deployments/README.md)

```bash
kubectl apply -f manifests/03-deployments/
kubectl rollout status deployment/postgres -n ecommerce --timeout=180s
kubectl get deployments -n ecommerce
kubectl logs deployment/catalog -n ecommerce --tail=2
```

▸ **What it does:** seven Deployments and the PostgreSQL init ConfigMap.

▸ **Expected:** all `READY`, twelve pods — and
`failed to resolve host 'postgres': [Errno -2] Name or service not known`. **That is the lesson.**

▸ **If it fails:** `ImagePullBackOff` — Part 2's verify step.

## 3.3 — Services (stage 04) · 📖 [README](../manifests/04-services/README.md)

```bash
kubectl apply -f manifests/04-services/
kubectl get services,endpointslices -n ecommerce
kubectl logs deployment/catalog -n ecommerce --tail=1
kubectl run rogue --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n ecommerce -- \
  curl -s -X POST http://payment:8080/api/payments/authorize -H 'Content-Type: application/json' \
  -H 'X-Calling-Service: rogue' -d '{"amount_cents":999999}'
```

▸ **What it does:** seven Services; each EndpointSlice lists real pod IPs. The last command is a throwaway pod,
unrelated to checkout, calling payment directly.

▸ **Expected:** `schema up to date products=5`, and `"authorized": true` from the rogue pod.

▸ **If it fails:** empty `ENDPOINTS` — compare the Service selector with `kubectl get pods --show-labels`.

## 3.4 — ConfigMaps (stage 05) · 📖 [README](../manifests/05-configmaps/README.md)

```bash
kubectl apply -f manifests/05-configmaps/01-ecommerce-config.yaml      # ConfigMap FIRST
kubectl apply -f manifests/05-configmaps/
for d in storefront catalog cart order payment; do kubectl rollout status deployment/$d -n ecommerce; done
kubectl exec -n ecommerce deployment/order -- printenv \
  | grep -E '^(POSTGRES_(HOST|PORT|USER|DB)|PAYMENT_URL|UPSTREAM_TIMEOUT_SECONDS)=' | sort
```

▸ **Expected:** `POSTGRES_DB=orders` (owned, from the Deployment) alongside shared values from the ConfigMap.

▸ **If it fails:** `CreateContainerConfigError` — the ConfigMap was applied after the Deployments.

## 3.5 — Secrets (stage 06) · 📖 [README](../manifests/06-secrets/README.md)

```bash
kubectl apply -f manifests/06-secrets/01-postgres-secret.yaml -f manifests/06-secrets/02-redis-secret.yaml
kubectl apply -f manifests/06-secrets/
for d in postgres redis catalog cart order; do kubectl rollout status deployment/$d -n ecommerce; done
kubectl describe secret postgres-secret -n ecommerce | tail -2
kubectl exec -n ecommerce deployment/redis -- sh -c 'ps -o user,args | head -2; redis-cli ping'
```

▸ **Expected:** `POSTGRES_PASSWORD: 31 bytes`; `redis  redis-server *:6379` (no password, not root); `PONG`.

## 3.6 — Storage (stage 07) · 📖 [README](../manifests/07-storage/README.md)

```bash
kubectl apply -f manifests/07-storage/01-ecommerce-gp3-storageclass.yaml
kubectl apply -f manifests/07-storage/02-postgres-data-pvc.yaml -f manifests/07-storage/03-redis-data-pvc.yaml
kubectl get pvc -n ecommerce                                            # Pending — correct
kubectl apply -f manifests/07-storage/04-postgres-deployment.yaml -f manifests/07-storage/05-redis-deployment.yaml
kubectl rollout status deployment/postgres -n ecommerce --timeout=300s
kubectl rollout status deployment/redis -n ecommerce --timeout=300s
kubectl rollout restart deployment/catalog deployment/order -n ecommerce
kubectl get pvc -n ecommerce
```

▸ **What it does:** the StorageClass (cluster-scoped), two claims, then the consumers — which is when EBS volumes are
actually created. The restart re-creates schemas on the new, empty database.

▸ **Expected:** claims `Pending` before the Deployments, `Bound` after.

▸ **If it fails:** still `Pending` with a pod present — `kubectl describe pvc`: an `UnauthorizedOperation` means the
EBS CSI driver's IAM role is missing.

## 3.7 — StatefulSets (stage 08) · 📖 [README](../manifests/08-statefulsets/README.md)

```bash
kubectl delete deployment postgres redis -n ecommerce
kubectl wait --for=delete pod -l 'app.kubernetes.io/name in (postgres,redis)' -n ecommerce --timeout=120s
kubectl apply -f manifests/08-statefulsets/
kubectl rollout status statefulset/postgres -n ecommerce --timeout=300s
kubectl rollout status statefulset/redis -n ecommerce --timeout=300s
kubectl rollout restart deployment/catalog deployment/order -n ecommerce
kubectl delete pvc postgres-data redis-data -n ecommerce
```

▸ **What it does:** replaces the Deployments (delete first — same labels), creates headless Services and
StatefulSets with per-pod claims, re-creates schemas, removes the now-unused stage 07 claims.

▸ **Expected:** `postgres-0`, `redis-0` `Running`; claims `postgres-data-postgres-0`, `redis-data-redis-0` `Bound`.

## 3.8 — Ingress → ALB (stage 09) · 📖 [README](../manifests/09-ingress/README.md)

```bash
kubectl apply -f manifests/09-ingress/ecommerce-ingress.yaml
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl annotate ingress ecommerce-ingress -n ecommerce \
  alb.ingress.kubernetes.io/inbound-cidrs="${MY_IP}/32" --overwrite
ALB=$(kubectl get ingress ecommerce-ingress -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
until curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ALB/healthz" | grep -q 200; do echo waiting; sleep 10; done
curl -s -o /dev/null -w 'payment %{http_code}\n' "http://$ALB/api/payments/authorize"
```

▸ **What it does:** creates the Ingress; restricts the ALB to your public IP; waits for it to answer; confirms
payment is **not** routable.

▸ **Expected:** healthy after about two minutes (127 s in the verification run); `payment 404`.

▸ **If it fails:** no ADDRESS — `kubectl describe ingress`; timeouts forever — your IP changed.

## 3.9 — Probes and init containers (stage 11) · 📖 [README](../manifests/11-health-checks/README.md)

```bash
kubectl apply -f manifests/11-health-checks/01-ecommerce-namespace.yaml          # label FIRST
kubectl apply -f manifests/11-health-checks/02-postgres-statefulset.yaml -f manifests/11-health-checks/03-redis-statefulset.yaml
kubectl rollout status statefulset/postgres -n ecommerce --timeout=300s
kubectl rollout status statefulset/redis -n ecommerce --timeout=300s
kubectl apply -f manifests/11-health-checks/
for d in storefront catalog cart order payment; do kubectl rollout status deployment/$d -n ecommerce --timeout=400s; done
kubectl get pods -n ecommerce -o wide
```

▸ **Expected:** readiness gates `1/1` on storefront, catalog, cart and order; `<none>` on payment and the datastores
(not ALB targets).

▸ **If it fails:** `Init:0/1` — `kubectl logs <pod> -c migrate -n ecommerce`.

## 3.10 — NetworkPolicy (stage 15) · 📖 [README](../manifests/15-security/README.md)

Apply in the order the README teaches — the intermediate failures are the lesson:

```bash
kubectl apply -f manifests/15-security/01-default-deny-all.yaml      # everything breaks, DNS included
kubectl apply -f manifests/15-security/02-allow-dns-egress.yaml      # names resolve; connections time out
kubectl apply -f manifests/15-security/                               # the call graph, edge by edge
kubectl get networkpolicies,policyendpoints -n ecommerce
kubectl run rogue --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n ecommerce -- \
  curl -s -m 5 -o /dev/null -w 'exit=%{exitcode}\n' http://payment:8080/healthz
```

▸ **What it does:** ten policies; each creates a matching `PolicyEndpoint` that the node agent programs.

▸ **Expected:** ten policies and ten PolicyEndpoints; the rogue pod prints `exit=28` (timeout — dropped).

▸ **If it fails:** the rogue pod still connects — the agent is not enforcing (Step 1.3).

## 3.11 — The complete manifest (stage 19) · 📖 [README](../manifests/19-final/README.md)

```bash
kubectl kustomize manifests/19-final/ | less
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32#" | kubectl apply -f -
kubectl delete configmap ecommerce-config -n ecommerce --ignore-not-found
```

▸ **What it does:** renders the kustomization — a hash-named, immutable ConfigMap and every reference rewritten to
it — substitutes your IP into the Ingress (only the `inbound-cidrs:` key; the NetworkPolicy's `cidr:` is untouched),
applies, then removes the hand-written mutable ConfigMap.

▸ **Expected:** `configmap/ecommerce-config-<hash> created` and five Deployments rolling onto it.

> **This is what `scripts/deploy.sh` does**, preceded by checks that the context is an EKS cluster named
> `kubernetes-lab`, that the network policy agent and the EBS CSI driver exist, and that the load balancer
> controller is installed (installing it with Step 1.4 if not), and followed by waiting for every rollout and the
> ALB hostname. From an empty namespace it took 66 s in the verification run.

---

# Part 4 — Validate

Everything `validate.sh` asserts, by hand.

## Step 4.1 — Workloads, storage, readiness, endpoints

```bash
kubectl get statefulsets,deployments,pvc -n ecommerce
kubectl get pods -n ecommerce \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
for s in storefront catalog cart order payment postgres redis postgres-headless redis-headless; do
  echo -n "$s: "; kubectl get endpointslices -n ecommerce -l "kubernetes.io/service-name=$s" \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
done
```

▸ **Expected:** everything `1/1`/`2/2`, two claims `Bound`, `True` on every pod, an address for every Service.

## Step 4.2 — Policy: the allowed edge works, the denied edges are dropped

```bash
kubectl get networkpolicies -n ecommerce --no-headers | wc -l
kubectl exec -n ecommerce deploy/order -c order -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://payment:8080/healthz', timeout=4).status)"
kubectl run rogue --rm -i --restart=Never --image=postgres:17.5-alpine -n ecommerce -- sh -c \
  'wget -q -T 4 -O /dev/null http://payment:8080/healthz; echo "pay=$?"; pg_isready -h postgres -p 5432 -t 4 >/dev/null; echo "pg=$?"'
```

▸ **What it does:** counts policies; proves `order → payment` works; then a pod with no allowed edges tries payment
and PostgreSQL. `pg_isready` exits **2** for "no response"; `wget -T` exits non-zero on timeout.

▸ **Expected:** `10`, `200`, `pay=1` (or any non-zero), `pg=2`.

▸ **If it fails:** `pay=0` — payment answered a pod the policies do not name: enforcement is off, or
`allow-order-to-payment` / `default-deny-all` is missing.

## Step 4.3 — End to end through the ALB

```bash
ALB=$(kubectl get ingress ecommerce-ingress -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/api/catalog/products" | head -c 80; echo
curl -s -X POST "http://$ALB/api/cart/v1" -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1001","name":"k","price_cents":8900,"quantity":1}' | head -c 80; echo
curl -s -X POST "http://$ALB/api/orders" -H 'Content-Type: application/json' \
  -d '{"session":"v1","items":[{"sku":"SKU-1001","name":"k","price_cents":8900,"quantity":1}]}'; echo
curl -s -o /dev/null -w 'payment %{http_code}\n' "http://$ALB/api/payments/authorize"
curl -s -H 'Host: admin.shop.local' "http://$ALB/whoami" | head -c 80; echo
```

▸ **Expected:** products JSON; the basket; an order with a `payment_ref`; `payment 404`; `{"dependencies":…` from
the **order** service.

---

# Part 5 — Cleanup

Order matters. Two controllers created AWS resources for you, and only they delete them.

## Step 5.1 — Delete the Ingress first, and wait

```bash
kubectl delete ingress ecommerce-ingress -n ecommerce --wait=true --timeout=300s
```

▸ **What it does:** the Ingress carries finalizer `ingress.k8s.aws/resources`; the delete blocks until the
controller has deleted the ALB, target groups and security groups.

▸ **If it hangs:** the controller is not running — `kubectl get deploy aws-load-balancer-controller -n kube-system`.

## Step 5.2 — Delete the namespace and the StorageClass

```bash
kubectl delete namespace ecommerce --wait=true --timeout=600s
kubectl delete storageclass ecommerce-gp3 --ignore-not-found
kubectl get pv
```

▸ **What it does:** removes everything namespaced **including the StatefulSets' PVCs** (the namespace owns them);
`reclaimPolicy: Delete` makes the EBS CSI driver delete each volume. The StorageClass is cluster-scoped.

▸ **Expected:** `No resources found` from `get pv`.

## Step 5.3 — Check AWS for orphans

```bash
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=ecommerce \
  --query 'Volumes[].[VolumeId,State]' --output text
aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=ingress.k8s.aws/stack,Values=ecommerce/ecommerce-ingress \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

▸ **Expected:** both empty. In the verification run `cleanup.sh` finished in 58 s with no PV, EBS volume or ALB left.

## Step 5.4 — Delete the cluster (when finished with Projects 04 and 05)

```bash
kubectl get ingress,svc -A | grep -Ei 'alb|LoadBalancer' || echo "no load balancers left"
cd .. && eksctl delete cluster --config-file clusters/eks-advanced.yaml --disable-nodegroup-eviction
```

▸ **What it does:** confirms nothing would orphan a load balancer, then deletes the node group, add-on roles, Pod
Identity associations, control plane and VPC stacks.

▸ **If it fails:** `DELETE_FAILED` on the VPC stack — a load balancer or ENI still uses a subnet; delete it in the
EC2 console and re-run.

---

# Command reference used in this project

| Command | What it does |
|---|---|
| `eksctl create/delete cluster --config-file <f>` | Build / remove an EKS cluster from a ClusterConfig |
| `helm upgrade --install <rel> <chart> --version <v>` | Idempotent, pinned chart install |
| `kubectl config current-context` | Which cluster every command will hit |
| `kubectl apply -f <file\|dir>` / `kubectl kustomize <dir>` | Declarative apply / render a kustomization |
| `kubectl get <kind> -o wide` / `-o jsonpath='{…}'` | Extra columns / one field |
| `kubectl describe <kind> <name>` | State and Events |
| `kubectl logs <pod> -c <container>` | Logs; `-c` for init containers |
| `kubectl exec <res> -- <cmd>` | Run a command in a container |
| `kubectl run <n> --rm -i --restart=Never --image=<img> -- <cmd>` | Throwaway in-cluster client |
| `kubectl port-forward svc/<name> <l>:<r>` | Tunnel through the API server |
| `kubectl rollout status\|restart\|undo` | Wait for, trigger and revert rollouts |
| `kubectl set env` / `kubectl patch` / `kubectl annotate` | Imperative changes |
| `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | A Service's real backends |
| `kubectl get networkpolicies,policyendpoints` | Policies and what the controller resolved them to |
| `kubectl debug node/<node> --image=busybox:1.36` | A pod with the node's filesystem at `/host` |
| `kubectl get targetgroupbindings` | The ALB controller's per-Service target groups |
| `aws elbv2 describe-target-health` / `aws ec2 describe-volumes` | What AWS thinks of targets / find volumes by tag |
| `docker manifest inspect <image>` | Does the registry really have this tag? |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Stage 19 — Final](../manifests/19-final/README.md)** | [Project 04](../README.md) | **[Troubleshooting](../troubleshooting/common-errors.md)** ▶ |
