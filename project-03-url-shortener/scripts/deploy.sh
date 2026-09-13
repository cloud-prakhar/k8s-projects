#!/usr/bin/env bash
# Deploys Project 03 to its FINAL state on an EKS cluster.
#
# The teaching stages (mutable ConfigMaps, v1/v2, Deployment versions of the
# datastores, stand-alone PVCs) are applied by hand during the lesson. This
# script applies only the end state — manifests/19-final — through Kustomize,
# because the final ConfigMaps are GENERATED there.
#
# Everything it does is written out in ./manual-steps.md Part 3 (stage 19) and
# Part 1 (the load balancer controller).
#
# Idempotent: safe to run repeatedly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LBC_CHART_VERSION="${LBC_CHART_VERSION:-3.5.0}"        # aws-load-balancer-controller v3.5.0
NAMESPACE="url-shortener"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run() { echo "+ $*"; "$@"; }
die() { echo "❌ $*" >&2; exit 1; }

echo "=== 0. Are we pointed at the right cluster? ==="
# kubectl acts on whatever the CURRENT context is. On a laptop with a production
# cluster in the kubeconfig, that check is the most important line in this file.
ctx=$(kubectl config current-context 2>/dev/null) || die "no current kube-context"
echo "  context: ${ctx}"
provider=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)
[[ "${provider}" == aws://* ]] || die "nodes are not EC2 instances (providerID='${provider}') — this project targets EKS"
[[ "${ctx}" == *"${CLUSTER_NAME}"* ]] || die "context '${ctx}' does not look like cluster '${CLUSTER_NAME}'. Set CLUSTER_NAME, or switch context."

echo ""
echo "=== 1. Prerequisite — the EBS CSI driver ==="
# Without it no PersistentVolumeClaim can ever bind, and both StatefulSets sit
# at 0/N with their pods Pending. It is an EKS add-on (clusters/eks-lab.yaml).
kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1 \
  || die "CSIDriver ebs.csi.aws.com missing — install the aws-ebs-csi-driver add-on"
echo "  ✅ ebs.csi.aws.com"

echo ""
echo "=== 2. Prerequisite — the AWS Load Balancer Controller ==="
# An Ingress with ingressClassName: alb is inert without it: accepted, no error,
# no load balancer. The controller needs AWS permissions, which
# clusters/eks-lab.yaml granted through EKS Pod Identity to the ServiceAccount
# kube-system/aws-load-balancer-controller.
if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "  already installed — skipping"
else
  command -v helm >/dev/null || die "helm is required to install the controller"
  kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1 \
    || die "ServiceAccount kube-system/aws-load-balancer-controller missing — its Pod Identity association comes from clusters/eks-lab.yaml"
  vpc_id=$(aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
             --query cluster.resourcesVpcConfig.vpcId --output text)
  run helm repo add eks https://aws.github.io/eks-charts
  run helm repo update eks
  run helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "${LBC_CHART_VERSION}" --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="${AWS_REGION}" \
    --set vpcId="${vpc_id}" \
    --wait --timeout 5m
fi
kubectl get ingressclass alb >/dev/null 2>&1 || die "IngressClass alb missing after install"
echo "  ✅ IngressClass/alb"

echo ""
echo "=== 3. Who may reach the load balancer ==="
# A public URL shortener is an open redirector. Default: only the machine
# running this script. Override: ALLOWED_CIDR=203.0.113.0/24 ./scripts/deploy.sh
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
echo "  alb.ingress.kubernetes.io/inbound-cidrs = ${ALLOWED_CIDR}"

echo ""
echo "=== 4. Render and apply the final state (stage 19) ==="
# `kubectl kustomize` renders; sed substitutes the CIDR; `apply -f -` applies.
# Rendering first means you could inspect exactly what is sent.
rendered=$(kubectl kustomize "${PROJECT_DIR}/manifests/19-final")
echo "+ kubectl kustomize manifests/19-final | sed inbound-cidrs | kubectl apply -f -"
sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${ALLOWED_CIDR}#" <<< "${rendered}" | kubectl apply -f -

echo ""
echo "=== 5. Wait for the datastores, then the application ==="
# StatefulSets first: the API's init container blocks until PostgreSQL answers,
# so waiting on the API before the database only adds noise.
run kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=600s
run kubectl rollout status statefulset/redis -n "${NAMESPACE}" --timeout=600s
run kubectl rollout status deployment/shortener-api -n "${NAMESPACE}" --timeout=600s
run kubectl rollout status deployment/shortener-web -n "${NAMESPACE}" --timeout=300s
run kubectl rollout status deployment/analytics-collector -n analytics --timeout=300s

echo ""
echo "=== 6. Wait for the ALB ==="
# The controller creates the load balancer asynchronously and writes its
# hostname into the Ingress status. Typically 1–3 minutes.
host=""
for _ in $(seq 1 36); do
  host=$(kubectl get ingress url-shortener-ingress -n "${NAMESPACE}" \
           -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${host}" ]] && break
  sleep 10
done
[[ -n "${host}" ]] || die "no ALB hostname after 6 minutes — kubectl describe ingress url-shortener-ingress -n ${NAMESPACE}"

run kubectl get statefulsets,deployments,pvc,ingress -n "${NAMESPACE}"

cat <<MSG

Deployed. The ALB hostname is:
  ${host}

It can take another minute or two before the name resolves and targets turn
healthy. Then:
  ./scripts/validate.sh
  open http://${host}/

💰 The ALB and three EBS volumes are billing from now. When you are done:
  ./scripts/cleanup.sh
MSG
