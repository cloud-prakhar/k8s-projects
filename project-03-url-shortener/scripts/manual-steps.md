# Manual Steps — Project 03

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
| [1 — Cluster setup](#part-1--cluster-setup) | *(none for the cluster)*; controller install is in `deploy.sh` | 25 min |
| [2 — Build and push the images](#part-2--build-and-push-the-images) | `build-images.sh` | 10 min |
| [3 — Deploy, stage by stage](#part-3--deploy-stage-by-stage) | `deploy.sh` (final state only) | 2.5 h |
| [4 — Validate](#part-4--validate) | `validate.sh` | 10 min |
| [5 — Cleanup](#part-5--cleanup) | `cleanup.sh` + cluster deletion | 20 min |

The **why** for each resource lives in `manifests/NN-*/README.md`. This file owns the operational sequence. All
commands run from the **project directory** (`project-03-url-shortener/`) unless stated otherwise.

> 💰 **The meter starts in Part 1.** About $0.25/hour with the ALB. Do Part 5 the same day.

---

# Part 1 — Cluster setup

## Step 1.1 — Confirm your AWS identity

```bash
aws sts get-caller-identity
# using a named profile? export it first:  export AWS_PROFILE=<profile>
```

▸ **What it does:** asks AWS which identity your credentials belong to. Everything eksctl creates is created as
this identity, in this account.

▸ **Expected output:** JSON with `Account` and `Arn`.

▸ **If it fails:** `Unable to locate credentials` — run `aws configure` or `aws sso login`, or export
`AWS_PROFILE`. **Make sure this is a lab account, not production.**

## Step 1.2 — Create the cluster

```bash
cd ..                                              # repository root
eksctl create cluster --config-file clusters/eks-lab.yaml --dry-run | head -40
eksctl create cluster --config-file clusters/eks-lab.yaml
cd project-03-url-shortener
```

▸ **What it does:** `--dry-run` prints the fully expanded config without creating anything. The real command
builds, through CloudFormation: a VPC with public/private subnets across availability zones, the EKS control plane
(Kubernetes 1.36), a managed node group of 2 × t3.medium, the add-ons (VPC CNI, CoreDNS, kube-proxy, EKS Pod
Identity agent, **EBS CSI driver** with its IAM role), and a Pod Identity association giving the ServiceAccount
`kube-system/aws-load-balancer-controller` its IAM permissions. It then writes a kube-context and makes it current.

▸ **Expected output** (15–20 minutes), ending with:

```
created serviceaccount "kube-system/aws-load-balancer-controller"
created pod identity association for service account "aws-load-balancer-controller" in namespace "kube-system"
all tasks were completed successfully
EKS cluster "kubernetes-lab" in "us-east-1" region is ready
```

▸ **If it fails:** `AlreadyExistsException` — a stack or cluster of that name exists; `eksctl get cluster
--region us-east-1`. VPC or Elastic IP limit errors — the account is at a quota (`VpcLimitExceeded`); delete an
unused VPC or request an increase. A failed create leaves CloudFormation stacks behind: `eksctl delete cluster
--config-file clusters/eks-lab.yaml` removes them.

## Step 1.3 — Confirm you are pointed at the lab

```bash
kubectl config current-context
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -n kube-system
kubectl get storageclass
```

▸ **What it does:** shows the current context, the nodes with their availability zone, the system pods, and the
storage classes.

▸ **Expected output:**

```
<you>@kubernetes-lab.us-east-1.eksctl.io

NAME                             STATUS   ROLES    VERSION               ZONE
ip-192-168-18-0.ec2.internal     Ready    <none>   v1.36.3-eks-…         us-east-1b
ip-192-168-48-247.ec2.internal   Ready    <none>   v1.36.3-eks-…         us-east-1a

aws-node-…  coredns-…  ebs-csi-controller-…  ebs-csi-node-…  eks-pod-identity-agent-…  kube-proxy-…  metrics-server-…

NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
gp2    kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false
```

▸ **Note:** two nodes in **two different AZs**, and `gp2` is **not** marked `(default)`. Stage 07 is built on both
facts.

▸ **If it fails:** the wrong context — `kubectl config get-contexts`, then `kubectl config use-context <lab>`.
Never continue while a production context is current.

## Step 1.4 — Install the AWS Load Balancer Controller

```bash
VPC_ID=$(aws eks describe-cluster --region us-east-1 --name kubernetes-lab \
           --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 --namespace kube-system \
  --set clusterName=kubernetes-lab \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId="$VPC_ID" \
  --wait --timeout 5m
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get ingressclass
```

▸ **What it does:** `--query … --output text` extracts the VPC ID. `helm upgrade --install` installs the chart if
absent or upgrades it if present — idempotent. `--version 3.5.0` pins the chart (controller v3.5.0).
`serviceAccount.create=false` reuses the ServiceAccount eksctl created **with** its IAM association. `--wait` blocks
until the controller's pods are Ready.

▸ **Expected output:** `aws-load-balancer-controller 2/2`, and `IngressClass/alb` with controller
`ingress.k8s.aws/alb`.

▸ **If it fails:** pods `CrashLoopBackOff` with `failed to get VPC ID` — `vpcId`/`region` missing. Later Ingress
events saying `AccessDenied` — the Pod Identity association is missing: `eksctl get podidentityassociation
--cluster kubernetes-lab --region us-east-1`.

> This is **cluster software**, shared by every project on this cluster. `cleanup.sh` leaves it running.

---

# Part 2 — Build and push the images

The images are already public as `cloudprakhargupta/url-shortener:{api,web,collector}-1.0.0`. **You can skip this
part.** Do it if you change the application or want your own registry.

## Step 2.1 — Authenticate

```bash
docker login
# ECR instead:
# aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
```

▸ **What it does:** stores a credential for `docker push`. EKS nodes pull *public* images without it.

## Step 2.2 — Build and push all three

```bash
REPO=cloudprakhargupta/url-shortener         # change to your own
for c in api web collector; do
  docker build -t "$REPO:$c-1.0.0" "application/$c"
  docker push "$REPO:$c-1.0.0"
done
```

▸ **What it does:** two-stage builds (dependencies in a build stage, only the virtualenv copied to the runtime
image), running as UID 10001; then uploads each image.

▸ **Expected output:** each push ends with `<tag>: digest: sha256:… size: …`.

▸ **If it fails:** `denied: requested access to the resource is denied` — you do not own `REPO`.

## Step 2.3 — Verify the registry really has them

```bash
for c in api web collector; do docker manifest inspect "$REPO:$c-1.0.0" >/dev/null && echo "ok $c"; done
```

▸ **What it does:** asks the registry for each manifest without downloading. "I built it" is not "a node can pull
it" — skipping this is how you get `ImagePullBackOff`.

▸ **If you used your own `REPO`:** change `images[].newName` in `manifests/19-final/kustomization.yaml`, and
substitute your repo in the stage manifests with `sed` as you apply them.

## Step 2.4 (optional) — Run it in plain Docker first

```bash
docker network create us-test
docker run -d --name pg --network us-test -e POSTGRES_DB=shortener -e POSTGRES_USER=shortener -e POSTGRES_PASSWORD=devpw postgres:17.5-alpine
docker run -d --name redis --network us-test redis:8.2.9-alpine redis-server --requirepass rpw
docker run -d --name analytics --network us-test cloudprakhargupta/url-shortener:collector-1.0.0
docker run -d --name api --network us-test -p 18081:8080 \
  -e POSTGRES_HOST=pg -e POSTGRES_PASSWORD=devpw -e REDIS_WRITE_HOST=redis -e REDIS_PASSWORD=rpw \
  -e ANALYTICS_URL=http://analytics:8080/events cloudprakhargupta/url-shortener:api-1.0.0
sleep 10
curl -s -X POST localhost:18081/api/links -H 'Content-Type: application/json' -d '{"url":"https://kubernetes.io"}'
docker rm -f pg redis analytics api && docker network rm us-test
```

▸ **What it does:** proves the application works before Kubernetes is involved. Docker's embedded DNS makes the
container names resolvable — exactly what Kubernetes will *not* do for you in stage 03.

---

# Part 3 — Deploy, stage by stage

Read each stage README **before** running its commands. The failures are the lesson.

## 3.1 — Namespaces (stage 00)

📖 [`manifests/00-namespace/README.md`](../manifests/00-namespace/README.md)

```bash
kubectl apply -f manifests/00-namespace/
kubectl get namespaces url-shortener analytics
```

▸ **What it does:** creates both scopes. ▸ **Expected:** two `Active` namespaces.

## 3.2 — Deployments (stage 03)

📖 [`manifests/03-deployments/README.md`](../manifests/03-deployments/README.md)

```bash
kubectl apply -f manifests/03-deployments/
kubectl rollout status deployment/postgres -n url-shortener --timeout=180s
kubectl get pods -n url-shortener -o wide
kubectl logs deployment/shortener-api -n url-shortener --tail=3
```

▸ **What it does:** five Deployments; `rollout status` waits properly; `logs deployment/…` picks one pod.

▸ **Expected output:** everything `Running` — and the API logging `failed to resolve host 'postgres'`. **That is
the lesson, not a mistake.**

▸ **If it fails:** `ImagePullBackOff` — the image tag is not in the registry (Part 2.3).

## 3.3 — Services, DNS, ExternalName (stage 04)

📖 [`manifests/04-services/README.md`](../manifests/04-services/README.md)

```bash
kubectl apply -f manifests/04-services/
kubectl get services,endpointslices -n url-shortener
kubectl logs deployment/shortener-api -n url-shortener --tail=3
kubectl exec -n url-shortener deployment/shortener-api -- python -c \
  "import socket; [print(n, socket.gethostbyname(n)) for n in ['postgres','redis','analytics','analytics-collector.analytics']]"
```

▸ **What it does:** six Services; the EndpointSlices show real backends; the API's own resolver proves the names.

▸ **Expected output:** `schema up to date versions=2` in the logs; four names resolving to `10.100.x.x` addresses.

▸ **If it fails:** empty `ENDPOINTS` — selector mismatch: compare `kubectl get svc <name> -o jsonpath='{.spec.selector}'`
with `kubectl get pods --show-labels`.

**Use it:**

```bash
kubectl port-forward -n url-shortener svc/shortener-web 8080:80 &
sleep 3
curl -s -X POST localhost:8080/api/links -H 'Content-Type: application/json' -d '{"url":"https://kubernetes.io"}'
kill %1
```

▸ **What it does:** a tunnel through the EKS API server to one pod behind the Service. ▸ **Expected:** JSON with a
`code` and `short_url`.

## 3.4 — ConfigMaps: mutable, drift, immutable (stage 05)

📖 [`manifests/05-configmaps/README.md`](../manifests/05-configmaps/README.md)

```bash
kubectl apply -f manifests/05-configmaps/01-shortener-config.yaml -f manifests/05-configmaps/02-redis-config.yaml
kubectl apply -f manifests/05-configmaps/03-shortener-api-deployment.yaml \
              -f manifests/05-configmaps/04-shortener-web-deployment.yaml \
              -f manifests/05-configmaps/05-redis-deployment.yaml
kubectl rollout status deployment/shortener-api -n url-shortener
kubectl rollout status deployment/redis -n url-shortener
kubectl exec -n url-shortener deployment/redis -- redis-cli config get maxmemory-policy
```

▸ **What it does:** ConfigMaps first, then workloads that consume them. The last command proves Redis read the
mounted file. ▸ **Expected:** `volatile-lru`.

▸ **If it fails:** `CreateContainerConfigError` — `kubectl describe pod` names the missing ConfigMap or key.

**The drift outage** — stage 05 §9 has the full commands: patch `CODE_LENGTH` to `10`, delete one API pod, loop
`curl` against an old code and see `404 302 404 302`. Then the fix:

```bash
kubectl apply -f manifests/05-configmaps/06-shortener-config-v1.yaml
kubectl apply -f manifests/05-configmaps/07-shortener-api-deployment-v1.yaml \
              -f manifests/05-configmaps/08-shortener-web-deployment-v1.yaml
kubectl rollout status deployment/shortener-api -n url-shortener
kubectl patch configmap shortener-config-v1 -n url-shortener --type merge -p '{"data":{"CODE_LENGTH":"10"}}'
kubectl delete configmap shortener-config -n url-shortener
```

▸ **Expected:** the `patch` fails with `field is immutable when immutable is set`.

## 3.5 — Secrets (stage 06)

📖 [`manifests/06-secrets/README.md`](../manifests/06-secrets/README.md)

```bash
kubectl apply -f manifests/06-secrets/01-postgres-secret.yaml -f manifests/06-secrets/02-redis-secret.yaml
kubectl apply -f manifests/06-secrets/03-postgres-deployment.yaml \
              -f manifests/06-secrets/04-redis-deployment.yaml \
              -f manifests/06-secrets/05-shortener-api-deployment.yaml
kubectl rollout status deployment/postgres -n url-shortener
kubectl rollout status deployment/redis -n url-shortener
kubectl rollout status deployment/shortener-api -n url-shortener
kubectl describe secret redis-secret -n url-shortener | tail -2
kubectl exec -n url-shortener deployment/redis -- sh -c 'ps -o args | head -2; redis-cli ping'
```

▸ **What it does:** Secrets first; then three workloads rolled onto them. `describe` shows byte counts, not
values; `ps` proves the password is not on Redis's command line; `redis-cli` authenticates via `REDISCLI_AUTH`.

▸ **Expected:** `REDIS_PASSWORD: 37 bytes`, `redis-server 0.0.0.0:6379`, `PONG`.

▸ **Note:** the PostgreSQL and Redis pods were replaced with no volumes — **every link and click is gone**. That is
stage 07's opening.

## 3.6 — Storage (stage 07)

📖 [`manifests/07-storage/README.md`](../manifests/07-storage/README.md)

```bash
kubectl apply -f manifests/07-storage/01-url-shortener-gp3-storageclass.yaml
kubectl apply -f manifests/07-storage/02-postgres-data-pvc.yaml -f manifests/07-storage/03-redis-data-pvc.yaml
kubectl describe pvc postgres-data -n url-shortener | tail -1
kubectl apply -f manifests/07-storage/04-postgres-deployment.yaml -f manifests/07-storage/05-redis-deployment.yaml
kubectl rollout status deployment/postgres -n url-shortener --timeout=300s
kubectl rollout status deployment/redis -n url-shortener --timeout=300s
kubectl rollout restart deployment/shortener-api -n url-shortener
kubectl rollout status deployment/shortener-api -n url-shortener
kubectl get pvc,pv -n url-shortener
```

▸ **What it does:** the StorageClass (cluster-scoped), two claims, then the Deployments that consume them — which is
when EBS volumes are actually created. The API restart re-runs migrations against the new, empty database.

▸ **Expected:** claims `Pending` with `waiting for first consumer` **before** the Deployments; `Bound` after.

▸ **If it fails:** `Pending` after the pod exists — `kubectl describe pvc`: `UnauthorizedOperation` means the EBS
CSI driver's IAM role is missing; `ebs.csi.aws.com not found` means the add-on is missing.

**Find the real volume:**

```bash
PV=$(kubectl get pvc postgres-data -n url-shortener -o jsonpath='{.spec.volumeName}')
VOL=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 describe-volumes --region us-east-1 --volume-ids "$VOL" \
  --query 'Volumes[0].[VolumeType,Size,Encrypted,AvailabilityZone,State]' --output text
```

▸ **Expected:** `gp3 1 True us-east-1x in-use`.

## 3.7 — StatefulSets and per-pod DNS (stage 08)

📖 [`manifests/08-statefulsets/README.md`](../manifests/08-statefulsets/README.md)

```bash
kubectl delete deployment redis -n url-shortener
kubectl wait --for=delete pod -l app.kubernetes.io/name=redis -n url-shortener --timeout=90s
kubectl apply -f manifests/08-statefulsets/01-redis-headless-service.yaml -f manifests/08-statefulsets/02-redis-statefulset.yaml
kubectl rollout status statefulset/redis -n url-shortener --timeout=300s
kubectl exec -n url-shortener redis-1 -- redis-cli info replication | grep -E '^role|master_link_status'
```

▸ **What it does:** replaces the Deployment (delete first — same labels), creates the headless Service and the
StatefulSet, and checks the replica is following the primary.

▸ **Expected:** `role:slave`, `master_link_status:up`.

**The READONLY failure, then config v2** — commands in stage 08 §6.2. Then:

```bash
kubectl apply -f manifests/08-statefulsets/03-shortener-config-v2.yaml -f manifests/08-statefulsets/04-shortener-api-deployment.yaml
kubectl rollout status deployment/shortener-api -n url-shortener

kubectl delete deployment postgres -n url-shortener
kubectl wait --for=delete pod -l app.kubernetes.io/name=postgres -n url-shortener --timeout=120s
kubectl apply -f manifests/08-statefulsets/05-postgres-headless-service.yaml -f manifests/08-statefulsets/06-postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n url-shortener --timeout=300s
kubectl rollout restart deployment/shortener-api -n url-shortener
kubectl rollout status deployment/shortener-api -n url-shortener
kubectl delete pvc postgres-data redis-data -n url-shortener
```

▸ **If it fails:** replica `master_link_status:down` — `kubectl logs redis-1 -n url-shortener`; NXDOMAIN on the
primary's name means `serviceName` or the headless Service is wrong.

## 3.8 — Ingress → ALB (stage 09)

📖 [`manifests/09-ingress/README.md`](../manifests/09-ingress/README.md)

```bash
kubectl apply -f manifests/09-ingress/01-url-shortener-ingress.yaml
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl annotate ingress url-shortener-ingress -n url-shortener \
  alb.ingress.kubernetes.io/inbound-cidrs="${MY_IP}/32" --overwrite
kubectl get ingress -n url-shortener
ALB=$(kubectl get ingress url-shortener-ingress -n url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
until curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ALB/healthz" | grep -q 200; do echo waiting; sleep 10; done
curl -s "http://$ALB/api/info" | head -c 200; echo
```

▸ **What it does:** creates the Ingress; restricts the ALB to your public IP; waits for the ALB to answer.

▸ **Expected:** an `ADDRESS` ending in `elb.amazonaws.com` within seconds; `200` after 2–3 minutes; JSON.

▸ **If it fails:** no ADDRESS — `kubectl describe ingress …` events. Timeouts forever — your IP changed or is not
in `inbound-cidrs`. `503` — no healthy targets: `kubectl get endpointslices -n url-shortener`.

## 3.9 — Probes, init container, readiness gates (stage 11)

📖 [`manifests/11-health-checks/README.md`](../manifests/11-health-checks/README.md)

```bash
kubectl apply -f manifests/11-health-checks/01-url-shortener-namespace.yaml
kubectl apply -f manifests/11-health-checks/02-postgres-statefulset.yaml -f manifests/11-health-checks/03-redis-statefulset.yaml
kubectl rollout status statefulset/postgres -n url-shortener --timeout=300s
kubectl rollout status statefulset/redis -n url-shortener --timeout=300s
kubectl apply -f manifests/11-health-checks/04-shortener-api-deployment.yaml \
              -f manifests/11-health-checks/05-shortener-web-deployment.yaml \
              -f manifests/11-health-checks/06-analytics-collector-deployment.yaml
kubectl rollout status deployment/shortener-api -n url-shortener --timeout=300s
kubectl get pods -n url-shortener -o wide
kubectl logs -n url-shortener -l app.kubernetes.io/name=shortener-api -c migrate --tail=2
```

▸ **What it does:** labels the namespace for ALB readiness gates, adds probes to both StatefulSets, then the
Deployments with the `migrate` init container. `-c migrate` selects the init container's logs.

▸ **Expected:** `READINESS GATES 1/1` on API and web pods; `schema up to date versions=2`.

▸ **If it fails:** pods stuck `0/1` with gates `0/1` — the ALB health check is failing:
`aws elbv2 describe-target-health`. `Init:0/1` — PostgreSQL not reachable.

## 3.10 — The complete manifest (stage 19)

📖 [`manifests/19-final/README.md`](../manifests/19-final/README.md)

```bash
kubectl kustomize manifests/19-final/ | less
MY_IP=$(curl -s https://checkip.amazonaws.com)
kubectl kustomize manifests/19-final/ | sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${MY_IP}/32#" | kubectl apply -f -
kubectl rollout status statefulset/redis -n url-shortener --timeout=400s
kubectl rollout status deployment/shortener-api -n url-shortener --timeout=400s
kubectl delete configmap shortener-config-v1 shortener-config-v2 redis-config -n url-shortener --ignore-not-found
```

▸ **What it does:** renders the kustomization (generated, hash-named, immutable ConfigMaps), substitutes your CIDR,
applies. Workloads roll onto the generated ConfigMaps; the hand-versioned ones are then removed.

▸ **Expected:** `configmap/shortener-config-<hash> created`, `configmap/redis-config-<hash> created`.

> **This is exactly what `scripts/deploy.sh` does**, preceded by checks that the context is an EKS cluster named
> `kubernetes-lab`, that the EBS CSI driver exists, and that the load balancer controller is installed (installing
> it with the Step 1.4 commands if not), and followed by waiting for rollouts and the ALB hostname.

---

# Part 4 — Validate

Everything `validate.sh` asserts, by hand.

## Step 4.1 — Workloads, storage and readiness

```bash
kubectl get statefulsets,deployments,pvc -n url-shortener
kubectl get deployment analytics-collector -n analytics
kubectl get pods -n url-shortener \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

▸ **What it does:** readiness **condition** per pod — which includes ALB readiness gates.

▸ **Expected:** `postgres 1/1`, `redis 2/2`, both Deployments `2/2`, collector `1/1`; three PVCs `Bound`; `True`
on every line.

## Step 4.2 — Services have endpoints

```bash
for s in postgres redis redis-headless shortener-api shortener-web; do
  echo -n "$s: "; kubectl get endpointslices -n url-shortener -l "kubernetes.io/service-name=$s" \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
done
kubectl get endpointslices -n analytics -l kubernetes.io/service-name=analytics-collector \
  -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
```

▸ **What it does:** `kubernetes.io/service-name` links an EndpointSlice to its Service. Empty = the most silent
failure in Kubernetes.

## Step 4.3 — Redis roles

```bash
kubectl exec -n url-shortener redis-0 -- redis-cli info replication | grep '^role'
kubectl exec -n url-shortener redis-1 -- redis-cli info replication | grep master_link_status
```

▸ **Expected:** `role:master`; `master_link_status:up`.

## Step 4.4 — DNS as the application resolves it

```bash
kubectl exec -n url-shortener deployment/shortener-api -c shortener-api -- python -c '
import socket
for n in ["postgres","redis","redis-0.redis-headless","analytics","analytics-collector.analytics"]:
    print(n, socket.gethostbyname(n))'
kubectl get pod redis-0 -n url-shortener -o jsonpath='{.status.podIP}{"\n"}'
```

▸ **Expected:** every name resolves; `redis-0.redis-headless` equals `redis-0`'s pod IP.

## Step 4.5 — Schema migrated

```bash
kubectl exec -n url-shortener postgres-0 -- psql -U shortener -d shortener -c 'SELECT * FROM schema_migrations'
```

▸ **Expected:** two rows, `001_create_links` and `002_links_created_at_idx`.

## Step 4.6 — End to end inside the cluster

```bash
kubectl run e2e --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n url-shortener -- sh -c '
  code=$(curl -fsS -X POST http://shortener-web/api/links -H "Content-Type: application/json" -d "{\"url\":\"https://kubernetes.io/\"}" | sed -n "s/.*\"code\":\"\([A-Za-z0-9]*\)\".*/\1/p")
  curl -s -o /dev/null -D - "http://shortener-api:8080/r/$code" | grep -iE "^(HTTP|x-click)"'
```

▸ **What it does:** a throwaway pod (`--rm`) creates a link through the web tier and follows it through the API, so
the request exercises CoreDNS, the Services, both datastores and the analytics alias.

▸ **Expected:** `HTTP/1.1 302 FOUND` and `X-Click-Counted: true`.

## Step 4.7 — From outside, through the ALB

```bash
ALB=$(kubectl get ingress url-shortener-ingress -n url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/api/info" | python3 -m json.tool | head -12
```

▸ **Expected:** `"config_version": "final"` and `redis_write.role` `master`.

▸ **If it times out:** `curl -s https://checkip.amazonaws.com` — your IP must match `inbound-cidrs`.

---

# Part 5 — Cleanup

Order matters. Two controllers created AWS resources for you, and only they delete them.

## Step 5.1 — Delete the Ingress first, and wait

```bash
kubectl delete ingress url-shortener-ingress -n url-shortener --wait=true --timeout=300s
```

▸ **What it does:** the Ingress carries finalizer `ingress.k8s.aws/resources`. The delete blocks until the
controller has deleted the ALB, target groups and security groups, then removed the finalizer.

▸ **Expected:** `ingress.networking.k8s.io "url-shortener-ingress" deleted` after up to a minute.

▸ **If it hangs:** the controller is not running — `kubectl get deploy aws-load-balancer-controller -n kube-system`.
Do **not** remove the finalizer by hand unless you are prepared to delete the ALB in the EC2 console.

## Step 5.2 — Delete the namespaces

```bash
kubectl delete namespace url-shortener analytics --wait=true --timeout=600s
```

▸ **What it does:** removes everything namespaced, **including the PVCs** — the StatefulSet does not own them, the
namespace does. With `reclaimPolicy: Delete`, the EBS CSI driver deletes each volume.

## Step 5.3 — Cluster-scoped objects and volumes

```bash
kubectl delete storageclass url-shortener-gp3 --ignore-not-found
kubectl get pv
```

▸ **Expected:** `No resources found` (after a minute).

## Step 5.4 — Check AWS for orphans

```bash
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=url-shortener \
  --query 'Volumes[].[VolumeId,State]' --output text
aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=ingress.k8s.aws/stack,Values=url-shortener/url-shortener-ingress \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

▸ **What it does:** the EBS CSI driver tags volumes with the claim's namespace; the controller tags ALBs with the
Ingress it came from. Empty output from both = nothing orphaned.

▸ **If anything is listed:** `aws ec2 delete-volume --volume-id <id>` / `aws elbv2 delete-load-balancer
--load-balancer-arn <arn>`.

## Step 5.5 — Delete the cluster (when finished with it)

```bash
kubectl get ingress,svc -A | grep -Ei 'alb|LoadBalancer' || echo "no load balancers left"
cd .. && eksctl delete cluster --config-file clusters/eks-lab.yaml --disable-nodegroup-eviction
```

▸ **What it does:** first confirms nothing else would orphan a load balancer; then deletes the node group, add-on
roles, Pod Identity associations, control plane and VPC stacks. `--disable-nodegroup-eviction` skips draining pods
you are deleting anyway. About 15 minutes.

▸ **If it fails:** `DELETE_FAILED` on the VPC stack usually means a load balancer or ENI still uses a subnet — find
it in the EC2 console, delete it, and re-run the command.

---

# Command reference used in this project

| Command | What it does |
|---|---|
| `eksctl create cluster --config-file <f>` | Build an EKS cluster from a ClusterConfig (CloudFormation underneath) |
| `eksctl delete cluster --config-file <f>` | Delete it and its stacks |
| `aws eks describe-cluster --query …` | Read cluster facts such as the VPC ID |
| `helm upgrade --install <rel> <chart> --version <v>` | Idempotent chart install, pinned |
| `kubectl config current-context` | Which cluster every command will hit |
| `kubectl apply -f <file|dir>` | Declarative create-or-update |
| `kubectl kustomize <dir>` | Render a kustomization without applying |
| `kubectl get <kind> -o wide` / `-o jsonpath='{…}'` | Extra columns / one field |
| `kubectl get <kind> -L <label>` | Show a label as a column (e.g. node zone) |
| `kubectl describe <kind> <name>` | State **and Events** — read the bottom first |
| `kubectl logs <pod> -c <container>` | Logs; `-c` required for init containers |
| `kubectl exec <res> -- <cmd>` | Run a command inside a container |
| `kubectl run <n> --rm -i --restart=Never --image=<img> -- <cmd>` | Throwaway in-cluster client |
| `kubectl port-forward svc/<name> <l>:<r>` | Tunnel through the API server |
| `kubectl rollout status\|restart\|history\|undo` | Wait for, trigger, list and revert rollouts |
| `kubectl set env <res> K=V` | Imperatively change env (a rollout) |
| `kubectl patch <res> --type merge\|json -p '…'` | Targeted update |
| `kubectl annotate <res> k=v --overwrite` | Add or change an annotation |
| `kubectl scale <res> --replicas=N` | Change replica count |
| `kubectl wait --for=delete\|condition=Ready …` | Block until a condition holds |
| `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | A Service's real backends |
| `kubectl get targetgroupbindings` | The ALB controller's per-Service target groups |
| `aws elbv2 describe-target-health --target-group-arn <arn>` | What the ALB thinks of each pod IP |
| `aws ec2 describe-volumes --filters …` | Find EBS volumes by tag |
| `docker manifest inspect <image>` | Does the registry really have this tag? |

---

| ◀ Previous | ▲ Up | Next ▶ |
|---|:--:|---:|
| ◀ **[Stage 19 — Final](../manifests/19-final/README.md)** | [Project 03](../README.md) | **[Failure labs](../failure-labs/labs.md)** ▶ |
