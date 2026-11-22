#!/usr/bin/env bash
# Deploys Project 05 to its FINAL state on an EKS cluster.
#
# The teaching stages (no resources, no probes, the canary and blue/green demos)
# are applied by hand during the lesson. This applies only manifests/19-final,
# through Kustomize, because the final ConfigMap is GENERATED there.
#
# Everything it does is written out in ./manual-steps.md Parts 1 and 3.
# Idempotent: safe to run repeatedly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LBC_CHART_VERSION="${LBC_CHART_VERSION:-3.5.0}"
NAMESPACE="web-platform"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run() { echo "+ $*"; "$@"; }
die() { echo "❌ $*" >&2; exit 1; }

echo "=== 0. Are we pointed at the right cluster? ==="
ctx=$(kubectl config current-context 2>/dev/null) || die "no current kube-context"
echo "  context: ${ctx}"
provider=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)
[[ "${provider}" == aws://* ]] || die "nodes are not EC2 instances — this project targets EKS"
[[ "${ctx}" == *"${CLUSTER_NAME}"* ]] || die "context '${ctx}' does not look like cluster '${CLUSTER_NAME}'"
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
[[ "${nodes}" -ge 3 ]] || echo "  ⚠️  only ${nodes} node(s) — the stage 14 drain lesson needs 3 (clusters/eks-advanced.yaml)"

echo ""
echo "=== 1. Prerequisite — Metrics Server (the HPA's only data source) ==="
kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1 \
  || die "metrics.k8s.io API missing — add the metrics-server add-on (clusters/eks-advanced.yaml)"
for _ in $(seq 1 12); do kubectl top nodes >/dev/null 2>&1 && break; sleep 10; done
kubectl top nodes >/dev/null 2>&1 || die "kubectl top nodes returns nothing — metrics-server not serving"
echo "  ✅ kubectl top works"

echo ""
echo "=== 2. Prerequisite — the AWS Load Balancer Controller ==="
if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "  already installed — skipping"
else
  command -v helm >/dev/null || die "helm is required"
  vpc_id=$(aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
             --query cluster.resourcesVpcConfig.vpcId --output text)
  run helm repo add eks https://aws.github.io/eks-charts
  run helm repo update eks
  run helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "${LBC_CHART_VERSION}" --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="${AWS_REGION}" --set vpcId="${vpc_id}" --wait --timeout 5m
fi
kubectl get ingressclass alb >/dev/null 2>&1 || die "IngressClass alb missing"
echo "  ✅ IngressClass/alb"

echo ""
echo "=== 3. Render and apply the final state (stage 19) ==="
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
echo "  inbound-cidrs = ${ALLOWED_CIDR}"
rendered=$(kubectl kustomize "${PROJECT_DIR}/manifests/19-final")
echo "+ kubectl kustomize manifests/19-final | sed inbound-cidrs | kubectl apply -f -"
sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${ALLOWED_CIDR}#" <<< "${rendered}" | kubectl apply -f -

echo ""
echo "=== 4. Wait for the rollout — and for the HPA ==="
run kubectl rollout status deployment/webapp -n "${NAMESPACE}" --timeout=600s
# The final Deployment deliberately has NO `replicas` field (the HPA owns it), so
# on first creation it starts with ONE pod and `rollout status` returns as soon
# as that one is ready. The HPA raises it to minReplicas a few seconds later, and
# those pods still need their 8 s warm-up and the ALB readiness gate. Wait for
# minReplicas READY pods, or validate.sh races the autoscaler.
min=$(kubectl get hpa webapp-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.minReplicas}')
echo "  waiting for ${min} ready webapp pods (HPA minReplicas)…"
for _ in $(seq 1 60); do
  ready=$(kubectl get deployment webapp -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
  [[ "${ready:-0}" -ge "${min}" ]] && break
  sleep 5
done
[[ "${ready:-0}" -ge "${min}" ]] || die "only ${ready:-0}/${min} webapp pods ready after 5 minutes"
echo "  ✅ ${ready} ready"

echo ""
echo "=== 5. Wait for the ALB ==="
host=""
for _ in $(seq 1 36); do
  host=$(kubectl get ingress web-platform-ingress -n "${NAMESPACE}" \
           -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${host}" ]] && break; sleep 10
done
[[ -n "${host}" ]] || die "no ALB hostname after 6 minutes"
run kubectl get deployment,hpa,pdb,ingress -n "${NAMESPACE}"

cat <<MSG

Deployed. ALB: http://${host}/
  ./scripts/validate.sh
💰 The ALB bills from now. When done: ./scripts/cleanup.sh
MSG
